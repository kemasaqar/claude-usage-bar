#!/usr/bin/env python3
"""Claude Code status line bridge.

Claude Code runs this as its statusLine command and pipes session JSON on
stdin. We do two things with it:

  1. Merge the plan rate limits (`rate_limits.*`) into a small cache file that
     the SwiftBar plugin reads.
  2. Print a status line for the terminal. If you already had a status line
     when you installed, install.sh saved it in the config file; it gets the
     same input and its output is shown instead of ours.

Merge rule per window (five_hour, seven_day, spend_limit): usage within a
window only goes up, so an incoming value is accepted only if it belongs to a
newer window (later `resets_at`) or the same window with a higher percentage.
That way an idle session holding old data can never overwrite fresher data
written by another session.

Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CACHE_PATH = Path(
    os.environ.get(
        "CLAUDE_USAGE_BAR_CACHE",
        Path.home() / ".cache" / "claude-usage-bar" / "usage.json",
    )
)
# Not in the cache folder: deleting the cache must not lose your status line.
CONFIG_PATH = Path(
    os.environ.get(
        "CLAUDE_USAGE_BAR_CONFIG",
        Path.home() / ".config" / "claude-usage-bar" / "config.json",
    )
)
WINDOWS = ("five_hour", "seven_day", "spend_limit")
CHAIN_TIMEOUT_S = 5


def load_cache(path: Path) -> dict:
    try:
        with path.open() as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_cache(path: Path, data: dict) -> None:
    """Atomic write so the menu bar never reads a half-written file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".usage-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def parse_window(raw) -> dict | None:
    """Keep only the fields we use; reject anything malformed."""
    if not isinstance(raw, dict):
        return None
    pct = raw.get("used_percentage")
    resets_at = raw.get("resets_at")
    if not isinstance(pct, (int, float)) or not isinstance(resets_at, (int, float)):
        return None
    out = {"used_percentage": float(pct), "resets_at": int(resets_at)}
    for key in ("used_usd", "limit_usd", "period"):
        if key in raw:
            out[key] = raw[key]
    return out


def is_newer(incoming: dict, current: dict | None) -> bool:
    if current is None:
        return True
    if incoming["resets_at"] != current.get("resets_at"):
        return incoming["resets_at"] > current.get("resets_at", 0)
    return incoming["used_percentage"] > current.get("used_percentage", -1)


def merge(cache: dict, rate_limits: dict, now: float) -> bool:
    """Merge incoming windows into cache in place. Returns True if anything changed."""
    windows = cache.setdefault("windows", {})
    changed = False
    for name in WINDOWS:
        incoming = parse_window(rate_limits.get(name))
        if incoming is None:
            continue
        if is_newer(incoming, windows.get(name)):
            incoming["seen_at"] = int(now)
            windows[name] = incoming
            changed = True
    if changed:
        cache["schema"] = 1
        cache["updated_at"] = int(now)
    return changed


def update_cache(rate_limits: dict, now: float, path: Path = CACHE_PATH) -> None:
    """Merge a fresh reading under a lock (the bridge and probe.py can race).

    `checked_at` records that some source delivered a reading now, even when
    no number changed; probe.py uses it to skip checks that wouldn't add anything.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.parent / ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = load_cache(path)
        merge(cache, rate_limits, now)
        if cache.get("windows"):
            cache["checked_at"] = int(now)
            write_cache(path, cache)


def fmt_duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d{hours}h"
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def render_status_line(payload: dict, now: float) -> str:
    parts = []
    model = (payload.get("model") or {}).get("display_name")
    if model:
        parts.append(model)
    cwd = (payload.get("workspace") or {}).get("current_dir") or payload.get("cwd")
    if cwd:
        parts.append(os.path.basename(cwd.rstrip("/")) or cwd)
    ctx = (payload.get("context_window") or {}).get("used_percentage")
    if isinstance(ctx, (int, float)):
        parts.append(f"ctx {ctx:.0f}%")
    rate_limits = payload.get("rate_limits") or {}
    for name, label in (("five_hour", "5h"), ("seven_day", "7d")):
        w = parse_window(rate_limits.get(name))
        if w:
            left = fmt_duration(w["resets_at"] - now)
            parts.append(f"{label} {w['used_percentage']:.0f}% ({left})")
    return " · ".join(parts)


def run_original(stdin: str) -> str | None:
    """Output of the status line you had before installing, or None if there
    wasn't one or it failed, in which case ours is shown."""
    original = load_cache(CONFIG_PATH).get("original_status_line") or {}
    command = original.get("command") if isinstance(original, dict) else None
    if not isinstance(command, str) or not command.strip():
        return None
    try:
        proc = subprocess.run(
            command, shell=True, input=stdin, capture_output=True, text=True,
            timeout=CHAIN_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = proc.stdout.rstrip("\n")
    return out if proc.returncode == 0 and out else None


def main() -> int:
    now = time.time()
    stdin = sys.stdin.read()
    try:
        payload = json.loads(stdin)
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    rate_limits = payload.get("rate_limits")
    if isinstance(rate_limits, dict):
        try:
            update_cache(rate_limits, now)
        except OSError:
            pass  # never break the status line over a cache problem

    original = run_original(stdin)
    print(original if original is not None else render_status_line(payload, now))
    return 0


if __name__ == "__main__":
    sys.exit(main())
