#!/usr/bin/env python3
# <xbar.title>Claude Code Usage</xbar.title>
# <xbar.version>v0.1</xbar.version>
# <xbar.desc>Claude plan limits (5-hour / 7-day) from the Claude Code status line bridge.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
"""SwiftBar plugin: reads the cache written by bridge/statusline.py.

The `.5m.` in the filename makes SwiftBar re-run this every 5 minutes.
Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import base64
import json
import os
import struct
import subprocess
import sys
import time
import zlib
from datetime import datetime
from pathlib import Path

CACHE_PATH = Path(
    os.environ.get(
        "CLAUDE_USAGE_BAR_CACHE",
        Path.home() / ".cache" / "claude-usage-bar" / "usage.json",
    )
)
# The plugin is symlinked into SwiftBar's folder; resolve back to the repo.
PROBE = Path(__file__).resolve().parent.parent / "bridge" / "probe.py"
PAUSE_FLAG = CACHE_PATH.parent / "auto-check-paused"
PROBE_STATE = CACHE_PATH.parent / "probe.json"
# Show a stale marker when nothing has changed for this long.
STALE_AFTER_S = int(os.environ.get("CLAUDE_USAGE_BAR_STALE_MIN", "60")) * 60

LABELS = {"five_hour": "5-hour", "seven_day": "7-day", "spend_limit": "Spend"}
WINDOW_S = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}
# No run-out estimate before this much of a window has passed: a few minutes
# of use would otherwise project something silly.
MIN_ELAPSED_S = {"five_hour": 30 * 60, "seven_day": 12 * 3600}
FONT = "font=Menlo size=12"
# Lines without an action render as disabled (grey) menu items; an explicit
# color keeps them readable. SwiftBar takes "light,dark".
TEXT_COLOR = "#1D1D1F,#F5F5F7"
# Menu bar icon: a circle that works like a battery. Full when nothing is
# used, draining from the top as usage grows, empty at 100%.
ICON_PT = 16     # canvas size in points
ICON_SCALE = 2   # pixels per point, so it stays sharp on Retina screens
RING_PT = 1.5    # outline width
GAP_PT = 1.5     # space between the outline and the fill


WARN_COLOR = "#F5A524"


def color_for(pct: float) -> str:
    if pct >= 90:
        return "#E5484D"
    if pct >= 70:
        return WARN_COLOR
    return ""  # default menu bar color


def bar(pct: float, width: int = 20, mark: float | None = None) -> str:
    """mark (0..1) draws │ where an even pace would put you now."""
    filled = round(max(0.0, min(100.0, pct)) / 100 * width)
    chars = ["█"] * filled + ["░"] * (width - filled)
    if mark is not None:
        chars[min(width - 1, round(max(0.0, min(1.0, mark)) * width))] = "│"
    return "".join(chars)


def elapsed_fraction(name: str, window: dict, now: float) -> float | None:
    length = WINDOW_S.get(name)
    if not length:
        return None
    start = window["resets_at"] - length
    return max(0.0, min(1.0, (now - start) / length))


def runs_out_at(name: str, window: dict, now: float) -> float | None:
    """When usage hits 100% if it keeps its average pace since the window
    started. None if it lasts until the reset, or it's too early to tell."""
    length = WINDOW_S.get(name)
    used = window["used_percentage"]
    if not length or not 0 < used < 100:
        return None
    start = window["resets_at"] - length
    elapsed = now - start
    if elapsed < MIN_ELAPSED_S[name]:
        return None
    out = start + elapsed * 100 / used
    return out if out < window["resets_at"] else None


def icon_alpha(pct: float) -> list[bytearray]:
    """Coverage (0-255) per pixel: a ring, a gap, then a disc filled from the
    bottom up to pct% of its height. 4x4 supersampling smooths the edges."""
    size = ICON_PT * ICON_SCALE
    c = size / 2
    r_out = c - 0.5 * ICON_SCALE  # small margin so the ring isn't clipped
    r_in = r_out - RING_PT * ICON_SCALE
    r_fill = r_in - GAP_PT * ICON_SCALE
    level = c + r_fill - max(0.0, min(100.0, pct)) / 100 * 2 * r_fill
    n = 4
    rows = []
    for py in range(size):
        row = bytearray(size)
        for px in range(size):
            hits = 0
            for sy in range(n):
                y = py + (sy + 0.5) / n
                for sx in range(n):
                    x = px + (sx + 0.5) / n
                    d2 = (x - c) ** 2 + (y - c) ** 2
                    ring = r_in * r_in <= d2 <= r_out * r_out
                    if ring or (d2 <= r_fill * r_fill and y >= level):
                        hits += 1
            row[px] = hits * 255 // (n * n)
        rows.append(row)
    return rows


def png_base64(alpha_rows: list[bytearray]) -> str:
    """Black RGBA PNG with the given alpha. SwiftBar's templateImage tints it
    to match the menu bar. The DPI makes macOS draw it at ICON_PT points."""
    h, w = len(alpha_rows), len(alpha_rows[0])
    raw = b"".join(
        b"\x00" + bytes(v for a in row for v in (0, 0, 0, a)) for row in alpha_rows
    )

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ppm = round(72 * ICON_SCALE / 0.0254)  # pixels per meter
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    return base64.b64encode(png).decode()


def fmt_duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m"


def fmt_clock(ts: float, now: float) -> str:
    dt = datetime.fromtimestamp(ts)
    if ts - now > 20 * 3600:
        return dt.strftime("%a %H:%M")
    return dt.strftime("%H:%M")


def load_cache() -> dict | None:
    try:
        with CACHE_PATH.open() as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def effective_pct(window: dict, now: float) -> tuple[float, bool]:
    """Returns (percentage, has_reset). Once resets_at passes, the stored
    number belongs to an old window, so treat it as 0 until fresh data arrives."""
    if window["resets_at"] <= now:
        return 0.0, True
    return float(window["used_percentage"]), False


def start_auto_check() -> None:
    """Fire and forget; probe.py decides whether a check is actually needed."""
    if PAUSE_FLAG.exists() or not PROBE.exists():
        return
    try:
        subprocess.Popen(
            [sys.executable, str(PROBE), "--auto"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        pass


def print_auto_check_menu(now: float) -> None:
    try:
        with PROBE_STATE.open() as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    paused = PAUSE_FLAG.exists()
    status = "paused" if paused else "on"
    if not paused and state.get("skipped", "").startswith("idle"):
        status += " · idle, waiting for activity"
    if state.get("last_run"):
        mark = "✓" if state.get("ok") else "✗"
        status += f" · last check {fmt_duration(now - state['last_run'])} ago {mark}"
    print(f"Auto-check: {status} | size=11")
    if state.get("last_run") and not state.get("ok") and state.get("error"):
        print(f"--{state['error']} | size=11")
    action = "--resume" if paused else "--pause"
    label = "Resume auto-check" if paused else "Pause auto-check"
    print(f"{label} | bash={PROBE} param1={action} terminal=false refresh=true")
    print(f"Check now | bash={PROBE} param1=--now terminal=false refresh=true")


def print_setup_help(now: float) -> None:
    print(f"– | templateImage={png_base64(icon_alpha(0))}")
    print("---")
    print("No usage data yet")
    print(f"Waiting for {CACHE_PATH}")
    print("--Send a message in Claude Code, or use Check now.")
    print("--Limits appear only on Pro/Max plans.")
    print("---")
    print_auto_check_menu(now)
    print("Refresh | refresh=true")


def main() -> None:
    now = time.time()
    start_auto_check()
    cache = load_cache()
    windows = (cache or {}).get("windows") or {}
    if not windows:
        print_setup_help(now)
        return

    updated_at = cache.get("updated_at", 0)
    # Stale means no reading arrived lately, not that the numbers didn't move.
    checked_at = max(cache.get("checked_at", 0), updated_at)
    stale = now - checked_at > STALE_AFTER_S

    rows = []
    for name in ("five_hour", "seven_day", "spend_limit"):
        w = windows.get(name)
        if not isinstance(w, dict) or "resets_at" not in w:
            continue
        pct, has_reset = effective_pct(w, now)
        out = None if has_reset else runs_out_at(name, w, now)
        rows.append((name, w, pct, has_reset, out))

    # Title: 5h and 7d percentages, colored by the worse of the two.
    # ↗ marks a window that runs out before its reset at the current pace.
    title_parts = []
    worst = 0.0
    heading_over = False
    for name, _w, pct, has_reset, out in rows:
        if name == "spend_limit":
            continue
        title_parts.append(f"{pct:.0f}%" + ("↺" if has_reset else "") + ("↗" if out else ""))
        worst = max(worst, pct)
        heading_over = heading_over or out is not None
    title = " · ".join(title_parts) or "–"
    if stale:
        title += " ⚠"
    attrs = [f"templateImage={png_base64(icon_alpha(100 - worst))}"]
    color = color_for(worst) or (WARN_COLOR if heading_over else "")
    if color:
        attrs.append(f"color={color}")
    print(f"{title} | {' '.join(attrs)}")

    print("---")
    for name, w, pct, has_reset, out in rows:
        label = LABELS[name]
        c = color_for(pct) or TEXT_COLOR
        mark = None if has_reset else elapsed_fraction(name, w, now)
        print(f"{label:<7}{bar(pct, mark=mark)} {pct:5.1f}% | {FONT} color={c}")
        info = f"size=11 color={TEXT_COLOR}"
        if has_reset:
            print(f"Window has reset (0% until the next reading) | {info}")
        else:
            left = fmt_duration(w["resets_at"] - now)
            line = f"Resets in {left} ({fmt_clock(w['resets_at'], now)})"
            if out:
                # SwiftBar colors whole lines, so the whole line turns orange.
                print(f"{line} · runs out ~{fmt_clock(out, now)} | size=11 color={WARN_COLOR}")
            else:
                print(f"{line} | {info}")
        if name == "spend_limit" and "used_usd" in w and "limit_usd" in w:
            print(f"${w['used_usd']:.2f} of ${w['limit_usd']:.2f} {w.get('period', '')} | {info}")

    print("---")
    ago = fmt_duration(now - checked_at)
    print(f"Last reading {ago} ago" + (" (stale)" if stale else "") + " | size=11")
    if stale:
        print(f"--No reading in the last {STALE_AFTER_S // 60}m. Checks pause while you're | size=11")
        print("--idle with no open 5-hour window, so a check doesn't start one. | size=11")
    print("---")
    print_auto_check_menu(now)
    print("Refresh | refresh=true")
    print(f"Open cache file | bash=/usr/bin/open param1=-R param2={CACHE_PATH} terminal=false")


if __name__ == "__main__":
    main()
