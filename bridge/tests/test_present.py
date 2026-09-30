"""M7 presentations: validation, image safety (public addresses only, re-encoding) and delivery."""

import io
import socket
import struct
import zlib

import pytest
from PIL import Image

from hermescall_bridge import present
from hermescall_bridge.present import PublicResolver, check_response, fetch_image, is_public_address, parse, to_jpeg

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import hermes_api, next_of, online_device, stop_devices  # noqa: F401 - stop_devices is a fixture

ITEM = {
    "title": "Trattoria",
    "subtitle": "Italian · 4.6 ★ · 350 m",
    "detail": "Open until 23:00.",
    "url": "https://example.com/trattoria",
    "image_url": "https://img.example.com/1.jpg",
    "lat": 48.137,
    "lon": 11.575,
    "actions": [
        {"label": "Call", "tel": "+49 89 123-45 (0)/6"},
        {"label": "Route", "maps": True},
        {"label": "Menu", "url": "https://example.com/menu"},
    ],
}


def deck(**changes) -> dict:
    return {"title": "Restaurants near you", "kind": "places", "text": "Three open now.", "items": [ITEM], **changes}


def with_item(**changes) -> dict:
    return deck(items=[{**ITEM, **changes}])


def image_bytes(size: tuple[int, int] = (1200, 800), mode: str = "RGB", fmt: str = "PNG", **save) -> bytes:
    out = io.BytesIO()
    Image.new(mode, size, (200, 30, 30, 128) if mode == "RGBA" else (200, 30, 30)).save(out, fmt, **save)
    return out.getvalue()


# ---- validation -------------------------------------------------------------


def test_valid_presentation_is_normalized() -> None:
    body = deck(items=[{**ITEM, "unknown": 1}, {"title": " Plain "}], extra="ignored")
    presentation, text, urls = parse(body)
    assert text == "Three open now." and urls == [ITEM["image_url"], None]
    assert presentation["kind"] == "places" and presentation["title"] == "Restaurants near you"
    first, second = presentation["items"]
    assert "image_url" not in first and "unknown" not in first and first["actions"][1] == {"label": "Route", "maps": True}
    assert second == {"title": "Plain"}
    presentation, text, _ = parse({"title": "T", "items": [{"title": "x"}]})
    assert presentation["kind"] == "list" and text == "T"


@pytest.mark.parametrize(
    "body",
    [
        [],
        deck(title=""),
        deck(title="x" * 121),
        deck(kind="table"),
        deck(text="x" * 2001),
        deck(items=[]),
        deck(items=[ITEM] * 11),
        deck(items=["x"]),
        with_item(title=" "),
        with_item(subtitle="x" * 201),
        with_item(detail="x" * 601),
        with_item(url="http://example.com"),
        with_item(url="javascript:alert(1)"),
        with_item(url="https://" + "a" * 1000),
        with_item(url="https://user:pw@example.com/"),
        with_item(url="https://exa mple.com/"),
        with_item(image_url="file:///etc/passwd"),
        with_item(lat=None),
        with_item(lat=91),
        with_item(lon=-180.5),
        with_item(lat="48.1"),
        with_item(lat=True),
        with_item(lat=float("nan")),
        with_item(actions=[{"label": "a", "maps": True}] * 4),
        with_item(actions=[{"label": "", "maps": True}]),
        with_item(actions=[{"label": "x" * 31, "maps": True}]),
        with_item(actions=[{"label": "Two", "maps": True, "tel": "+49 1"}]),
        with_item(actions=[{"label": "None"}]),
        with_item(actions=[{"label": "Url", "url": "http://example.com"}]),
        with_item(actions=[{"label": "Tel", "tel": "12"}]),
        with_item(actions=[{"label": "Tel", "tel": "+49 89 <b>"}]),
        with_item(actions=[{"label": "Tel", "tel": "1" * 31}]),
        with_item(actions=[{"label": "Maps", "maps": "yes"}]),
        with_item(lat=None, lon=None, actions=[{"label": "Maps", "maps": True}]),
        with_item(actions="call"),
    ],
)
def test_invalid_presentations_are_rejected(body) -> None:
    with pytest.raises(ValueError):
        parse(body)


# ---- image safety ---------------------------------------------------------


@pytest.mark.parametrize(
    ("address", "public"),
    [
        ("93.184.216.34", True),
        ("2606:2800:220:1:248:1893:25c8:1946", True),
        ("127.0.0.1", False),
        ("10.1.2.3", False),
        ("172.16.0.1", False),
        ("192.168.1.10", False),
        ("100.64.0.1", False),  # carrier-grade NAT
        ("169.254.169.254", False),  # cloud metadata
        ("0.0.0.0", False),  # noqa: S104
        ("224.0.0.1", False),
        ("240.0.0.1", False),
        ("255.255.255.255", False),
        ("::1", False),
        ("::", False),
        ("fe80::1%en0", False),
        ("fc00::1", False),
        ("ff02::1", False),
        ("::ffff:127.0.0.1", False),
        ("::ffff:10.0.0.1", False),
        ("::ffff:93.184.216.34", True),
        ("not an ip", False),
    ],
)
def test_public_address_filter(address, public) -> None:
    assert is_public_address(address) is public


class FakeResolver:
    def __init__(self, *addresses: str) -> None:
        self.addresses = addresses

    async def resolve(self, host: str, port: int = 0, family: socket.AddressFamily = socket.AF_INET) -> list[dict]:
        return [{"hostname": host, "host": a, "port": port, "family": family, "proto": 0, "flags": 0} for a in self.addresses]

    async def close(self) -> None:
        pass


async def test_resolver_drops_private_addresses() -> None:
    resolver = PublicResolver(FakeResolver("10.0.0.1", "93.184.216.34", "::1"))
    assert [r["host"] for r in await resolver.resolve("mixed.example", 443)] == ["93.184.216.34"]
    with pytest.raises(OSError):
        await PublicResolver(FakeResolver("127.0.0.1", "::ffff:192.168.0.1")).resolve("rebind.example", 443)


@pytest.mark.parametrize(
    "url", ["https://127.0.0.1/x.png", "https://[::1]/x.png", "https://169.254.169.254/latest", "http://example.com/x.png"]
)
async def test_fetch_refuses_private_literals_and_http(url) -> None:
    with pytest.raises((OSError, ValueError)):
        await fetch_image(url)


async def test_fetch_never_reaches_a_name_that_resolves_to_loopback(monkeypatch) -> None:
    monkeypatch.setattr(present, "DefaultResolver", lambda: FakeResolver("127.0.0.1"))
    with pytest.raises(OSError):
        await fetch_image("https://localhost.example/x.png")


def test_to_jpeg_shrinks_and_strips_metadata() -> None:
    exif = Image.Exif()
    exif[0x010F] = "SecretCam"  # Make
    exif[0x8825] = {2: (48.0, 8.0, 0.0)}  # GPS
    source = image_bytes((2000, 1000), fmt="JPEG", exif=exif.tobytes())
    assert Image.open(io.BytesIO(source)).getexif()
    jpeg = to_jpeg(source)
    with Image.open(io.BytesIO(jpeg)) as image:
        assert image.format == "JPEG" and max(image.size) == 512 and image.mode == "RGB"
        assert not image.getexif() and "icc_profile" not in image.info and "exif" not in image.info
    with Image.open(io.BytesIO(to_jpeg(image_bytes((100, 50), mode="RGBA")))) as image:
        assert image.size == (100, 50) and image.mode == "RGB"


@pytest.mark.parametrize(
    ("status", "headers", "ok"),
    [
        (200, {"Content-Type": "image/jpeg"}, True),
        (200, {"Content-Type": "image/png; charset=binary", "Content-Encoding": "identity", "Content-Length": "100"}, True),
        (200, {"Content-Type": "image/jpeg", "Content-Encoding": "gzip"}, False),
        (200, {"Content-Type": "image/jpeg", "Content-Encoding": "br"}, False),
        (200, {"Content-Type": "text/html"}, False),
        (200, {"Content-Type": "image/jpeg", "Content-Length": str(6 * 1024 * 1024)}, False),
        (200, {"Content-Type": "image/jpeg", "Content-Length": "-1"}, False),
        (302, {"Content-Type": "image/jpeg", "Location": "http://127.0.0.1/"}, False),
    ],
)
def test_image_response_checks(status, headers, ok) -> None:
    if ok:
        check_response(status, headers)
    else:
        with pytest.raises(OSError):
            check_response(status, headers)


def _png_header(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"\0" * 64)) + chunk(b"IEND", b"")


@pytest.mark.filterwarnings("ignore::PIL.Image.DecompressionBombWarning")
@pytest.mark.parametrize(
    "data",
    [_png_header(50_000, 50_000), _png_header(4000, 4000), image_bytes((10, 10), fmt="BMP"), b"not an image", b""],
)
def test_to_jpeg_rejects_bombs_and_garbage(data) -> None:
    with pytest.raises(ValueError):
        to_jpeg(data)


# ---- delivery ---------------------------------------------------------------


def fake_fetcher(images: dict[str, bytes], calls: list[str]):
    async def fetch(url: str) -> bytes:
        calls.append(url)
        if url not in images:
            raise OSError("not found")
        return images[url]

    return fetch


async def test_presentation_reaches_the_phone_with_images(h) -> None:
    device = await online_device(h)
    calls: list[str] = []
    second = {"title": "Pizzeria", "image_url": "https://img.example.com/missing.jpg", "lat": 48.1, "lon": 11.5}
    third = {"title": "Bistro", "image_url": "https://img.example.com/garbage.jpg"}
    h.bridge.presenter.fetch = fake_fetcher({ITEM["image_url"]: image_bytes(), third["image_url"]: b"<html>"}, calls)
    status, result = await hermes_api(h, "POST", "/v1/present", deck(items=[ITEM, second, third]))
    assert status == 200 and result["images"] == 1
    assert sorted(calls) == sorted([ITEM["image_url"], second["image_url"], third["image_url"]])

    message = await next_of(device, "chat")
    assert message["kind"] == "presentation" and message["id"] == result["message_id"] and message["role"] == "agent"
    assert message["text"] == "Three open now." and message["mid"]
    shown = message["presentation"]
    assert shown["title"] == "Restaurants near you" and shown["kind"] == "places"
    first, pizzeria, bistro = shown["items"]
    assert "image" not in pizzeria and "image" not in bistro and "image_url" not in first
    assert first["actions"][0] == {"label": "Call", "tel": "+49 89 123-45 (0)/6"}
    image = first["image"]
    assert image["mime"] == "image/jpeg"
    jpeg = await device.fetch_attachment(image)
    assert jpeg.startswith(b"\xff\xd8") and len(jpeg) == image["size"]
    assert "Restaurants near you" in h.bridge.chat.recent_context() and "Pizzeria" in h.bridge.chat.recent_context()


async def test_every_phone_gets_its_own_image_blob(h) -> None:
    a = await online_device(h, "Phone A")
    b = await online_device(h, "Phone B")
    h.bridge.presenter.fetch = fake_fetcher({ITEM["image_url"]: image_bytes()}, [])
    assert (await hermes_api(h, "POST", "/v1/present", deck()))[1]["images"] == 1
    first, second = (await next_of(a, "chat"))["presentation"], (await next_of(b, "chat"))["presentation"]
    assert first["items"][0]["image"]["blob_id"] != second["items"][0]["image"]["blob_id"]
    assert await b.fetch_attachment(second["items"][0]["image"]) == await a.fetch_attachment(first["items"][0]["image"])


async def test_oversized_presentation_is_rejected_before_fetching(h) -> None:
    await online_device(h)
    calls: list[str] = []
    h.bridge.presenter.fetch = fake_fetcher({}, calls)
    long = "https://example.com/" + "a" * 970
    item = {
        "title": "t" * 120,
        "subtitle": "s" * 200,
        "detail": "d" * 600,
        "url": long,
        "image_url": long,
        "actions": [{"label": "l" * 30, "url": long}] * 3,
    }
    status, result = await hermes_api(h, "POST", "/v1/present", deck(items=[item] * 10))
    assert (status, result) == (400, {"error": "presentation too large"}) and calls == []
    assert (await hermes_api(h, "POST", "/v1/present", deck(items=[item] * 5)))[0] == 200


async def test_invalid_presentation_is_a_400(h) -> None:
    status, result = await hermes_api(h, "POST", "/v1/present", with_item(url="http://insecure.example"))
    assert status == 400 and "https" in result["error"]
