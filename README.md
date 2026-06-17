# dotfiles

Personal dev-environment config, version-controlled so it can be synced across machines.

## Claude Code status line

A two-line status line for [Claude Code](https://code.claude.com), showing context
usage, rate limits, this session's work, and token totals.

```
ctx 427k/1M (42%) · session 45% ↻ 2h26m · week 10% ↻ 6d              Opus 4.8 1M
PR#42 ✓ · +3109 -698 lines · tok in 20.3M out 420k                   xhigh·think
```

**Line 1 — capacity & limits** (model name pinned right):
- `ctx 427k/1M (42%)` — context window used / max, with percent. Colors: teal < 80%, amber 80–89%, red ≥ 90%.
- `session 45% ↻ 2h26m` — 5-hour rate-limit usage + time until reset.
- `week 10% ↻ 6d` — 7-day rate-limit usage + time until reset.
- `Opus 4.8 1M` — model name, flush right.

**Line 2 — this session's work** (effort pinned right):
- `PR#42 ✓` — PR number + review state (`✓` approved / `✗` changes requested), when a PR is detected.
- `+3109 -698 lines` — lines added/removed this session.
- `tok in 20.3M out 420k` — total input/output tokens summed from the session transcript.
- `xhigh·think` — reasoning effort (+ `·think` when extended thinking is on), flush right.

Segments only appear when their data is present, so it degrades gracefully.

### Install

```bash
git clone <this-repo> ~/Documents/dotfiles
cd ~/Documents/dotfiles
./install.sh
```

`install.sh` symlinks `claude/statusline.sh` into `~/.claude/`, then prints the
settings block to add. Add this to `~/.claude/settings.json` (merge into the
top-level object — don't replace the file):

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh",
  "refreshInterval": 10
}
```

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
- **Colors** — the `teal` / `amber` / `red` / `green` 256-color codes near `# --- Colours`.
- **Thresholds** — `color_for()` (the 80% / 90% warning cutoffs).
- **Layout** — the `line1` / `line2` segment arrays near the bottom.
