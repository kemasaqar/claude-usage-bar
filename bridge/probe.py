#!/usr/bin/env python3
"""Fetch plan limits with a tiny headless Claude Code request.

The status line only runs in terminal sessions. When you work in the desktop
app or an editor panel, nothing refreshes the cache, so this runs

    claude -p --model haiku --tools "" --system-prompt "Reply with ok." ...

and reads the `rate_limit_event` from its stream-json output. It costs roughly
a thousand Haiku tokens and saves no session.

  probe.py --auto    check if the last reading is older than the interval and
                     either a 5-hour window is open or a Claude Code session
                     was active since (the SwiftBar plugin calls this every refresh)
  probe.py --now     check right away (ignores pause)
  probe.py --pause   stop automatic checks
  probe.py --resume  allow automatic checks again

Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from statusline import CACHE_PATH, load_cache, update_cache, write_cache  # noqa: E402

STATE_DIR = CACHE_PATH.parent
PAUSE_FLAG = STATE_DIR / "auto-check-paused"
PROBE_STATE = STATE_DIR / "probe.json"
PROBE_CWD = STATE_DIR / "probe-cwd"
PROJECTS_DIR = Path(
    os.environ.get("CLAUDE_USAGE_BAR_PROJECTS", Path.home() / ".claude" / "projects")
)
INTERVAL_S = int(os.environ.get("CLAUDE_USAGE_BAR_PROBE_MIN", "5")) * 60
TIMEOUT_S = float(os.environ.get("CLAUDE_USAGE_BAR_PROBE_TIMEOUT_S", "90"))
# Redraw the menu bar as soon as a check finishes instead of on the next
# 5-minute refresh. The redraw's own --auto run skips ("recent reading"),
# so this can't loop. Set to "" to disable.
REFRESH_URL = os.environ.get(
    "CLAUDE_USAGE_BAR_REFRESH_URL", "swiftbar://refreshplugin?name=claude-usage"
)

CLAUDE_CANDIDATES = (
    shutil.which("claude") or "",
    str(Path.home() / ".local" / "bin" / "claude"),
    str(Path.home() / ".claude" / "local" / "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
)


def find_claude() -> str | None:
    """CLAUDE_USAGE_BAR_CLAUDE, if set, is the only one tried: a wrong path
    should show up as an error, not quietly fall back to another claude."""
    override = os.environ.get("CLAUDE_USAGE_BAR_CLAUDE")
    for path in (override,) if override else CLAUDE_CANDIDATES:
        if path and os.access(path, os.X_OK):
            return path
    return None


def windows_from_event(info: dict) -> dict:
    """rate_limit_info.unifiedWindows -> the status line's rate_limits shape.
    utilization is a 0..1 fraction here; the status line uses 0..100."""
    out = {}
    for name, w in (info.get("unifiedWindows") or {}).items():
        if not isinstance(w, dict):
            continue
        util, resets_at = w.get("utilization"), w.get("resetsAt")
        if isinstance(util, (int, float)) and isinstance(resets_at, (int, float)):
            out[name] = {"used_percentage": round(util * 100, 1), "resets_at": resets_at}
    return out


def run_claude(claude: str) -> dict:
    """Returns rate_limits from one headless request. Raises RuntimeError."""
    PROBE_CWD.mkdir(parents=True, exist_ok=True)
    cmd = [
        claude, "-p",
        "--model", "haiku",
        "--output-format", "stream-json", "--verbose",
        "--max-turns", "1",
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "project",  # empty probe-cwd: skips your hooks and plugins
        "--disable-slash-commands",
        "--no-session-persistence",
        "--system-prompt", "Reply with ok.",
        "ok",
    ]
    try:
        proc = subprocess.run(
            cmd, cwd=PROBE_CWD, capture_output=True, text=True,
            timeout=TIMEOUT_S, stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"claude timed out after {TIMEOUT_S}s")
    rate_limits = {}
    for line in proc.stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("type") == "rate_limit_event":
            rate_limits.update(windows_from_event(event.get("rate_limit_info") or {}))
    if rate_limits:
        return rate_limits
    detail = (proc.stderr or proc.stdout).strip().splitlines()
    raise RuntimeError(detail[-1][:200] if detail else f"no rate_limit_event (exit {proc.returncode})")


def last_activity() -> float:
    """Newest transcript write across all Claude Code sessions, any app."""
    newest = 0.0
    try:
        projects = list(os.scandir(PROJECTS_DIR))
    except OSError:
        return 0.0
    for project in projects:
        if not project.is_dir():
            continue
        try:
            for entry in os.scandir(project.path):
                if entry.name.endswith(".jsonl"):
                    newest = max(newest, entry.stat().st_mtime)
        except OSError:
            continue
    return newest


def load_state() -> dict:
    try:
        with PROBE_STATE.open() as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


IDLE_REASON = "idle, no open 5-hour window"


def should_auto_check(now: float) -> tuple[bool, str]:
    """Check every interval while a 5-hour window is open or you're active.

    When idle with no open window, a request would itself start a new 5-hour
    window and shift your reset times, so wait for real activity instead."""
    if PAUSE_FLAG.exists():
        return False, "paused"
    cache = load_cache(CACHE_PATH)
    last_reading = max(cache.get("checked_at", 0), load_state().get("last_run", 0))
    if now - last_reading < INTERVAL_S:
        return False, "recent reading"
    if last_activity() > last_reading:
        return True, "activity since last reading"
    five_hour = (cache.get("windows") or {}).get("five_hour") or {}
    if five_hour.get("resets_at", 0) > now:
        return True, "5-hour window open"
    return False, IDLE_REASON


def check(now: float) -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_DIR / ".probe-lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("another check is already running")
            return 0
        state = {"last_run": int(now)}
        claude = find_claude()
        try:
            if not claude:
                raise RuntimeError("claude not found; set CLAUDE_USAGE_BAR_CLAUDE")
            rate_limits = run_claude(claude)
            update_cache(rate_limits, time.time())
            state["ok"] = True
            print("ok:", json.dumps(rate_limits))
        except (RuntimeError, OSError) as e:
            state.update(ok=False, error=str(e))
            print("error:", e, file=sys.stderr)
        write_cache(PROBE_STATE, state)
    request_redraw()
    return 0 if state["ok"] else 1


def request_redraw() -> None:
    if not REFRESH_URL:
        return
    try:
        subprocess.run(["/usr/bin/open", "-g", REFRESH_URL], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--auto", action="store_true")
    mode.add_argument("--now", action="store_true")
    mode.add_argument("--pause", action="store_true")
    mode.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    now = time.time()

    if args.pause:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        PAUSE_FLAG.touch()
        print("auto-check paused")
        return 0
    if args.resume:
        PAUSE_FLAG.unlink(missing_ok=True)
        print("auto-check resumed")
        return 0
    if args.auto:
        go, why = should_auto_check(now)
        if not go:
            print("skipped:", why)
            state = load_state()
            if state.get("skipped") != why and why != "recent reading":
                state["skipped"] = why  # shown in the menu
                write_cache(PROBE_STATE, state)
            return 0
    return check(now)


if __name__ == "__main__":
    sys.exit(main())
