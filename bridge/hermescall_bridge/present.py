"""Presentations: structured results (places, links, lists) the agent shows as cards in the app.

The phone never contacts third parties: the bridge fetches `image_url`s itself (https, public
addresses only, checked on every resolved address; no redirects; ≤ 5 MiB; 8 s each, 15 s in
total), re-encodes them as small JPEGs without metadata and sends them as encrypted blobs.
"""

import asyncio
import io
import ipaddress
import logging
import math
import re
import socket
import urllib.parse
from collections.abc import Awaitable, Callable, Mapping
from typing import Any

import aiohttp
from aiohttp.abc import AbstractResolver, ResolveResult
from aiohttp.resolver import DefaultResolver
from PIL import Image, ImageOps

from .chat import ChatService

log = logging.getLogger(__name__)

KINDS = ("places", "links", "list")
MAX_TITLE = 120
MAX_TEXT = 2000
MAX_ITEMS = 10
MAX_SUBTITLE = 200
MAX_DETAIL = 600
MAX_URL = 1000
MAX_ACTIONS = 3
MAX_LABEL = 30
TEL = re.compile(r"[+0-9 ()/-]{3,30}")
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_PIXELS = 12_000_000
IMAGE_FORMATS = ("JPEG", "PNG", "WEBP", "GIF")
MAX_DECODES = 2
MAX_SIDE = 512
JPEG_QUALITY = 80
IMAGE_TIMEOUT = 8.0
IMAGES_TIMEOUT = 15.0

Image.MAX_IMAGE_PIXELS = MAX_PIXELS
Fetcher = Callable[[str], Awaitable[bytes]]


# ---- validation ----------------------------------------------------------


def _text(raw: dict, name: str, limit: int, required: bool = False) -> str | None:
    value = raw.get(name)
    if value is None and not required:
        return None
    if not isinstance(value, str) or len(value.strip()) > limit or (required and not value.strip()):
        raise ValueError(f"{name}: {'required, 1–' if required else 'at most '}{limit} chars")
    return value.strip() or None


def https_url(value: object, name: str = "url") -> str:
    ok = isinstance(value, str) and len(value) <= MAX_URL and value.startswith("https://")
    ok = ok and not any(ch <= " " or ch == "\x7f" for ch in value)
    try:
        parts = urllib.parse.urlsplit(value) if ok else None
        ok = ok and bool(parts.hostname) and parts.username is None and parts.password is None
        ok = ok and (parts.port is None or parts.port > 0)
    except ValueError:
        ok = False
    if not ok:
        raise ValueError(f"{name}: https:// URL of at most {MAX_URL} chars")
    return value


def _coordinate(value: object, name: str, limit: float) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value) or abs(value) > limit:
        raise ValueError(f"{name}: number between -{limit:g} and {limit:g}")
    return float(value)


def _action(raw: object, has_location: bool) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("actions: objects with label and url, tel or maps")
    action: dict[str, Any] = {"label": _text(raw, "label", MAX_LABEL, required=True)}
    targets = [key for key in ("url", "tel", "maps") if raw.get(key) is not None]
    if len(targets) != 1:
        raise ValueError("actions: exactly one of url, tel or maps")
    if targets[0] == "url":
        action["url"] = https_url(raw["url"], "actions.url")
    elif targets[0] == "tel":
        tel = raw["tel"]
        if not isinstance(tel, str) or not TEL.fullmatch(tel) or not any(ch.isdigit() for ch in tel):
            raise ValueError("actions.tel: +, digits, spaces and -()/ (3–30 chars)")
        action["tel"] = tel
    else:
        if raw["maps"] is not True or not has_location:
            raise ValueError("actions.maps: true, and the item needs lat and lon")
        action["maps"] = True
    return action


def _item(raw: object) -> tuple[dict[str, Any], str | None]:
    if not isinstance(raw, dict):
        raise ValueError("items: objects")
    item: dict[str, Any] = {"title": _text(raw, "title", MAX_TITLE, required=True)}
    for name, limit in (("subtitle", MAX_SUBTITLE), ("detail", MAX_DETAIL)):
        if (value := _text(raw, name, limit)) is not None:
            item[name] = value
    if raw.get("url") is not None:
        item["url"] = https_url(raw["url"])
    image_url = https_url(raw["image_url"], "image_url") if raw.get("image_url") is not None else None
    if (raw.get("lat") is None) != (raw.get("lon") is None):
        raise ValueError("lat and lon: both or neither")
    if raw.get("lat") is not None:
        item["lat"] = _coordinate(raw["lat"], "lat", 90)
        item["lon"] = _coordinate(raw["lon"], "lon", 180)
    actions = raw.get("actions")
    if actions is not None:
        if not isinstance(actions, list) or len(actions) > MAX_ACTIONS:
            raise ValueError(f"actions: at most {MAX_ACTIONS}")
        if actions:
            item["actions"] = [_action(action, "lat" in item) for action in actions]
    return item, image_url


def parse(body: object) -> tuple[dict[str, Any], str, list[str | None]]:
    """(presentation, preview text, image URL per item). Raises ValueError; unknown keys are ignored."""
    if not isinstance(body, dict):
        raise ValueError("expected an object")
    title = _text(body, "title", MAX_TITLE, required=True)
    kind = body.get("kind", "list")
    if kind not in KINDS:
        raise ValueError(f"kind: one of {', '.join(KINDS)}")
    text = _text(body, "text", MAX_TEXT)
    raw_items = body.get("items")
    if not isinstance(raw_items, list) or not 1 <= len(raw_items) <= MAX_ITEMS:
        raise ValueError(f"items: 1–{MAX_ITEMS}")
    parsed = [_item(raw) for raw in raw_items]
    presentation = {"title": title, "kind": kind, "items": [item for item, _ in parsed]}
    return presentation, text or title, [url for _, url in parsed]


# ---- images ----------------------------------------------------------------


def is_public_address(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    blocked = ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified
    return ip.is_global and not blocked


class PublicResolver(AbstractResolver):
    """Drops every non-public address a name resolves to, so DNS cannot point the bridge inwards."""

    def __init__(self, inner: AbstractResolver | None = None) -> None:
        self._inner = inner or DefaultResolver()

    async def resolve(self, host: str, port: int = 0, family: socket.AddressFamily = socket.AF_INET) -> list[ResolveResult]:
        results = [r for r in await self._inner.resolve(host, port, family) if is_public_address(r["host"])]
        if not results:
            raise OSError(f"{host} has no public address")
        return results

    async def close(self) -> None:
        await self._inner.close()


def check_response(status: int, headers: Mapping[str, str]) -> None:
    """200, an image type, no content encoding (it would bypass the byte cap), not announced as too large."""
    encoding = headers.get("Content-Encoding", "identity").strip().lower()
    content_type = headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    if status != 200 or not content_type.startswith("image/"):
        raise OSError(f"image not loaded: HTTP {status} {content_type}")
    if encoding != "identity":
        raise OSError("compressed image response")
    length = headers.get("Content-Length", "0")
    if not length.isdigit() or int(length) > MAX_IMAGE_BYTES:
        raise OSError("image too large")


async def fetch_image(url: str) -> bytes:
    """GET an image from the public internet (see the module docstring for the rules)."""
    host = urllib.parse.urlsplit(https_url(url, "image_url")).hostname or ""
    try:
        literal = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        literal = None
    if literal is not None and not is_public_address(str(literal)):  # aiohttp skips the resolver for IP literals
        raise OSError("image host is not public")
    connector = aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False)
    timeout = aiohttp.ClientTimeout(total=IMAGE_TIMEOUT)
    async with (
        # No transparent decompression: the byte cap must apply to what is decoded.
        aiohttp.ClientSession(connector=connector, timeout=timeout, trust_env=False, auto_decompress=False) as session,
        session.get(url, allow_redirects=False, headers={"Accept": "image/*", "Accept-Encoding": "identity"}) as response,
    ):
        check_response(response.status, response.headers)
        data = bytearray()
        async for chunk in response.content.iter_chunked(64 * 1024):
            data += chunk
            if len(data) > MAX_IMAGE_BYTES:
                raise OSError("image too large")
    return bytes(data)


def _rgb(image: Image.Image) -> Image.Image:
    if image.mode in ("RGBA", "LA", "PA") or (image.mode == "P" and "transparency" in image.info):
        rgba = image.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.getchannel("A"))
        return flat
    return image.convert("RGB")


def to_jpeg(data: bytes, max_side: int = MAX_SIDE) -> bytes:
    """Any image Pillow reads → JPEG, longest side ≤ `max_side` px, quality 80, no EXIF/ICC/metadata."""
    try:
        with Image.open(io.BytesIO(data), formats=IMAGE_FORMATS) as source:
            if source.width * source.height > MAX_PIXELS:
                raise ValueError("image has too many pixels")
            source.draft("RGB", (max_side, max_side))
            image = _rgb(ImageOps.exif_transpose(source) or source)
            image.thumbnail((max_side, max_side))
            clean = Image.new("RGB", image.size)
            clean.paste(image)
            out = io.BytesIO()
            clean.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True)
            return out.getvalue()
    except (Image.DecompressionBombError, OSError, SyntaxError, ValueError, MemoryError) as exc:
        raise ValueError("unreadable image") from exc


class PresentService:
    def __init__(self, chat: ChatService, fetch: Fetcher = fetch_image) -> None:
        self._chat = chat
        self.fetch = fetch
        self._decodes = asyncio.Semaphore(MAX_DECODES)

    async def present(self, body: object) -> dict[str, Any]:
        """Raises ValueError (→ HTTP 400) for invalid or oversized presentations."""
        presentation, text, urls = parse(body)
        if not self._chat.fits_presentation(text, _with_placeholder_images(presentation, urls)):
            raise ValueError("presentation too large")
        images = await self._load_images(urls)
        message_id = await self._chat.send_presentation(text, presentation, images, _summary(presentation))
        log.info("presentation %s: %d items, %d images", message_id[:6], len(urls), len(images))
        return {"message_id": message_id, "images": len(images)}

    async def _load_images(self, urls: list[str | None]) -> dict[int, bytes]:
        tasks = {index: asyncio.ensure_future(self._load(url)) for index, url in enumerate(urls) if url}
        if not tasks:
            return {}
        await asyncio.wait(tasks.values(), timeout=IMAGES_TIMEOUT)
        images = {}
        for index, task in tasks.items():
            if not task.done():
                task.cancel()
            elif task.exception() is None and task.result() is not None:
                images[index] = task.result()
        return images

    async def _load(self, url: str) -> bytes | None:
        try:
            data = await asyncio.wait_for(self.fetch(url), IMAGE_TIMEOUT)
            async with self._decodes:
                return await asyncio.get_running_loop().run_in_executor(None, to_jpeg, data)
        except (aiohttp.ClientError, OSError, TimeoutError, ValueError) as exc:
            log.info("presentation image dropped: %s", exc.__class__.__name__)
            return None


def _with_placeholder_images(presentation: dict[str, Any], urls: list[str | None]) -> dict[str, Any]:
    """Worst case for the size check: every image loaded."""
    placeholder = {"blob_id": "A" * 22, "key": "A" * 43, "mime": "image/jpeg", "size": MAX_IMAGE_BYTES}
    items = [{**item, "image": placeholder} if url else item for item, url in zip(presentation["items"], urls, strict=True)]
    return {**presentation, "items": items}


def _summary(presentation: dict[str, Any]) -> str:
    titles = "; ".join(item["title"] for item in presentation["items"])
    return f"[Shown to the owner as cards: {presentation['title']} — {titles}]"
