#!/usr/bin/env bash
# resolve-memdir.sh — compute the per-repo memory directory.
#
# Storage: ~/.agent-mem/<key>/
#
# Overrides:
#   $AGENT_MEM_DIR — base directory (default: ~/.agent-mem).
#   $AGENT_MEM_KEY — full key override; skips path encoding. Use to force
#                    two clones to share memory, or to alias a repo.
#
# Key rules (modeled on Claude Code's auto memory):
#   - Inside a git repo: key = encode(repo_root) where repo_root is
#     dirname(git --git-common-dir). Worktrees share one key.
#   - Outside a git repo: key = encode($PWD).
#   - encode(path) = path with each '/' replaced by '-' (e.g.,
#     /Users/foo/repo -> -Users-foo-repo).
#
# Prints the absolute memdir to stdout. Creates the directory.

set -uo pipefail

base="${AGENT_MEM_DIR:-$HOME/.agent-mem}"

encode_path() {
  printf '%s' "$1" | sed 's|/|-|g'
}

if [ -n "${AGENT_MEM_KEY:-}" ]; then
  key="$AGENT_MEM_KEY"
elif common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  key="$(encode_path "$(dirname "$common_dir")")"
else
  key="$(encode_path "$PWD")"
fi

memdir="$base/$key"
mkdir -p "$memdir" 2>/dev/null || true
printf '%s\n' "$memdir"

