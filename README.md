# agent-mem

A GitHub Copilot CLI plugin that gives Copilot **per-repo external memory** modeled after [Claude Code's auto memory](https://docs.claude.com/en/docs/claude-code/memory) — but stored in the plugin's own location (`~/.agent-mem/`, not under `~/.copilot/`).

## What it does

On every Copilot CLI session start, the plugin's `sessionStart` hook:

1. Resolves a memory directory keyed by the current git repo's **absolute root path**:
   - Inside a git repo: `~/.agent-mem/<encoded-repo-root>/` where the key is the absolute repo-root path with `/` replaced by `-` (e.g., `/Users/foo/work/api` → `-Users-foo-work-api`). Worktrees of one clone share a key because they resolve to the same repo root via `git --git-common-dir`.
   - Outside a git repo: `~/.agent-mem/<encoded-cwd>/` using the same encoding.
   - This matches [Claude Code's `~/.claude/projects/`](https://code.claude.com/docs/en/memory#storage-location) convention, so two clones of the same repo at different paths get independent memory and unrelated repos that happen to share a basename never collide.
2. Injects an **index** of that directory into the session via `additionalContext`:
   - The absolute memory path.
   - The contents of `MEMORY.md` (capped at 200 lines / 25 KB to match Claude Code's defaults).
   - A bullet list of the other `*.md` topic files with one-line previews — **content is not dumped**; the agent reads individual files on demand.
   - Guidance on when to read topic files and when to proactively save new learnings.

This index-first design keeps the per-session token cost roughly constant even as the memory directory grows.

## Install

    copilot plugin install difujia/agent-mem

Pin to a specific release:

    copilot plugin install difujia/agent-mem@v0.5.0

Local-path install (for development on a clone):

    copilot plugin install /absolute/path/to/agent-mem

> Copilot CLI prints a deprecation warning for local-path installs — they still work today but may be removed in favor of marketplace installs in a future release.

Verify:

    copilot plugin list   # should list agent-mem

## Updating

`copilot plugin install` **copies** plugin files into `~/.copilot/installed-plugins/_direct/agent-mem/` — it does *not* symlink. To pick up new upstream releases:

    copilot plugin uninstall agent-mem && copilot plugin install difujia/agent-mem

For local development on a clone, re-install from the path after editing:

    copilot plugin uninstall agent-mem && copilot plugin install /absolute/path/to/agent-mem

## Storage layout

    ~/.agent-mem/<encoded-repo-root>/
    ├── MEMORY.md             # concise index, injected at session start (capped)
    └── <topic>.md            # detailed topic files, loaded on demand

## Overrides

| Env var | Effect |
| --- | --- |
| `AGENT_MEM_DIR` | Base directory. Default: `~/.agent-mem`. |
| `AGENT_MEM_KEY` | Full key override; skips path encoding. Use to force two clones to share memory (`AGENT_MEM_KEY=my-project copilot`), to alias a repo, or to opt out of per-clone isolation. |

## How memory grows

**Lazy directory creation** — resolving the memory path, starting a session, and running `/agent-mem-reload` do not create the memory directory. The index is still injected when the directory does not exist, so Copilot knows where to save. Copilot creates the directory only when it is ready to write the first memory file.

**Explicit writes** — when you tell Copilot "remember this for this repo", it evaluates the candidate using the same reflection, evidence, and maintenance rules as proactive learning rather than blindly appending it. Accepted lessons go into `MEMORY.md`, with longer detail in a linked `<topic>.md` file.

**Feedback-driven reflection** — whenever user feedback causes a revision, including design, code, docs, plans, or workflow, the injected guidance tells Copilot to reflect before finishing its response. The feedback need not be an explicit correction, repeated, or accompanied by a request to remember. Verified, repo-specific discoveries that would otherwise need to be re-derived also trigger evaluation.

**Scope and synthesis** — Copilot identifies the session's main work goal, revisiting it when the user redirects the work, and considers why the feedback changed the approach. A principle that applies beyond that goal to other tasks in the repo is a strong candidate for memory, not an automatic write. Feedback limited to the current task or session is not saved. Copilot distills the smallest supported, actionable rule with its scope, limiting conditions, and a brief source rather than copying the feedback or logging the change. It asks if lasting applicability is unclear.

**Evidence and exclusions** — user requirements must come from user feedback, and technical claims from inspected code, docs, or verified execution. Secrets, personal data, unverified assumptions, temporary task state, conversation logs, and generic knowledge are excluded. Repo feedback must not be promoted into unsupported universal rules or cross-repo preferences.

**Maintenance and conflicts** — before an explicit or proactive write, Copilot reads the existing `MEMORY.md` and relevant topic files, skips semantic duplicates, and merges complementary lessons. If new feedback establishes a lasting replacement for a conflicting rule in the same scope and conditions, it updates the obsolete entry and related index/topic summaries rather than leaving contradictory rules active. Different scopes and one-off exceptions do not invalidate the old rule; unclear conflicts require clarification. After verifying a conflict update was saved, Copilot tells the user the old memory is outdated, summarizes the old and new rules, and gives the saved file path. Failed writes must be reported as failures.

For example:

| Current goal | Feedback that leads to a revision | Learning decision |
| --- | --- | --- |
| Revise one settings screen | "Throughout this project, show save errors inline rather than in dialogs." | Distill the project-wide error-display rule; the lesson extends beyond this screen. |
| Revise this release's announcement | "Remove the migration paragraph from this announcement." | Skip: the feedback is limited to the current deliverable. |
| Adjust one hook | "Resolving or reading a memory path must never create its directory." | Distill the read-only lifecycle constraint, not a log of the hook edit. |
| Revise one settings screen, with an existing project-wide dialog-error rule | "Use inline save errors throughout the project instead." | Replace the obsolete rule and notify after verifying the save. |
| Prepare a one-off demo, with an existing project-wide inline-error rule | "Use a dialog just for this demo." | Skip the session-only exception; do not invalidate the standing rule. |

Reflection does not require a write: without a qualifying new or changed lesson, no files or memory directories are created. Learning remains prompt-driven: `sessionStart` injects these instructions for the agent to follow during the conversation, and `/agent-mem-reload` restores the same guidance. The hook does not itself interpret feedback or write lessons, and injection alone does not guarantee the agent will follow the guidance. No separate learning skill is required.

**Reading** — topic files are *not* injected at session start. When a topic looks relevant to the current task, Copilot reads it with the view tool. This is the same on-demand pattern Claude Code uses for its topic files.

## Slash command

`/agent-mem-reload` re-injects the per-repo memory index (MEMORY.md + topic file list) into the current conversation. Use it after `/compact` discards the `sessionStart` `additionalContext` (see [Known limitation](#known-limitation-compact-discards-the-index) below).

The skill is namespaced to avoid collision with Copilot CLI's built-in `/memory` command, which controls an unrelated session-level memory feature.

## Known limitation: `/compact` discards the index

Copilot CLI's `/compact` summarizes the conversation and drops the `sessionStart` `additionalContext` along with it. The hooks reference confirms `preCompact`'s stdout is "notification only" and there is no `postCompact` event, so there's no clean way to re-inject the index at compaction time.

Workarounds:

- Run `/agent-mem-reload` after `/compact` to restore the memory index without losing the compacted summary.
- Or use `/clear` instead of `/compact` to start a fresh session, which fires `sessionStart` and re-injects the full index — but throws away the conversation.

## Caps (mirror Claude Code's defaults)

| Item | Cap |
| --- | --- |
| `MEMORY.md` injected length | 200 lines or 25 KB, whichever comes first |
| Topic-file index entries | 50 (extras summarized as "…N more") |
| Per-entry preview line | 100 chars |

`<!-- ... -->` block comments are stripped from `MEMORY.md` before injection (so maintainer notes don't burn tokens), matching Claude Code's CLAUDE.md handling. Comments inside fenced code blocks are preserved.

## Layout

    .claude-plugin/plugin.json          # plugin manifest
    hooks/hooks.json                    # sessionStart hook
    scripts/resolve-memdir.sh           # computes the per-repo memdir
    scripts/inject-memory.sh            # builds + injects the memory index
    skills/agent-mem-reload/SKILL.md    # /agent-mem-reload slash command

## Development

Run the memory lifecycle and injected-guidance regression checks (requires Bash, Git, and jq):

    bash tests/memory-lifecycle.sh

These checks verify the emitted guidance and read-only hook behavior, not an AI model's learning decisions.

## Why an injected index, not env vars?

A `sessionStart` hook runs *inside* the already-spawned Copilot CLI process and cannot mutate its parent's environment, so it can't simply export `COPILOT_MEMORY_DIR` or `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` for the session to pick up. Instead we build the index ourselves and inject it via `additionalContext`, which is the supported plugin pathway (per the [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference): "sessionStart … Optional — can inject `additionalContext` into the session").

## Differences from Claude Code's auto memory

| Aspect | Claude Code | agent-mem |
| --- | --- | --- |
| Storage root | `~/.claude/projects/<project>/memory/` | `~/.agent-mem/<encoded-repo-root>/` |
| Per-repo keying | encoded absolute repo-root path, shared across worktrees | same |
| Multiple clones of same repo | independent memory per clone path | same |
| Entry file | `MEMORY.md` (capped at 200 lines / 25 KB) | same |
| Topic files | `<topic>.md`, loaded on demand | same |
| Comment stripping | strips `<!-- ... -->` | same |
| Storage override | `autoMemoryDirectory` setting | `$AGENT_MEM_DIR` env var |
| Key override | (not exposed) | `$AGENT_MEM_KEY` env var |
| `/memory` command | yes (`/memory`) | `/agent-mem-reload` (avoids collision with Copilot CLI's built-in `/memory`; rehydrates the index after compact) |
| Proactive saving | Claude decides when to save | injected guidance encourages it |
| Survives `/compact` | full re-injection of CLAUDE.md / MEMORY.md | **not supported** — re-run `/agent-mem-reload` or `/clear` after compact (see [Known limitation](#known-limitation-compact-discards-the-index)) |
