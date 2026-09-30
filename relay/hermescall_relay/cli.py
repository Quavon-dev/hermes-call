import argparse
import logging
import shutil
import subprocess
import sys
import time
from pathlib import Path

from aiohttp import web

from hermescall_common.codes import PairingInvite

from . import backup, doctor, logs, pushauth, schema
from .config import DEFAULT_CONFIG, Config, ConfigError, load
from .push import DirectApns, GatewayPush, PushSender
from .server import Relay, short
from .store import CODE_TTL_SECONDS, Store
from .version import VERSION


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


def _store(config: Config) -> Store:
    return Store(config.db_path, config.limits)


def serve(config: Config) -> None:
    push, push_mode = make_push(config)
    turn_secret = _optional_secret(config, "turn_secret")
    if not turn_secret:
        logging.warning("TURN secret missing: calls will fail behind NAT")
    relay = Relay(config, _store(config), push, turn_secret)
    logging.info(
        "relay %s listening on %s:%s for %s (push %s%s)",
        VERSION,
        config.listen_host,
        config.listen_port,
        config.authority,
        push_mode,
        f", metrics on {config.metrics_host}:{config.metrics_port}" if config.metrics_port else "",
    )
    # run_app turns SIGTERM into a graceful shutdown: on_shutdown closes WebSockets (1001) and
    # sends the chat alerts still waiting for an ack.
    web.run_app(relay.app(), host=config.listen_host, port=config.listen_port, access_log=None, print=None, shutdown_timeout=10)


def pair(config: Config) -> None:
    store = _store(config)
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


def _day(timestamp: int) -> str:
    return time.strftime("%Y-%m-%d", time.localtime(timestamp))


def list_bridges(config: Config) -> None:
    rows = _store(config).list_bridges()
    if not rows:
        print("no bridges paired")
    for bridge_id, created, devices in rows:
        print(f"{bridge_id}  paired {_day(created)}  devices={devices}")


def list_devices(config: Config) -> None:
    devices = _store(config).all_devices()
    if not devices:
        print("no devices paired")
    for device in devices:
        pushes = ",".join(
            kind
            for kind, token in (("voip", device.push_token), ("alert", device.alert_token), ("live", device.la_start_token))
            if token
        )
        print(f"{device.id}  bridge {short(device.bridge_id)}…  paired {_day(device.created)}  push={pushes or '-'}")


def revoke_bridge(config: Config, bridge_id: str) -> int:
    if _store(config).delete_bridge(bridge_id):
        print(f"revoked bridge {short(bridge_id)}… and all its devices")
        return 0
    print("unknown bridge", file=sys.stderr)
    return 1


def revoke_device(config: Config, device_id: str) -> int:
    store = _store(config)
    device = store.device(device_id)
    if device is None or not store.delete_device(device.bridge_id, device_id):
        print("unknown device", file=sys.stderr)
        return 1
    print(f"revoked device {short(device_id)}… (disconnected within 15 s; its bridge still lists it until it syncs)")
    return 0


def stats(config: Config) -> None:
    store = _store(config)
    usage = store.usage()
    mib = 1024 * 1024
    print(f"relay {VERSION}, database schema {store.schema_version}/{schema.LATEST}")
    print(f"bridges {usage.bridges}, devices {usage.devices}")
    print(f"mailbox {usage.mail_count} message(s), {usage.mail_bytes / mib:.1f} MiB")
    print(f"attachments {usage.blob_count}, {usage.blob_bytes / mib:.1f} MiB")
    print(f"stored {usage.stored_bytes / mib:.1f} of {config.limits.storage_max_bytes / mib:.0f} MiB allowed")
    print(f"disk free {store.free_bytes() / mib:.0f} MiB (floor {config.limits.min_free_bytes / mib:.0f} MiB)")


def push_id(config: Config) -> int:
    key = _optional_secret(config, "push_gateway_key")
    if not key:
        print("no push gateway key", file=sys.stderr)
        return 1
    print(pushauth.relay_id(pushauth.load_key(key)))
    return 0


def make_backup(config: Config, config_path: Path, target: Path, include: list[Path]) -> int:
    members = backup.create(config, config_path, target, include)
    print(f"backup written to {target} (mode 600, {len(members) - 2} config file(s)); it contains secrets")
    return 0


def restore_backup(config: Config, config_path: Path, archive: Path, include: list[Path]) -> int:
    roots = [config.secrets_dir, config_path.resolve().parent, *include]
    manifest = backup.restore(archive, config.db_path, roots)
    print(f"restored backup of relay {manifest.get('relay')} from {_day(int(manifest.get('created', 0)))}")
    print("start the relay again; phones and bridges reconnect on their own")
    return 0


def compact(config: Config) -> None:
    store = _store(config)
    before = store.path.stat().st_size
    store.compact()
    print(f"database compacted: {before // 1024} KiB -> {store.path.stat().st_size // 1024} KiB")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hermescall-relay")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("serve", help="run the relay daemon")
    sub.add_parser("pair", help="create a one-time bridge pairing code")
    sub.add_parser("bridges", help="list paired bridges")
    sub.add_parser("devices", help="list paired devices")
    revoke = sub.add_parser("revoke-bridge", help="remove a bridge and all of its devices")
    revoke.add_argument("bridge_id")
    revoke = sub.add_parser("revoke-device", help="remove one device (e.g. a lost phone)")
    revoke.add_argument("device_id")
    sub.add_parser("check-config", help="validate the configuration")
    sub.add_parser("push-id", help="print this relay's identity at the push gateway")
    sub.add_parser("stats", help="counts, stored bytes and disk space")
    sub.add_parser("doctor", help="check DNS, TLS, TURN, push, disk and the running relay")
    sub.add_parser("compact", help="VACUUM the database (returns free space to the disk)")
    for name, text in (("backup", "write a backup archive (database + config + keys)"), ("restore", "restore a backup")):
        command = sub.add_parser(name, help=text)
        command.add_argument("archive", type=Path)
        command.add_argument("--include", type=Path, action="append", default=[], help="another config directory")
    return parser


def _dispatch(args: argparse.Namespace, config: Config) -> int:
    simple = {
        "pair": pair,
        "bridges": list_bridges,
        "devices": list_devices,
        "stats": stats,
        "compact": compact,
        "serve": serve,
    }
    if args.command in simple:
        simple[args.command](config)
        return 0
    if args.command == "push-id":
        return push_id(config)
    if args.command == "revoke-bridge":
        return revoke_bridge(config, args.bridge_id)
    if args.command == "revoke-device":
        return revoke_device(config, args.device_id)
    if args.command == "doctor":
        return doctor.report(doctor.run(config))
    if args.command == "backup":
        return make_backup(config, args.config, args.archive, args.include)
    if args.command == "restore":
        return restore_backup(config, args.config, args.archive, args.include)
    print(f"config ok: {config.authority}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    logs.setup()
    try:
        config = load(args.config)
        logs.setup(config.log_level, config.log_format)
        return _dispatch(args, config)
    except (ConfigError, backup.BackupError, schema.SchemaError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
