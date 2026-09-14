#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v jq >/dev/null 2>&1; then
  printf 'Memory lifecycle tests require jq.\n' >&2
  exit 1
fi

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-mem-test.XXXXXX")"
test_dir="$(cd "$test_dir" && pwd -P)"
trap 'rm -rf -- "$test_dir"' EXIT
unset AGENT_MEM_KEY

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3"
}

read_context() {
  "$repo_root/scripts/inject-memory.sh" |
    jq -er '.additionalContext | select(type == "string" and length > 0)'
}

check_lifecycle() (
  session_dir="$1"
  case_name="$2"
  expected_key="$3"
  export AGENT_MEM_DIR="$test_dir/memory $case_name"
  cd "$session_dir"

  memdir="$("$repo_root/scripts/resolve-memdir.sh")"
  [ "$memdir" = "$AGENT_MEM_DIR/$expected_key" ] ||
    fail "$case_name: resolved the wrong memory path"
  [ ! -e "$AGENT_MEM_DIR" ] ||
    fail "$case_name: resolving the path created a directory"

  context="$(jq -nc --arg cwd "$session_dir" '{cwd: $cwd}' | read_context)"
  assert_contains "$context" "$memdir" "$case_name: missing memory path"
  assert_contains "$context" "none yet" "$case_name: missing empty-memory index"
  assert_contains "$context" 'only when you are ready to write the first memory file' \
    "$case_name: missing lazy-write guidance"
  [ ! -e "$AGENT_MEM_DIR" ] ||
    fail "$case_name: session start created a directory"

  reloaded="$(printf '{}\n' | read_context)"
  [ "$context" = "$reloaded" ] ||
    fail "$case_name: reload changed the empty-memory index"
  [ ! -e "$AGENT_MEM_DIR" ] ||
    fail "$case_name: reload created a directory"

  mkdir -p "$memdir"
  context="$(printf '{}\n' | read_context)"
  assert_contains "$context" "none yet" "$case_name: existing empty directory failed"
  [ ! -e "$memdir/MEMORY.md" ] ||
    fail "$case_name: reading an empty directory created MEMORY.md"

  printf '# Repo memory\n\nDurable fixture learning.\n' > "$memdir/MEMORY.md"
  printf '# Build notes\n\nDetails loaded on demand only.\n' > "$memdir/build.md"
  before="$(cksum "$memdir/MEMORY.md" "$memdir/build.md")"
  context="$(printf '{}\n' | read_context)"
  assert_contains "$context" 'Durable fixture learning.' \
    "$case_name: first saved memory was not injected"
  assert_contains "$context" '`build.md`' "$case_name: missing topic index"
  assert_contains "$context" 'Build notes' "$case_name: missing topic preview"
  [[ "$context" != *'Details loaded on demand only.'* ]] ||
    fail "$case_name: topic contents were injected eagerly"
  [ "$before" = "$(cksum "$memdir/MEMORY.md" "$memdir/build.md")" ] ||
    fail "$case_name: loading the index modified saved memories"

  printf 'PASS: %s\n' "$case_name"
)

mkdir -p "$test_dir/chat" "$test_dir/repo"
git init --quiet "$test_dir/repo"

chat_key="$(printf '%s' "$test_dir/chat" | sed 's|/|-|g')"
repo_key="$(printf '%s' "$test_dir/repo" | sed 's|/|-|g')"
check_lifecycle "$test_dir/chat" "non-git" "$chat_key"
check_lifecycle "$test_dir/repo" "git" "$repo_key"

export AGENT_MEM_KEY="shared-project"
check_lifecycle "$test_dir/chat" "key-override" "$AGENT_MEM_KEY"
