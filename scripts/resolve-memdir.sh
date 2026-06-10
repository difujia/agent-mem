#!/usr/bin/env bash
# resolve-memdir.sh — compute the per-repo memory directory.
#
# Storage: ~/.agent-mem/<key>/
#
# Overrides:
#   $AGENT_MEM_DIR — base directory (default: ~/.agent-mem).
#   $AGENT_MEM_KEY — full key override; skips path encoding. Use this to
#                    force two clones to share memory, or to alias a repo.
#
# Key rules (modeled on Claude Code's auto memory):
#   - Inside a git repo: key = encode(repo_root) where repo_root is
#     dirname(git --git-common-dir). Worktrees share one key because they
#     resolve to the same repo_root.
#   - Outside a git repo: key = encode($PWD).
#   - encode(path) = path with each '/' replaced by '-' (e.g.,
#     /Users/foo/repo -> -Users-foo-repo). Matches Claude Code's
#     ~/.claude/projects/ convention so two clones at different paths
#     never collide.
#
# One-shot migrations (only when the new memdir is absent):
#   1. Old basename-only key at $base/<basename> (pre-v0.3.0 layout).
#   2. Old basename-only key at $base/_nogit/<basename> (pre-v0.3.0, no-git).
#   3. Legacy zsh-wrapper location ~/.copilot/repo-memory/<basename>.
#   4. Legacy zsh-wrapper location ~/.copilot/repo-memory/_nogit/<basename>.
#
# Prints the absolute memdir to stdout. Creates the directory.

set -uo pipefail

base="${AGENT_MEM_DIR:-$HOME/.agent-mem}"
legacy_base="$HOME/.copilot/repo-memory"

encode_path() {
  printf '%s' "$1" | sed 's|/|-|g'
}

legacy_basename_key=""
legacy_nogit_key=""

if [ -n "${AGENT_MEM_KEY:-}" ]; then
  key="$AGENT_MEM_KEY"
elif common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  repo_root="$(dirname "$common_dir")"
  key="$(encode_path "$repo_root")"
  legacy_basename_key="$(basename "$repo_root")"
else
  key="$(encode_path "$PWD")"
  legacy_nogit_key="_nogit/$(basename "$PWD")"
fi

memdir="$base/$key"

migrate_from() {
  local src="$1"
  [ -n "$src" ] && [ -d "$src" ] || return 1
  mkdir -p "$(dirname "$memdir")" 2>/dev/null || return 1
  mv "$src" "$memdir" 2>/dev/null
}

if [ ! -d "$memdir" ]; then
  if [ -n "$legacy_basename_key" ]; then
    migrate_from "$base/$legacy_basename_key" \
      || migrate_from "$legacy_base/$legacy_basename_key" \
      || true
  fi
fi

if [ ! -d "$memdir" ]; then
  if [ -n "$legacy_nogit_key" ]; then
    migrate_from "$base/$legacy_nogit_key" \
      || migrate_from "$legacy_base/$legacy_nogit_key" \
      || true
  fi
fi

mkdir -p "$memdir" 2>/dev/null || true
printf '%s\n' "$memdir"

