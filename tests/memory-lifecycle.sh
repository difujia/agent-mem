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

assert_learning_guidance() {
  local context="$1"
  local case_name="$2"

  assert_contains "$context" 'whenever user feedback causes a revision' \
    "$case_name: missing feedback-driven reflection trigger"
  assert_contains "$context" 'design, code, docs, plans, or workflow' \
    "$case_name: reflection trigger excludes non-code revisions"
  assert_contains "$context" 'not limited to explicit corrections or repeated feedback' \
    "$case_name: reflection requires explicit or repeated correction"
  assert_contains "$context" "identify the session's main work goal" \
    "$case_name: missing session-goal baseline"
  assert_contains "$context" 'applies beyond that goal' \
    "$case_name: missing broader-scope evaluation"
  assert_contains "$context" 'Do not save lessons limited to this session.' \
    "$case_name: session-only feedback is not excluded"
  assert_contains "$context" 'Synthesize the smallest supported, actionable principle' \
    "$case_name: missing reflective synthesis"
  assert_contains "$context" 'without waiting for a "remember" request' \
    "$case_name: qualifying lessons are not saved proactively"
  assert_contains "$context" 'first read the existing MEMORY.md and relevant' \
    "$case_name: missing pre-write memory read"
  assert_contains "$context" 'skip duplicates and merge complementary lessons' \
    "$case_name: missing semantic deduplication"
  assert_contains "$context" 'For a conflict in the same scope and conditions' \
    "$case_name: missing scope-aware conflict handling"
  assert_contains "$context" 'a lasting replacement, update the outdated entry' \
    "$case_name: missing obsolete-memory replacement"
  assert_contains "$context" 'do not leave contradictory guidance active' \
    "$case_name: conflicting old guidance can remain active"
  assert_contains "$context" 'Different scopes and one-off exceptions do not invalidate an existing rule.' \
    "$case_name: scoped exceptions invalidate standing rules"
  assert_contains "$context" 'ask before changing it' \
    "$case_name: ambiguous conflicts do not require clarification"
  assert_contains "$context" 'verify the saved content before claiming success' \
    "$case_name: missing save verification"
  assert_contains "$context" 'tell the user that the old memory is outdated' \
    "$case_name: missing obsolete-memory notification"
  assert_contains "$context" 'the updated memory has been saved' \
    "$case_name: missing replacement-memory notification"
  assert_contains "$context" 'the saved file path' \
    "$case_name: missing saved-memory location"
  assert_contains "$context" 'Report write failures explicitly, never as success.' \
    "$case_name: missing write-failure reporting"
  assert_contains "$context" 'secrets or personal data, unverified assumptions' \
    "$case_name: missing unsafe-memory exclusions"
  assert_contains "$context" 'No qualifying new or changed lesson means no writes or directory creation.' \
    "$case_name: evaluating candidates creates files"
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
  assert_learning_guidance "$context" "$case_name: session start"
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
  assert_learning_guidance "$context" "$case_name: reload saved memory"
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
