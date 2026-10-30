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

import json
import os
import subprocess
import sys
import time
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
FONT = "font=Menlo size=12"
# Lines without an action render as disabled (grey) menu items; an explicit
# color keeps them readable. SwiftBar takes "light,dark".
TEXT_COLOR = "#1D1D1F,#F5F5F7"


def color_for(pct: float) -> str:
    if pct >= 90:
        return "#E5484D"
    if pct >= 70:
        return "#F5A524"
    return ""  # default menu bar color


def bar(pct: float, width: int = 20) -> str:
    filled = round(max(0.0, min(100.0, pct)) / 100 * width)
    return "█" * filled + "░" * (width - filled)


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
    print("✳ – | sfimage=gauge.with.dots.needle.0percent")
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
        rows.append((name, w, pct, has_reset))

    # Title: 5h and 7d percentages, colored by the worse of the two.
    title_parts = []
    worst = 0.0
    for name, _w, pct, has_reset in rows:
        if name == "spend_limit":
            continue
        title_parts.append(f"{pct:.0f}%" + ("↺" if has_reset else ""))
        worst = max(worst, pct)
    title = " · ".join(title_parts) or "–"
    if stale:
        title += " ⚠"
    needle = min((0, 33, 50, 67, 100), key=lambda n: abs(n - worst))
    attrs = [f"sfimage=gauge.with.dots.needle.{needle}percent"]
    color = color_for(worst)
    if color:
        attrs.append(f"color={color}")
    print(f"{title} | {' '.join(attrs)}")

    print("---")
    for name, w, pct, has_reset in rows:
        label = LABELS[name]
        c = color_for(pct) or TEXT_COLOR
        print(f"{label:<7}{bar(pct)} {pct:5.1f}% | {FONT} color={c}")
        info = f"size=11 color={TEXT_COLOR}"
        if has_reset:
            print(f"Window has reset (0% until the next reading) | {info}")
        else:
            left = fmt_duration(w["resets_at"] - now)
            print(f"Resets in {left} ({fmt_clock(w['resets_at'], now)}) | {info}")
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
