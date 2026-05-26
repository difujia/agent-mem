#!/usr/bin/env bash
# resolve-memdir.sh — compute the per-repo memory directory.
#
# Storage: ~/.agent-mem/<key>/ (the plugin's own storage, not Copilot's).
# Override the base dir with $AGENT_MEM_DIR.
#
# Key rules (kept consistent with the legacy zsh wrapper):
#   - Inside a git repo: key = basename(repo_root) where repo_root is
#     dirname(git --git-common-dir). Shared across worktrees of one clone.
#   - Outside a git repo: key = _nogit/<basename(cwd)>.
#
# One-shot migration: if a per-repo dir doesn't yet exist under the new base
# but exists under the legacy ~/.copilot/repo-memory/<key>, move it. Safe and
# idempotent — only fires when the new path is absent.
#
# Prints the absolute path to stdout. Creates the directory.

set -uo pipefail

base="${AGENT_MEM_DIR:-$HOME/.agent-mem}"
legacy_base="$HOME/.copilot/repo-memory"

if common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  repo_root=$(dirname "$common_dir")
  repo_key=$(basename "$repo_root")
  rel="$repo_key"
else
  rel="_nogit/$(basename "$PWD")"
fi

memdir="$base/$rel"
legacy_dir="$legacy_base/$rel"

# One-shot migration from legacy location.
if [ ! -d "$memdir" ] && [ -d "$legacy_dir" ]; then
  mkdir -p "$(dirname "$memdir")" 2>/dev/null || true
  mv "$legacy_dir" "$memdir" 2>/dev/null || true
fi

mkdir -p "$memdir" 2>/dev/null || true
printf '%s\n' "$memdir"

