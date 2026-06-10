---
name: agent-mem-reload
description: >-
  Re-inject this repo's agent-mem index (MEMORY.md contents + topic file list)
  into the current Copilot CLI conversation. Used to restore the index after
  /compact has dropped it, without nuking the compacted summary the way /clear
  would. Read-only — never edits memory files. Use when the user types
  /agent-mem-reload, or asks to "reload agent memory", "rehydrate repo
  memory", or "restore the memory index after compact".
allowed-tools: bash
---

# /agent-mem-reload

Re-emit the per-repo memory index that the agent-mem plugin normally injects at session start.

## When this is the right tool

The `sessionStart` hook injects an index of `~/.agent-mem/<repo>/` (MEMORY.md contents + a list of topic files) at the start of every conversation. The `/compact` command summarizes the conversation but also drops that injected context. This skill rebuilds the index and surfaces it as a tool result so the rest of the conversation has it back.

`/clear` would also restore the index (sessionStart re-fires) but throws away the compacted summary. Use this skill when you want both.

## What to do

1. The skill-context header above shows the absolute "Base directory" of this skill, which is always `<plugin-root>/skills/agent-mem-reload`. The plugin root is two parent directories up. Substitute that base directory below as `SKILL_DIR`, then run:

       SKILL_DIR="<paste the 'Base directory' value from the skill-context header>"
       PLUGIN_ROOT="$(cd "$SKILL_DIR/../.." && pwd -P)"
       echo '{}' | "$PLUGIN_ROOT/scripts/inject-memory.sh" | jq -r '.additionalContext'

   The output is the same markdown block the sessionStart hook would emit: memdir path, MEMORY.md (capped), topic file index with previews, and read/write guidance.

2. Do **not** summarize or paraphrase the output for the user — they already see it in the tool result, and the point is for *you* to have it back in context. A brief one-line confirmation ("Reloaded agent-mem index from `<memdir>`.") is enough.

3. Do not edit any memory files from this skill. Writing is the agent's normal workflow when the user says "remember this" or when the agent proactively saves a durable learning per the injected guidance.
