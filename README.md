# claude-usage-bar

Shows your Claude plan limits (5-hour session and 7-day weekly) in the macOS menu bar, refreshed every 5 minutes.

```
◔ 23% · 41%          ← menu bar (orange at 70%, red at 90%, ⚠ when stale)
─────────────────
5-hour ████░░░░░░░░░░░░░░░░  23.5%
Resets in 2h 14m (16:30)
7-day  ████████░░░░░░░░░░░░  41.2%
Resets in 3d 4h (Mon 09:00)
```

## How it works

```
Claude Code ──stdin JSON──▶ bridge/statusline.py ──▶ ~/.cache/claude-usage-bar/usage.json
                               │                                  │
                               └─▶ prints your status line        ▼
                                              SwiftBar runs swiftbar/claude-usage.5m.py every 5 min
```

- Claude Code passes `rate_limits.five_hour` / `seven_day` to its [status line command](https://code.claude.com/docs/en/statusline). This is a documented feature, so there are no credentials, Keychain reads or undocumented endpoints involved.
- The bridge merges each window into the cache with one rule: usage within a window only goes up. A value is accepted only if it's from a newer window (later `resets_at`) or the same window with a higher percentage. Several open sessions can't clobber each other with older data.
- Once a window's reset time passes, the menu bar shows `0%↺` instead of the old number.

### Limits of this approach

- Numbers update only when a Claude Code session gets a reply. Usage from claude.ai or the desktop app shares the same limits but shows up only after your next Claude Code reply.
- `rate_limits` is present only on Pro/Max plans (or a gateway with a spend limit).
- Using your own OAuth login against the usage endpoint was ruled out: Anthropic's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance) restricts subscription OAuth to Anthropic's own apps.

## Install

```bash
brew install --cask swiftbar   # open it once and choose a plugin folder
./install.sh                   # sets Claude Code's statusLine + links the plugin
```

`install.sh` backs up `~/.claude/settings.json` before changing it and refuses to replace an existing `statusLine` unless you pass `--force`. `./uninstall.sh` reverses both steps.

The plugin is symlinked, so edits in this folder take effect on the next refresh. If this volume isn't mounted, the status line and plugin stop working until it is.

## Settings (environment variables)

| Variable | Default | Used by |
|---|---|---|
| `CLAUDE_USAGE_BAR_CACHE` | `~/.cache/claude-usage-bar/usage.json` | both |
| `CLAUDE_USAGE_BAR_STALE_MIN` | `60` | plugin: minutes without change before ⚠ |

To refresh more or less often, rename the plugin link (e.g. `claude-usage.1m.py`).

## When it breaks

All field parsing lives in `parse_window()` in `bridge/statusline.py`. If Claude Code renames a field, fix it there. To see what Claude Code is sending, temporarily change your `statusLine` command to `tee /tmp/statusline-input.json | <path to bridge>`.

## Tests

```bash
python3 -m unittest discover -s tests -v
```
