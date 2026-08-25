#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${OPENCODE_PREWALK_REPO_URL:-https://github.com/vivekascoder/opencode-prewalk.git}"
REPO_DIR="${OPENCODE_PREWALK_DIR:-$HOME/.local/share/opencode-prewalk}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PLUGIN_DIR="${OPENCODE_PREWALK_PLUGIN_DIR:-$CONFIG_HOME/opencode/plugins/opencode-prewalk}"

info() { printf '→ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

for cmd in git node npm opencode2; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$node_major" -lt 20 ]; then
  fail "Node.js 20+ is required (found $(node --version))"
fi

mkdir -p "$(dirname "$REPO_DIR")"
if [ -d "$REPO_DIR/.git" ]; then
  info "Updating existing checkout at $REPO_DIR"
  git -C "$REPO_DIR" fetch --quiet origin main
  git -C "$REPO_DIR" checkout --quiet main
  git -C "$REPO_DIR" pull --ff-only --quiet origin main
else
  [ ! -e "$REPO_DIR" ] || fail "$REPO_DIR already exists and is not a git checkout"
  info "Cloning opencode-prewalk to $REPO_DIR"
  git clone --quiet "$REPO_URL" "$REPO_DIR"
fi

info "Installing plugin dependencies"
npm --prefix "$REPO_DIR" install --omit=dev --no-audit --no-fund --quiet

[ -f "$REPO_DIR/src/index.ts" ] || fail "Plugin entrypoint is missing at $REPO_DIR/src/index.ts"

mkdir -p "$(dirname "$PLUGIN_DIR")"
if [ -L "$PLUGIN_DIR" ]; then
  rm "$PLUGIN_DIR"
elif [ -e "$PLUGIN_DIR" ]; then
  fail "$PLUGIN_DIR already exists and is not a symlink; move/remove it before installing"
fi
ln -s "$REPO_DIR" "$PLUGIN_DIR"

ok "Linked global OpenCode plugin at $PLUGIN_DIR"
ok "Installed opencode-prewalk"
printf '\nRestart OpenCode, then run:\n\n  /prewalk fix the failing auth refresh tests\n\n'
