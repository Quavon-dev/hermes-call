import argparse
import logging
import shutil
import subprocess
import sys
import time
from pathlib import Path

from aiohttp import web

from hermescall_common.codes import PairingInvite

from . import pushauth
from .config import DEFAULT_CONFIG, Config, ConfigError, load
from .push import DirectApns, GatewayPush, PushSender
from .server import Relay, short
from .store import CODE_TTL_SECONDS, Store


def _optional_secret(config: Config, name: str) -> bytes | None:
    try:
        return config.secret(name)
    except ConfigError:
        return None


def make_push(config: Config) -> tuple[PushSender | None, str]:
    if config.apns:
        return DirectApns(config.apns, config.secret("apns_key")), "own APNs key"
    if not config.push_gateway:
        return None, "disabled"
    key = _optional_secret(config, "push_gateway_key")
    if not key:
        logging.warning("push_gateway_key missing: incoming calls ring only while the app is open")
        return None, "disabled (no gateway key)"
    push = GatewayPush(config.push_gateway, key)
    return push, f"via {config.push_gateway} as relay {short(push.relay_id)}"


def serve(config: Config) -> None:
    push, push_mode = make_push(config)
    turn_secret = _optional_secret(config, "turn_secret")
    if not turn_secret:
        logging.warning("TURN secret missing: calls will fail behind NAT")
    relay = Relay(config, Store(config.db_path), push, turn_secret)
    logging.info(
        "relay listening on %s:%s for %s (push %s)",
        config.listen_host,
        config.listen_port,
        config.authority,
        push_mode,
    )
    web.run_app(relay.app(), host=config.listen_host, port=config.listen_port, access_log=None, print=None)


def pair(config: Config) -> None:
    store = Store(config.db_path)
    code = store.create_relay_code()
    invite = PairingInvite("relay", config.host, config.port, config.tls_pin, code)
    print(f"Relay pairing code: {code.display()}  (single use, valid {CODE_TTL_SECONDS // 60} minutes)")
    print(f"Relay:              {config.authority}")
    if config.tls_pin:
        print(f"TLS pin (SHA-256):  {config.tls_pin}")
    print("\nOn the bridge host run:")
    print(f"  hermes-call-bridge relay add '{invite.to_uri()}'")
    qrencode = shutil.which("qrencode")
    if qrencode:
        print(flush=True)
        subprocess.run([qrencode, "-t", "ANSIUTF8", "-m", "2"], input=invite.to_uri().encode(), check=False)


def list_bridges(config: Config) -> None:
    rows = Store(config.db_path).list_bridges()
    if not rows:
        print("no bridges paired")
    for bridge_id, created, devices in rows:
        print(f"{bridge_id}  paired {time.strftime('%Y-%m-%d', time.localtime(created))}  devices={devices}")


def revoke_bridge(config: Config, bridge_id: str) -> int:
    if Store(config.db_path).delete_bridge(bridge_id):
        print(f"revoked bridge {short(bridge_id)}… and all its devices")
        return 0
    print("unknown bridge", file=sys.stderr)
    return 1


def push_id(config: Config) -> int:
    key = _optional_secret(config, "push_gateway_key")
    if not key:
        print("no push gateway key", file=sys.stderr)
        return 1
    print(pushauth.relay_id(pushauth.load_key(key)))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hermescall-relay")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("serve", help="run the relay daemon")
    sub.add_parser("pair", help="create a one-time bridge pairing code")
    sub.add_parser("bridges", help="list paired bridges")
    revoke = sub.add_parser("revoke-bridge", help="remove a bridge and all of its devices")
    revoke.add_argument("bridge_id")
    sub.add_parser("check-config", help="validate the configuration")
    sub.add_parser("push-id", help="print this relay's identity at the push gateway")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    # httpx logs every request URL at INFO, and APNs URLs contain the device token.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        config = load(args.config)
        if args.command == "serve":
            serve(config)
        elif args.command == "pair":
            pair(config)
        elif args.command == "bridges":
            list_bridges(config)
        elif args.command == "push-id":
            return push_id(config)
        elif args.command == "revoke-bridge":
            return revoke_bridge(config, args.bridge_id)
        else:
            print(f"config ok: {config.authority}")
    except ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
