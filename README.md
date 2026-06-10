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

    copilot plugin install difujia/agent-mem@v0.4.1

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

**Explicit writes** — when you tell Copilot "remember this for this repo", it appends a terse entry to `MEMORY.md` (creating it if needed), or splits longer content into a new `<topic>.md` file and links to it from `MEMORY.md`.

**Proactive writes** — the injected guidance also tells Copilot to save *durable, repo-specific* learnings without being asked, when all of the following are true:

- The fact is durable across sessions, not session-state.
- It's repo-specific, not generic knowledge the model already has.
- You'd otherwise re-derive it next session — e.g. a non-obvious build command, a corrected mistake, an architectural constraint, a tool quirk, or a user preference.

Transient state, conversation logs, and generic knowledge are explicitly excluded.

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
