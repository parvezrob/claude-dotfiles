# dotfiles

Personal dev-environment config, version-controlled so it can be synced across machines.

## Claude Code status line

A two-line status line for [Claude Code](https://code.claude.com), showing context
usage, rate limits, this session's work, token totals, cache health and cost.

```
ctx 427k/1M (42%) · session 45% ↻ 2h26m · week 10% ↻ 6d                                Opus 4.8 1M
PR#42 ✓ · +3109 -698 lines · tok in 5.3B out 7.7M ⣀⣤⣶⣿ · sub 41% · cache 99% · warm 47m · ≈$4.1k   xhigh·think
```

**Line 1 — capacity & limits** (model name pinned right):
- `ctx 427k/1M (42%)` — context window used / max, with percent. Colors: teal < 80%, amber 80–89%, red ≥ 90%.
- `session 45% ↻ 2h26m` — 5-hour rate-limit usage + time until reset.
- `week 10% ↻ 6d` — 7-day rate-limit usage + time until reset.
- `Opus 4.8 1M` — model name, flush right.

**Line 2 — this session's work** (effort pinned right):
- `PR#42 ✓` — PR number + review state (`✓` approved / `✗` changes requested), when a PR is detected.
- `+3109 -698 lines` — lines added/removed this session.
- `tok in 5.3B out 7.7M` — total input/output tokens this session (main + subagents), from the
  [token-ledger mod](#token-ledger-mod). Shows `tok counting…` while it back-fills a resumed session.
- `⣀⣤⣶⣿` — sparkline of output tokens for the last 16 main-conversation requests.
- `sub 41%` — share of tokens spent by subagents.
- `cache 99%` — prompt-cache hit ratio. Colors: teal ≥ 90%, amber 50–89%, red < 50%.
- `warm 47m` — time left before the prompt cache goes cold (amber under 5m, dim `cold` once expired).
- `≈$4.1k` — estimated session cost at list price.
- `xhigh·think` — reasoning effort (+ `·think` when extended thinking is on), flush right.

Segments only appear when their data is present, so it degrades gracefully. On narrow
terminals line 2 sheds the cache countdown, then cost, then the sparkline, then the
subagent share, instead of wrapping.

### token-ledger mod

`claude/mods/token-ledger` is a small Claude Code mod (loaded as a plugin from the
`claude/mods` directory marketplace). It counts every model request's tokens and writes
`~/.claude/token-ledger/<session_id>.json`; the status line just reads that small file
instead of re-scanning the transcript on every refresh. On a resumed session it runs
`bin/seed.sh` once, at low priority, to add the tokens recorded before it started counting.
Without the mod, the `tok`, sparkline and `sub` segments are simply left out.

### Install

```bash
git clone <this-repo> ~/Documents/dotfiles
cd ~/Documents/dotfiles
./install.sh
```

`install.sh` symlinks `claude/statusline.sh` into `~/.claude/`, then prints the
settings blocks to add (with this repo's path filled in). Add them to
`~/.claude/settings.json` (merge into the top-level object — don't replace the file):

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh",
  "refreshInterval": 10
},
"enabledPlugins": {
  "token-ledger@claude-dotfiles": true
},
"extraKnownMarketplaces": {
  "claude-dotfiles": {
    "source": { "source": "directory", "path": "/path/to/this/repo/claude/mods" }
  }
}
```

Because the marketplace points at the repo directory, a `git pull` updates the mod too.

Restart Claude Code (or open `/statusline`) to see it.

#### Optional: sticky bottom bar

To pin the input box + status line to the bottom of the terminal (they stay put
while the conversation scrolls above), also add `"tui": "fullscreen"` to
`~/.claude/settings.json`. It uses Claude Code's alt-screen renderer (like `vim`),
so on quit the terminal restores to its prior screen — the conversation isn't left
in native scrollback (it's still saved as a resumable session transcript). Requires
Claude Code v2.1.153+; set back to `"default"` to revert.

### Requirements

- **bash** and **jq** (`sudo dnf install jq`, or `apt`/`pacman`/`brew` equivalent).
- A **UTF-8 locale** — used for the right-alignment width math (handles double-width glyphs).
- **Claude Code v2.1.153+** for the right-aligned model/effort (it exports `$COLUMNS`).
  On older versions they fall back to showing inline; everything else still works.
- `session` / `week` need a **Claude Pro/Max** subscription and show `—` until the
  first reply of a session (and on non-subscription billing).

### Customizing

All in `claude/statusline.sh`:
- **Token counting** — `TOKENS_INCLUDE_CACHE_READS=1` at the top counts all input
  (including context re-reads, so it grows large). Set to `0` to count only new input.
- **Colors** — the `teal` / `amber` / `red` / `green` / `mist` / `pale` 256-color codes near `# --- Colours`.
- **Thresholds** — `color_for()` (the 80% / 90% warning cutoffs).
- **Layout** — the `line1` / `line2` segment arrays near the bottom.
