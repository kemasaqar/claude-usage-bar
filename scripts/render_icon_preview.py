#!/usr/bin/env python3
"""Draw the README's preview images with the plugin's own drawing code:

  docs/icon-levels.png   the icon at 0%, 10% ... 100% usage, enlarged
  docs/menu-bar.svg      the same levels at real size, as the menu bar shows
                         them (icon + "5h · 7d" numbers), icons as base64 PNGs

Re-run after changing ICON_PT, RING_PT or GAP_PT:
    python3 scripts/render_icon_preview.py
"""
from __future__ import annotations

import base64
import importlib.util
import struct
import zlib
from pathlib import Path

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


def main() -> None:
    plugin = load_plugin()
    DOCS.mkdir(exist_ok=True)
    (DOCS / "icon-levels.png").write_bytes(enlarged_strip(plugin))
    (DOCS / "menu-bar.svg").write_text(real_size_svg(plugin))
    print("wrote docs/icon-levels.png and docs/menu-bar.svg")


if __name__ == "__main__":
    main()
