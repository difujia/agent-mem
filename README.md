# agent-mem

A GitHub Copilot CLI plugin that gives Copilot **per-repo external memory** modeled after [Claude Code's auto memory](https://docs.claude.com/en/docs/claude-code/memory) — but stored in the plugin's own location (`~/.agent-mem/`, not under `~/.copilot/`).

## What it does

On every Copilot CLI session start, the plugin's `sessionStart` hook:

1. Resolves a memory directory keyed by the current git repository:
   - Inside a git repo: `~/.agent-mem/<repo-name>/` (shared across all worktrees of the same clone, via `git --git-common-dir`).
   - Outside a git repo: `~/.agent-mem/_nogit/<cwd-basename>/`.
2. Injects an **index** of that directory into the session via `additionalContext`:
   - The absolute memory path.
   - The contents of `MEMORY.md` (capped at 200 lines / 25 KB to match Claude Code's defaults).
   - A bullet list of the other `*.md` topic files with one-line previews — **content is not dumped**; the agent reads individual files on demand.
   - Guidance on when to read topic files and when to proactively save new learnings.

This index-first design keeps the per-session token cost roughly constant even as the memory directory grows.

## Storage layout

    ~/.agent-mem/<repo>/
    ├── MEMORY.md             # concise index, injected at session start (capped)
    ├── <topic>.md            # detailed topic files, loaded on demand
    └── <topic>.instructions.md   # older naming convention also supported

Override the base directory with `$AGENT_MEM_DIR`.

## How memory grows

**Explicit writes** — when you tell Copilot "remember this for this repo", it appends a terse entry to `MEMORY.md` (creating it if needed), or splits longer content into a new `<topic>.md` file and links to it from `MEMORY.md`.

**Proactive writes** — the injected guidance also tells Copilot to save *durable, repo-specific* learnings without being asked, when all of the following are true:

- The fact is durable across sessions, not session-state.
- It's repo-specific, not generic knowledge the model already has.
- You'd otherwise re-derive it next session — e.g. a non-obvious build command, a corrected mistake, an architectural constraint, a tool quirk, or a user preference.

Transient state, conversation logs, and generic knowledge are explicitly excluded.

**Reading** — topic files are *not* injected at session start. When a topic looks relevant to the current task, Copilot reads it with the view tool. This is the same on-demand pattern Claude Code uses for its topic files.

## Slash command

Use `/agent-mem` inside a Copilot CLI session to list the memory directory for the current repo and its files (sizes + previews). The skill name avoids collision with Copilot CLI's built-in `/memory` command, which controls a different session-level memory feature.

Optional arguments:

- `/agent-mem` — list MEMORY.md + topic files with sizes.
- `/agent-mem view <filename>` — read the contents of a specific topic file.
- `/agent-mem path` — print just the absolute memory directory path.

## Known limitation: `/compact` discards the index

Copilot CLI's `/compact` summarizes the conversation and drops the `sessionStart` `additionalContext` along with it. The hooks reference confirms `preCompact`'s stdout is "notification only" and there is no `postCompact` event, so there's no clean way to re-inject the index at compaction time.

Workarounds:

- Run `/agent-mem` after a `/compact` to re-list the memory directory; this re-establishes the index in the conversation.
- Or `/clear` instead of `/compact` to start a fresh session, which fires `sessionStart` and re-injects the full index.

## Caps (mirror Claude Code's defaults)

| Item | Cap |
| --- | --- |
| `MEMORY.md` injected length | 200 lines or 25 KB, whichever comes first |
| Topic-file index entries | 50 (extras summarized as "…N more") |
| Per-entry preview line | 100 chars |

`<!-- ... -->` block comments are stripped from `MEMORY.md` before injection (so maintainer notes don't burn tokens), matching Claude Code's CLAUDE.md handling. Comments inside fenced code blocks are preserved.

## Migration from legacy storage

The plugin used to (and the older `copilot()` zsh wrapper before it) store memory under `~/.copilot/repo-memory/<repo>/`. On first run for any repo, `resolve-memdir.sh` will `mv` the legacy directory into the new `~/.agent-mem/<repo>/` location automatically — no data loss. Migration is one-shot and only fires when the new path doesn't yet exist.

## Install

    copilot plugin install /Users/fujiadi/Developer/agent-mem

(Or any absolute path / `./relative/path` to this repo.)

> Copilot CLI prints a deprecation warning for local-path installs — they still work today but may be removed in favor of marketplace installs in a future release. If/when that happens, publish this directory to a GitHub repo and install with `copilot plugin install OWNER/REPO`.

Verify:

    copilot plugin list   # should list agent-mem

## Updating

`copilot plugin install` **copies** plugin files into `~/.copilot/installed-plugins/_direct/agent-mem/` — it does *not* symlink. After editing this repo, re-run:

    copilot plugin uninstall agent-mem && copilot plugin install /Users/fujiadi/Developer/agent-mem

## Layout

    .claude-plugin/plugin.json          # plugin manifest
    hooks/hooks.json                    # sessionStart hook
    scripts/resolve-memdir.sh           # computes the per-repo memdir (+ legacy migration)
    scripts/inject-memory.sh            # builds + injects the memory index
    skills/agent-mem/SKILL.md           # /agent-mem slash command

## Why not just set env vars from the hook?

The original `copilot()` wrapper worked because it ran *before* `copilot` started, so it could set `COPILOT_MEMORY_DIR` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` for the child process. A `sessionStart` hook runs *inside* the already-spawned process and cannot mutate its parent's environment. Instead we build the index ourselves and inject it via `additionalContext`, which is the supported plugin pathway (per the [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference): "sessionStart … Optional — can inject `additionalContext` into the session").

## Differences from Claude Code's auto memory

| Aspect | Claude Code | agent-mem |
| --- | --- | --- |
| Storage root | `~/.claude/projects/<project>/memory/` | `~/.agent-mem/<repo>/` |
| Per-repo keying | git-repo, shared across worktrees | same |
| Entry file | `MEMORY.md` (capped at 200 lines / 25 KB) | same |
| Topic files | `<topic>.md`, loaded on demand | same |
| Comment stripping | strips `<!-- ... -->` | same |
| Storage override | `autoMemoryDirectory` setting | `$AGENT_MEM_DIR` env var |
| `/memory` command | yes (`/memory`) | `/agent-mem` (avoids collision with Copilot CLI's built-in `/memory`) |
| Proactive saving | Claude decides when to save | injected guidance encourages it |
| Survives `/compact` | full re-injection of CLAUDE.md / MEMORY.md | **not supported** — re-run `/agent-mem` or `/clear` after compact (see [Known limitation](#known-limitation-compact-discards-the-index)) |
