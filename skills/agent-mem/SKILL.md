---
name: agent-mem
description: >-
  View this repo's external memory stored by the agent-mem plugin. Lists
  MEMORY.md and all topic files in the per-repo memory directory with their
  sizes, and points at the absolute path so the user can open or edit them
  directly. Use when the user types /agent-mem or asks "what's in my agent
  memory", "show repo memory", "list saved learnings", or similar. Note:
  Copilot CLI's built-in /memory command controls a different (session-level)
  memory feature; this skill exposes agent-mem's per-repo file-based store.
allowed-tools: bash
argument-hint: "[view <file> | path]"
---

# /agent-mem

Show the user a concise overview of agent-mem's storage for the current repo. The plugin already injects a topic index at session start; this skill is for an explicit, user-initiated view.

## What to do

1. **Resolve the memory directory.** Run the plugin's resolver — it handles git-repo keying and the legacy-location migration:

       AGENT_MEM_ROOT="${AGENT_MEM_PLUGIN_ROOT:-$HOME/.copilot/installed-plugins/_direct/agent-mem}"
       MEMDIR="$("$AGENT_MEM_ROOT/scripts/resolve-memdir.sh")"
       echo "$MEMDIR"

2. **Branch on the user argument** (`$ARGUMENTS`, if any):

   - **No argument** (default): list contents.

         echo "Memory directory: $MEMDIR"
         echo
         if [ -s "$MEMDIR/MEMORY.md" ]; then
           lines=$(wc -l < "$MEMDIR/MEMORY.md" | tr -d ' ')
           bytes=$(wc -c < "$MEMDIR/MEMORY.md" | tr -d ' ')
           echo "MEMORY.md  ($lines lines, $bytes bytes)"
         else
           echo "MEMORY.md  (not yet created)"
         fi
         echo
         echo "Topic files:"
         ls -lh "$MEMDIR"/*.md 2>/dev/null \
           | grep -v 'MEMORY.md' \
           | awk '{ printf "  %-12s %s\n", $5, $NF }' \
           | sort -u || echo "  (none yet)"

     Then summarize for the user in plain English: how many topic files there are and where to find them. Mention they can run `/memory view <filename>` to open a specific file, or open the directory in their editor at `$MEMDIR`.

   - **`view <filename>`**: read the file with the view tool. Resolve the filename against `$MEMDIR` if it's not already an absolute path. Show the full contents.

   - **`path`**: just print `$MEMDIR` and stop. Useful for piping into other commands.

3. **Do not edit memory files from this skill.** Editing is the user's job (or the agent's normal workflow when the user says "remember this" or when the agent proactively saves a durable learning per the session-start guidance).

## User-provided argument

`$ARGUMENTS`
