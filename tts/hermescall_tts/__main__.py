# SPDX-License-Identifier: MIT
import argparse
import logging
from pathlib import Path

from aiohttp import web

from .server import build_app, loopback


def main() -> None:
    parser = argparse.ArgumentParser(prog="hermescall_tts", description="German speech for Hermes Call calls")
    parser.add_argument("--host", default="127.0.0.1", type=loopback)
    parser.add_argument("--port", default=8881, type=int)
    parser.add_argument("--models", default="/var/lib/hermes-call-tts/models", type=Path)
    parser.add_argument("--voices", default="dm_thorsten", help="comma-separated, the first is the default")
    parser.add_argument("--threads", default=4, type=int)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    from .engine import KokoroGerman

    engine = KokoroGerman(args.models, [voice for voice in args.voices.split(",") if voice], args.threads)
    web.run_app(build_app(engine), host=args.host, port=args.port, access_log=None, print=None)


if __name__ == "__main__":
    main()
