#!/usr/bin/env python3
"""Draw the README's preview images with the plugin's own drawing code:

  docs/icon-levels.png   the icon at 0%, 10% ... 100% usage, enlarged
  docs/menu-bar.svg      the same levels at real size, as the menu bar shows
                         them (icon + "5h · 7d" numbers), icons as base64 PNGs
  docs/menu-*.svg        the open menu, drawn from the plugin's real output
                         for a few usage situations (a throwaway cache each)

Re-run after changing the icon or what the menu shows:
    python3 scripts/render_previews.py
"""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
BG = (0x3E, 0x68, 0xA6)
LEVELS = range(0, 101, 10)
WEEKLY = 13  # second number in the real-size example


def load_plugin():
    spec = importlib.util.spec_from_file_location(
        "plugin", ROOT / "swiftbar" / "claude-usage.5m.py"
    )
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    return plugin


def png_bytes(rows: list[bytearray], color_type: int) -> bytes:
    """color_type 2 = RGB rows, 6 = RGBA rows."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    w, h = len(rows[0]) // (3 if color_type == 2 else 4), len(rows)
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def icons(plugin, scale: int) -> list[list[bytearray]]:
    plugin.ICON_SCALE = scale
    return [plugin.icon_alpha(100 - used) for used in LEVELS]


def enlarged_strip(plugin) -> bytes:
    pad, gap = 24, 28
    alphas = icons(plugin, 4)  # 4 px per point: large and crisp
    size = len(alphas[0])
    width = 2 * pad + len(alphas) * size + (len(alphas) - 1) * gap
    rows = [bytearray(BG * width) for _ in range(size + 2 * pad)]
    for i, alpha in enumerate(alphas):
        x0 = pad + i * (size + gap)
        for y, arow in enumerate(alpha):
            row = rows[pad + y]
            for x, a in enumerate(arow):
                for ch in range(3):  # white over the background
                    bg = BG[ch]
                    row[(x0 + x) * 3 + ch] = bg + (255 - bg) * a // 255
    return png_bytes(rows, 2)


def real_size_svg(plugin) -> str:
    """Two rows of menu bar items at real size: 16pt icons, 13px text.
    Icons are 2x PNGs so they stay sharp on Retina screens."""
    per_row, slot, pad, row_h = 6, 100, 14, 26
    pt = plugin.ICON_PT
    items = []
    for i, (used, alpha) in enumerate(zip(LEVELS, icons(plugin, 2))):
        x = pad + (i % per_row) * slot
        y = pad + (i // per_row) * row_h
        white = [bytearray(v for a in row for v in (255, 255, 255, a)) for row in alpha]
        data = base64.b64encode(png_bytes(white, 6)).decode()
        color = plugin.color_for(used) or "#FFFFFF"
        items.append(
            f'<image x="{x}" y="{y + (row_h - pt) / 2}" width="{pt}" height="{pt}" '
            f'href="data:image/png;base64,{data}"/>'
            f'<text x="{x + pt + 4}" y="{y + row_h / 2 + 4.5}" fill="{color}">'
            f"{used}% · {WEEKLY}%</text>"
        )
    rows = -(-len(LEVELS) // per_row)
    width, height = 2 * pad + per_row * slot - 14, 2 * pad + rows * row_h
    bg = "#{:02X}{:02X}{:02X}".format(*BG)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">'
        f'<rect width="{width}" height="{height}" rx="8" fill="{bg}"/>'
        f'<g font-family="-apple-system, BlinkMacSystemFont, \'Helvetica Neue\', '
        f'Helvetica, Arial, sans-serif" font-size="13">'
        + "".join(items)
        + "</g></svg>\n"
    )


H, DAY = 3600, 86400
# name -> {window: (used %, seconds since the window started)}
MENU_SCENARIOS = {
    "heading-over": {"five_hour": (48, 2 * H), "seven_day": (41, 3 * DAY + 20 * H)},
    "on-track": {"five_hour": (22, 2 * H), "seven_day": (30, 3 * DAY + 12 * H)},
}
WINDOW_LEN = {"five_hour": 5 * H, "seven_day": 7 * DAY}


def plugin_output(windows: dict) -> str:
    """Runs the real plugin against a throwaway cache. The reading is fresh,
    so its background auto-check skips and nothing reaches Claude."""
    # 30s of slack so "Resets in 3h 00m" doesn't read 2h 59m by the time
    # the plugin runs.
    now = int(time.time()) + 30
    with tempfile.TemporaryDirectory() as tmp:
        cache = Path(tmp) / "usage.json"
        cache.write_text(json.dumps({
            "updated_at": now, "checked_at": now,
            "windows": {
                name: {"used_percentage": used, "resets_at": now + WINDOW_LEN[name] - elapsed}
                for name, (used, elapsed) in windows.items()
            },
        }))
        (Path(tmp) / "projects").mkdir()
        env = {
            **os.environ,
            "CLAUDE_USAGE_BAR_CACHE": str(cache),
            "CLAUDE_USAGE_BAR_CONFIG": str(Path(tmp) / "config.json"),
            "CLAUDE_USAGE_BAR_PROJECTS": str(Path(tmp) / "projects"),
            "CLAUDE_USAGE_BAR_CLAUDE": str(Path(tmp) / "no-claude"),
            "CLAUDE_USAGE_BAR_REFRESH_URL": "",
        }
        return subprocess.run(
            [sys.executable, str(ROOT / "swiftbar" / "claude-usage.5m.py")],
            env=env, capture_output=True, text=True, check=True,
        ).stdout


def parse_line(line: str) -> tuple[str, dict]:
    text, _, attrs = line.partition(" | ")
    return text, dict(a.split("=", 1) for a in attrs.split() if "=" in a)


def dark(color: str | None, default: str = "#F5F5F7") -> str:
    """SwiftBar colors are "light,dark"; draw the dark-mode one."""
    return color.split(",")[-1] if color else default


def menu_svg(output: str) -> str:
    """The menu bar item and its open menu, dark mode, from SwiftBar output.
    Top-level lines only; submenus ("--") and the cache-file item are left out."""
    lines = output.splitlines()
    title, title_attrs = parse_line(lines[0])
    width, pad, y = 360, 14, 0
    parts = []
    # Menu bar item: white icon (the template PNG recolored) + title.
    parts.append(f'<rect width="{width}" height="26" rx="6" fill="#3E68A6"/>')
    parts.append(
        f'<image x="{pad}" y="5" width="16" height="16" filter="url(#white)" '
        f'href="data:image/png;base64,{title_attrs["templateImage"]}"/>'
    )
    parts.append(
        f'<text x="{pad + 21}" y="17.5" font-size="13" '
        f'fill="{dark(title_attrs.get("color"), "#FFFFFF")}">{escape(title)}</text>'
    )
    y = 34
    body = []
    for line in lines[2:]:  # skip the title and its "---"
        if line.startswith("--") and line != "---":
            continue
        if line == "---":
            body.append(f'<line x1="0" x2="{width}" y1="{y + 5}" y2="{y + 5}" stroke="#48484A"/>')
            y += 10
            continue
        text, attrs = parse_line(line)
        if text.startswith("Open cache file"):
            continue
        mono = attrs.get("font") == "Menlo"
        size = int(attrs.get("size", 13))
        family = "Menlo, ui-monospace, monospace" if mono else "inherit"
        body.append(
            f'<text x="{pad}" y="{y + size + 3}" font-size="{size}" font-family="{family}" '
            f'xml:space="preserve" fill="{dark(attrs.get("color"))}">{escape(text)}</text>'
        )
        y += size + 9
    height = y + 8
    panel = f'<rect y="30" width="{width}" height="{height - 30}" rx="8" fill="#2A2A2C"/>'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">'
        '<defs><filter id="white"><feColorMatrix type="matrix" '
        'values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 1 0"/></filter></defs>'
        f'<g font-family="-apple-system, BlinkMacSystemFont, \'Helvetica Neue\', '
        f'Helvetica, Arial, sans-serif">'
        + "".join(parts) + panel + "".join(body)
        + "</g></svg>\n"
    )


def main() -> None:
    plugin = load_plugin()
    DOCS.mkdir(exist_ok=True)
    (DOCS / "icon-levels.png").write_bytes(enlarged_strip(plugin))
    (DOCS / "menu-bar.svg").write_text(real_size_svg(plugin))
    written = ["icon-levels.png", "menu-bar.svg"]
    for name, windows in MENU_SCENARIOS.items():
        (DOCS / f"menu-{name}.svg").write_text(menu_svg(plugin_output(windows)))
        written.append(f"menu-{name}.svg")
    print("wrote " + ", ".join(f"docs/{w}" for w in written))


if __name__ == "__main__":
    main()
