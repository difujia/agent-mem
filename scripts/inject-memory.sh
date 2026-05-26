#!/usr/bin/env bash
# inject-memory.sh — sessionStart hook for the agent-mem plugin.
#
# Design (Claude-Code-style auto memory, adapted for Copilot CLI):
#
#   ~/.agent-mem/<repo>/
#     ├── MEMORY.md       — concise index, injected at session start (capped)
#     ├── <topic>.md      — detailed topic files, loaded on demand
#     └── ...
#
# At session start the hook injects via additionalContext:
#   1. The memdir path (so the agent knows where to read/write)
#   2. The contents of MEMORY.md, capped at 200 lines / 25 KB (Claude's caps)
#   3. A bullet list of other *.md files with first-line previews
#   4. Instructions on how to read topic files on demand and how/when to
#      proactively save durable learnings.
#
# Files with HTML block comments (<!-- ... -->) have those stripped before
# injection, matching Claude Code's CLAUDE.md behavior.

set -uo pipefail
trap 'exit 0' ERR

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# --- Resolve user's working directory from the hook's JSON stdin payload.
payload="$(cat 2>/dev/null || true)"
session_cwd=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
  session_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
if [ -n "$session_cwd" ] && [ -d "$session_cwd" ]; then
  cd "$session_cwd" 2>/dev/null || true
fi

memdir="$("$script_dir/resolve-memdir.sh")"
[ -d "$memdir" ] || exit 0

# --- Caps (mirror Claude Code's defaults so behavior is predictable).
MAX_MEMORY_LINES=200
MAX_MEMORY_BYTES=25600   # 25 KB
MAX_INDEX_ENTRIES=50
MAX_PREVIEW_LEN=100

# strip_comments <file> — remove <!-- ... --> block comments (multi-line),
# matching Claude Code's CLAUDE.md handling. Comments inside fenced code
# blocks are preserved (rough heuristic: skip lines between ``` fences).
strip_comments() {
  awk '
    BEGIN { in_code=0; in_comment=0 }
    {
      line = $0
      if (in_code) { print line; if (line ~ /^```/) in_code=0; next }
      if (line ~ /^```/) { in_code=1; print line; next }
      while (1) {
        if (in_comment) {
          end = index(line, "-->")
          if (end == 0) { line = ""; break }
          line = substr(line, end + 3); in_comment = 0
        } else {
          start = index(line, "<!--")
          if (start == 0) break
          end = index(substr(line, start + 4), "-->")
          if (end == 0) {
            line = substr(line, 1, start - 1); in_comment = 1; break
          }
          line = substr(line, 1, start - 1) substr(line, start + 4 + end + 2)
        }
      }
      if (length(line) > 0 || !in_comment) print line
    }
  ' "$1"
}

# preview_line <file> — first non-empty, non-frontmatter, non-heading-marker
# content line, trimmed and length-capped.
preview_line() {
  awk -v max="$MAX_PREVIEW_LEN" '
    BEGIN { in_fm=0; fm_seen=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; fm_seen=1; next }
    in_fm { if (/^---[[:space:]]*$/) in_fm=0; next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^#+[[:space:]]*/, "", line)
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (length(line) == 0) next
      if (length(line) > max) line = substr(line, 1, max - 1) "…"
      print line; exit
    }
  ' "$1"
}

# --- Build context body.
ctx_file="$(mktemp -t agent-mem-ctx.XXXXXX)"
trap 'rm -f "$ctx_file"' EXIT

{
  printf '# agent-mem (per-repo memory)\n\n'
  printf 'Memory directory for this session:\n  %s\n\n' "$memdir"

  # --- MEMORY.md index (capped injection).
  memory_md="$memdir/MEMORY.md"
  if [ -s "$memory_md" ]; then
    bytes="$(wc -c < "$memory_md" | tr -d ' ')"
    lines="$(wc -l < "$memory_md" | tr -d ' ')"
    truncated=0
    printf '## MEMORY.md\n\n'
    if [ "$bytes" -gt "$MAX_MEMORY_BYTES" ] || [ "$lines" -gt "$MAX_MEMORY_LINES" ]; then
      truncated=1
      strip_comments "$memory_md" | head -n "$MAX_MEMORY_LINES" | head -c "$MAX_MEMORY_BYTES"
      printf '\n\n_(MEMORY.md truncated at %d lines / %d KB — read the full file with the view tool if you need more)_\n\n' \
        "$MAX_MEMORY_LINES" "$((MAX_MEMORY_BYTES / 1024))"
    else
      strip_comments "$memory_md"
      printf '\n'
    fi
  else
    printf '## MEMORY.md\n\n_(none yet — create one when you record your first learning)_\n\n'
  fi

  # --- Topic file index (filenames + first-line previews, NOT full content).
  # macOS ships bash 3.2 with no associative arrays — use sort -u to dedupe.
  shopt -s nullglob
  topics=()
  while IFS= read -r f; do
    [ -n "$f" ] && topics+=("$f")
  done < <(
    {
      for ff in "$memdir"/*.md; do
        [ -e "$ff" ] && [ "$(basename "$ff")" != "MEMORY.md" ] && printf '%s\n' "$ff"
      done
    } | sort -u
  )
  shopt -u nullglob

  if [ ${#topics[@]} -gt 0 ]; then
    printf '## Topic files (load on demand with the view tool)\n\n'
    count=0
    for f in "${topics[@]}"; do
      count=$((count + 1))
      if [ "$count" -gt "$MAX_INDEX_ENTRIES" ]; then
        printf -- '- _(…%d more files in %s)_\n' \
          "$((${#topics[@]} - MAX_INDEX_ENTRIES))" "$memdir"
        break
      fi
      prev="$(preview_line "$f")"
      if [ -n "$prev" ]; then
        printf -- '- `%s` — %s\n' "$(basename "$f")" "$prev"
      else
        printf -- '- `%s`\n' "$(basename "$f")"
      fi
    done
    printf '\n'
  fi

  # --- Read/write guidance for the agent.
  cat <<EOF
## How to use this memory

**Reading on demand**: topic files above are NOT loaded into context. When a
topic looks relevant to the current task, read it with the view tool:
\`view ${memdir}/<filename>\`.

**Writing (explicit)**: when the user asks you to "remember", "save",
"memorize", or "note" something for this repo, append a concise entry to
\`${memdir}/MEMORY.md\` (create if missing), or split detailed notes into a
new \`${memdir}/<kebab-case-topic>.md\` file referenced from MEMORY.md.

**Writing (proactive)**: also save durable, repo-specific learnings without
being asked, when ALL of the following are true:
  - The fact is durable (true across sessions, not session-state)
  - It's repo-specific (not generic knowledge the model already has)
  - You'd otherwise re-derive it next session — e.g. a non-obvious build
    command, a corrected mistake the user pointed out, an architectural
    constraint, a tool quirk, or a user preference about this repo
Keep entries terse. Move long detail into a topic file and link to it
from MEMORY.md. Do NOT save transient state, conversation logs, or
generic knowledge.

**Format**: plain markdown. No frontmatter required for new files (the
\`*.instructions.md\` files without frontmatter from older versions still
work).
EOF
} > "$ctx_file"

# --- Emit the sessionStart hook payload.
if command -v jq >/dev/null 2>&1; then
  jq -nc --rawfile ctx "$ctx_file" '{additionalContext: $ctx}'
else
  escaped="$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g' "$ctx_file")"
  printf '{"additionalContext":"%s"}\n' "$escaped"
fi

exit 0
