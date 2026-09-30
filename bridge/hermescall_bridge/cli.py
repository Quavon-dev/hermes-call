import argparse
import asyncio
import json
import logging
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from hermescall_common import codes
from hermescall_common.client import pair_as_initiator
from hermescall_common.errors import ProtocolError

from .config import DEFAULT_CONFIG, Config, ConfigError, load
from .state import StateStore

PAIRING_WAIT_SECONDS = 600


def _api(config: Config, method: str, path: str, body: dict | None = None, timeout: float = 15) -> dict:
    request = urllib.request.Request(
        f"http://{config.api_host}:{config.api_port}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {config.secret('api_token')}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - loopback URL from config
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        raise ConfigError(f"bridge API error {exc.code}: {exc.read().decode(errors='replace')[:200]}") from exc
    except OSError as exc:
        raise ConfigError("cannot reach the bridge service; is hermes-call-bridge running?") from exc


def _parse_invite(args: list[str], pin: str = "") -> codes.PairingInvite:
    if len(args) == 1:
        invite = codes.parse_uri(args[0])
    elif len(args) == 2:
        host, port = codes.parse_authority(args[0])
        invite = codes.PairingInvite("relay", host, port, codes.validate_pin(pin) if pin else "", codes.parse_code(args[1]))
    else:
        raise ProtocolError("give a pairing link, or a relay address and a code")
    if invite.kind != "relay":
        raise ProtocolError("this is a device pairing link, not a relay pairing link")
    return invite


def relay_add(config: Config, args: list[str], force: bool, pin: str = "") -> int:
    store = StateStore(config.state_dir)
    state = store.load()
    if state.paired and not force:
        print(f"already paired with {state.endpoint.authority}; use --force to replace (devices must pair again)")
        return 1
    invite = _parse_invite(args, pin)
    final, result, pin = asyncio.run(pair_as_initiator(invite, {"sign_pk": state.keys["sign_pk"]}, "paired"))
    state.relay = {"host": invite.host, "port": invite.port, "pin": pin, "bridge_id": result["bridge_id"]}
    state.devices = {}
    store.save(state)
    print(f"paired with relay {state.endpoint.authority} (bridge {result['bridge_id'][:6]}…)")
    if pin and not invite.pin:
        print(f"relay uses a self-signed certificate; pinned key {pin} (verified by the pairing code)")
    print("restart the service: systemctl restart hermes-call-bridge")
    return 0


def device_add(config: Config, name: str) -> int:
    offer = _api(config, "POST", "/v1/devices/pairing", {"name": name})
    print(f"\nDevice pairing code: {offer['code']}   (single use, 10 minutes, 3 attempts)")
    print("In the Hermes Call app: Add relay → enter the relay address and this code, or scan:\n", flush=True)
    qrencode = shutil.which("qrencode")
    if qrencode:
        subprocess.run([qrencode, "-t", "ANSIUTF8", "-m", "2"], input=offer["uri"].encode(), check=False)
    print(f"Link: {offer['uri']}\nWaiting for the device…", flush=True)
    deadline = time.monotonic() + PAIRING_WAIT_SECONDS
    while time.monotonic() < deadline:
        status = _api(config, "GET", f"/v1/devices/pairing/{offer['slot']}")
        if status["status"] == "paired":
            print(f"paired: {status['device']['name']} ({status['device']['id']})")
            return 0
        if status["status"] == "closed":
            break
        time.sleep(1)
    print("pairing code expired", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hermes-call-bridge")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("serve", help="run the bridge daemon")
    relay = sub.add_parser("relay", help="relay pairing").add_subparsers(dest="action", required=True)
    add = relay.add_parser("add", help="pair with a relay: pairing link, or <relay address> <code>")
    add.add_argument("invite", nargs="+")
    add.add_argument("--force", action="store_true")
    add.add_argument("--pin", default="", help="TLS pin of a self-signed relay (printed by hermescall-relay pair)")
    relay.add_parser("show")
    device = sub.add_parser("device", help="paired phones").add_subparsers(dest="action", required=True)
    device.add_parser("add").add_argument("--name", default="iPhone")
    device.add_parser("list")
    device.add_parser("revoke").add_argument("device_id")
    call = sub.add_parser("call", help="ring your phone (test)")
    call.add_argument("--first-message", default="Hello, this is a Hermes Call test call.")
    call.add_argument("--reason", default="test call")
    call.add_argument("--device", default="all")
    sub.add_parser("status")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    # httpx logs every request URL at INFO (Hermes run ids, TTS calls): noise, and URLs can carry ids.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        config = load(args.config)
        if args.command == "serve":
            from .daemon import run

            run(config)
        elif args.command == "relay" and args.action == "add":
            return relay_add(config, args.invite, args.force, args.pin)
        elif args.command == "relay":
            state = StateStore(config.state_dir).load()
            print(state.endpoint.authority if state.paired else "not paired")
        elif args.command == "device" and args.action == "add":
            return device_add(config, args.name)
        elif args.command == "device" and args.action == "list":
            for d in _api(config, "GET", "/v1/devices")["devices"]:
                print(f"{d['id']}  {d['name']}  paired {time.strftime('%Y-%m-%d', time.localtime(d['created']))}")
        elif args.command == "device":
            print(json.dumps(_api(config, "DELETE", f"/v1/devices/{args.device_id}")))
        elif args.command == "call":
            body = {"reason": args.reason, "first_message": args.first_message, "device": args.device}
            print(json.dumps(_api(config, "POST", "/v1/calls", body, timeout=120)))
        else:
            print(json.dumps(_api(config, "GET", "/v1/status")))
    except (ConfigError, ProtocolError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
