#!/usr/bin/env python3
"""Builds the app icons as Icon Composer documents (.icon: icon.json + SVG layers).

iOS 26/27 render these themselves: Liquid Glass, specular highlights, and the dark, clear and
tinted appearances. All artwork is original and generated here.

    python3 tools/make_icons.py            # write ios/HermesCall/Resources/*.icon
    python3 tools/make_icons.py --preview  # also render PNG previews with Xcode's ictool

AppIcon         Standard: a handset in an orbit with a spark, white glass on warm amber.
AppIconPresence Presence: the gold orrery (rings of data blocks around a filament heart) on black.
"""

import json
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "HermesCall" / "Resources"
WATCH_OUT = ROOT / "ios" / "HermesCallWatch"
C = 512.0  # canvas centre (1024 × 1024 points)

GOLD = "#FFA629"
LIGHT = "#FFE9B0"
EMBER = "#6B2A05"


def svg(body: str, defs: str = "") -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f"<defs>{defs}</defs>{body}</svg>\n"
    )


def poly(points, fill, opacity=1.0) -> str:
    d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in points) + " Z"
    return f'<path d="{d}" fill="{fill}" fill-opacity="{opacity:.3f}"/>'


def core(radius: float = 230) -> str:
    """The heart's soft glow (not glass, so no disc edge shows)."""
    defs = (
        '<radialGradient id="core" cx="0.5" cy="0.5" r="0.5">'
        '<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.22" stop-color="#FFF4D6"/>'
        f'<stop offset="0.5" stop-color="{GOLD}" stop-opacity="0.85"/>'
        f'<stop offset="1" stop-color="{GOLD}" stop-opacity="0"/></radialGradient>'
    )
    return svg(f'<circle cx="{C}" cy="{C}" r="{radius}" fill="url(#core)"/>', defs)


# MARK: standard geometry


def rounded_rect(cx, cy, length, width, radius, angle, xf):
    """Points of a rounded rectangle centred at (cx, cy), long side along `angle`."""
    pts = []
    hl, hw = length / 2 - radius, width / 2 - radius
    for ox, oy, start in ((hl, hw, 0), (-hl, hw, 90), (-hl, -hw, 180), (hl, -hw, 270)):
        for k in range(9):
            t = math.radians(start + 90 * k / 8)
            x, y = ox + radius * math.cos(t), oy + radius * math.sin(t)
            rx = cx + x * math.cos(angle) - y * math.sin(angle)
            ry = cy + x * math.sin(angle) + y * math.cos(angle)
            pts.append(xf(rx, ry))
    return pts


def handset(scale=1.0, cx=C, cy=C, rotate=math.pi / 4):
    """A classic handset: a curved grip with rounded ear and mouth pads."""

    def xf(x, y):
        c, s_ = math.cos(rotate), math.sin(rotate)
        return cx + (x * c - y * s_) * scale, cy + (x * s_ + y * c) * scale

    hub_y, radius, width = 150.0, 250.0, 92.0
    a0, a1 = math.radians(212), math.radians(328)
    steps = 48
    outer = [
        xf(
            math.cos(a0 + (a1 - a0) * i / steps) * (radius + width / 2),
            hub_y + math.sin(a0 + (a1 - a0) * i / steps) * (radius + width / 2),
        )
        for i in range(steps + 1)
    ]
    inner = [
        xf(
            math.cos(a1 - (a1 - a0) * i / steps) * (radius - width / 2),
            hub_y + math.sin(a1 - (a1 - a0) * i / steps) * (radius - width / 2),
        )
        for i in range(steps + 1)
    ]
    parts = [poly(outer + inner, "#FFFFFF")]
    for angle in (a0, a1):
        # pad: a rounded block reaching inward from the grip's end
        inward = angle + math.pi
        px = math.cos(angle) * (radius - 30) + math.cos(inward) * 20
        py = hub_y + math.sin(angle) * (radius - 30) + math.sin(inward) * 20
        parts.append(poly(rounded_rect(px, py, 150, 140, 52, inward, xf), "#FFFFFF"))
    return "".join(parts)


def orbit_band(rx=392, ry=156, tilt=0.42, width=38, front=None, color="#FFFFFF", opacity=1.0, cx=C, cy=C):
    """An elliptical band; `front` True/False keeps only the half in front of / behind the glyph."""
    ct, st = math.cos(tilt), math.sin(tilt)
    steps = 180
    lo, hi = 0.0, 2 * math.pi
    if front is True:
        lo, hi = 0.0, math.pi
    elif front is False:
        lo, hi = math.pi, 2 * math.pi

    def pt(a, r_off):
        x, y = (rx + r_off) * math.cos(a), (ry + r_off) * math.sin(a)
        return cx + x * ct - y * st, cy + x * st + y * ct

    outer = [pt(lo + (hi - lo) * i / steps, width / 2) for i in range(steps + 1)]
    inner = [pt(hi - (hi - lo) * i / steps, -width / 2) for i in range(steps + 1)]
    return poly(outer + inner, color, opacity)


def band_blocks(rx, ry, tilt, width, angles, span=0.09, color=LIGHT):
    """Bright "data blocks" sitting on a band (slightly wider than it)."""
    ct, st = math.cos(tilt), math.sin(tilt)
    parts = []
    for center in angles:

        def pt(a, r_off):
            x, y = (rx + r_off) * math.cos(a), (ry + r_off) * math.sin(a)
            return C + x * ct - y * st, C + x * st + y * ct

        a0, a1 = center - span / 2, center + span / 2
        outer = [pt(a0 + (a1 - a0) * i / 8, width * 0.62) for i in range(9)]
        inner = [pt(a1 - (a1 - a0) * i / 8, -width * 0.62) for i in range(9)]
        parts.append(poly(outer + inner, color))
    return "".join(parts)


def spark(rx=392, ry=156, tilt=0.42, angle=-0.55, r=58):
    ct, st = math.cos(tilt), math.sin(tilt)
    x, y = rx * math.cos(angle), ry * math.sin(angle)
    return f'<circle cx="{C + x * ct - y * st:.2f}" cy="{C + x * st + y * ct:.2f}" r="{r}" fill="#FFFFFF"/>'


# MARK: documents


def layer(name, image, glass=False, opacity=None, blend=None, fill=None, specializations=None):
    entry = {"image-name": image, "name": name, "glass": glass, "position": {"scale": 1, "translation-in-points": [0, 0]}}
    if opacity is not None:
        entry["opacity"] = opacity
    if blend:
        entry["blend-mode"] = blend
    if fill:
        entry["fill"] = fill
    if specializations:
        entry.update(specializations)
    return entry


def group(layers, shadow="neutral", translucency=0.4, specular=True, lighting=None):
    entry = {
        "layers": layers,
        "shadow": {"kind": shadow, "opacity": 0.5},
        "translucency": {"enabled": translucency > 0, "value": translucency},
        "specular": specular,
    }
    if lighting:
        entry["lighting"] = lighting
    return entry


def write_icon(path: Path, doc: dict, assets: dict):
    if path.exists():
        shutil.rmtree(path)
    (path / "Assets").mkdir(parents=True)
    for name, content in assets.items():
        (path / "Assets" / name).write_text(content)
    (path / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


ORBITS = [
    # rx, ry, tilt, band width, block angles (front half is 0…π)
    (400, 128, -0.40, 22, [0.9, 2.1]),
    (330, 150, 0.70, 20, [1.4, 2.6]),
]


def presence_icon(path: Path):
    back = "".join(orbit_band(rx, ry, tilt, w, front=False, color=GOLD, opacity=0.5) for rx, ry, tilt, w, _ in ORBITS)
    front = "".join(
        orbit_band(rx, ry, tilt, w, front=True, color=GOLD) + band_blocks(rx, ry, tilt, w, blocks)
        for rx, ry, tilt, w, blocks in ORBITS
    )
    orb_defs = (
        '<radialGradient id="orb" cx="0.42" cy="0.38" r="0.62">'
        '<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.35" stop-color="#FFF1CC"/>'
        f'<stop offset="1" stop-color="{GOLD}"/></radialGradient>'
    )
    assets = {
        "rings-back.svg": svg(back),
        "glow.svg": core(),
        "rings-front.svg": svg(front),
        "orb.svg": svg(f'<circle cx="{C}" cy="{C}" r="96" fill="url(#orb)"/>', orb_defs),
    }
    doc = {
        "fill": {"linear-gradient": ["srgb:0.12000,0.06000,0.02000,1.00000", "srgb:0.00000,0.00000,0.00000,1.00000"]},
        "groups": [
            # front to back (Icon Composer lists the top group first)
            group([layer("rings-front", "rings-front.svg", glass=True)], translucency=0.15),
            group([layer("orb", "orb.svg", glass=True)], shadow="layer-color", translucency=0.0),
            group([layer("glow", "glow.svg", glass=False)], shadow="none", translucency=0.0, specular=False),
            group([layer("rings-back", "rings-back.svg", glass=False)], shadow="none", translucency=0.0, specular=False),
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    write_icon(path, doc, assets)


def standard_icon(path: Path):
    assets = {
        "orbit-front.svg": svg(orbit_band(front=True) + spark()),
        "handset.svg": svg(handset(scale=0.98, cx=C - 8, cy=C + 26)),
        "orbit-back.svg": svg(orbit_band(front=False)),
    }
    white = {"fill": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"}}
    doc = {
        "fill": {"linear-gradient": ["srgb:1.00000,0.76000,0.32000,1.00000", "srgb:0.90000,0.36000,0.06000,1.00000"]},
        "fill-specializations": [
            {
                "appearance": "dark",
                "value": {"linear-gradient": ["srgb:0.16000,0.09000,0.04000,1.00000", "srgb:0.03000,0.02000,0.01500,1.00000"]},
            },
        ],
        "groups": [
            group([layer("orbit-front", "orbit-front.svg", glass=True, **white)], translucency=0.3),
            group([layer("handset", "handset.svg", glass=True, **white)], translucency=0.25),
            group([layer("orbit-back", "orbit-back.svg", glass=True, opacity=0.75, **white)], translucency=0.5),
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    write_icon(path, doc, assets)


ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"


def preview(icon: Path, out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    for rendition in ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]:
        out = out_dir / f"{icon.stem}-{rendition}.png"
        cmd = [
            ICTOOL,
            str(icon),
            "--export-image",
            "--output-file",
            str(out),
            "--platform",
            "iOS",
            "--rendition",
            rendition,
            "--width",
            "512",
            "--height",
            "512",
            "--scale",
            "1",
            "--design-generation",
            "27",
        ]
        if rendition.startswith("Tinted"):
            cmd += ["--tint-color", "0.1", "--tint-strength", "0.8"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(rendition, result.stderr.strip() or result.stdout.strip())


if __name__ == "__main__":
    standard = OUT / "AppIcon.icon"
    presence = OUT / "AppIconPresence.icon"
    standard_icon(standard)
    presence_icon(presence)
    # The watch app shows the presence (watchOS masks it to a circle).
    presence_icon(WATCH_OUT / "AppIcon.icon")
    print("wrote", standard, presence)
    # Settings shows both icons as tiles: small renders from the real documents.
    catalog = OUT / "Assets.xcassets"
    for icon, name in ((standard, "IconPreviewStandard"), (presence, "IconPreviewPresence")):
        folder = catalog / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                ICTOOL,
                str(icon),
                "--export-image",
                "--output-file",
                str(folder / f"{name}.png"),
                "--platform",
                "iOS",
                "--rendition",
                "Default",
                "--width",
                "128",
                "--height",
                "128",
                "--scale",
                "2",
                "--design-generation",
                "27",
            ],
            check=True,
            capture_output=True,
        )
    if "--preview" in sys.argv:
        out = Path(tempfile.gettempdir()) / "icon-previews"
        preview(standard, out)
        preview(presence, out)
        print("previews in", out)
