#!/usr/bin/env bash
# Install these dotfiles into ~/.claude/.
# Symlinks the Claude Code status line script so edits here take effect live.
# Safe to re-run; an existing real file is backed up before linking.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SRC="${DOTFILES_DIR}/claude/statusline.sh"
DEST="${CLAUDE_DIR}/statusline.sh"

mkdir -p "$CLAUDE_DIR"
chmod +x "$SRC"

# Back up an existing non-symlink so nothing is silently overwritten.
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
  backup="${DEST}.bak.$(date +%s)"
  mv "$DEST" "$backup"
  echo "Backed up existing status line -> $backup"
fi

ln -sf "$SRC" "$DEST"
echo "Linked: $DEST -> $SRC"

# Dependency check.
if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: 'jq' is not installed — the status line needs it (e.g. 'sudo dnf install jq')."
fi

cat <<'EOF'

Almost done. Add this block to ~/.claude/settings.json (merge into the
top-level object — do not replace the whole file):

  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "refreshInterval": 10
  }

Then restart Claude Code (or open /statusline) to see it.
Right-aligned model/effort require Claude Code v2.1.153+; older versions
fall back to showing them inline.
EOF
