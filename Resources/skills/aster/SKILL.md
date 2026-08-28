---
name: aster
description: "Control Aster, a macOS terminal workspace for coding agents. Use only when the user explicitly mentions Aster or asks to use Aster to inspect or control panes, tabs, windows, commands, or another agent. Do not use merely because a task could benefit from a background terminal, delegation, or parallel work. Requires ASTER_ENV=1."
---

# Aster

Aster organizes terminals into windows, tabs, and panes, recognizes coding agents running inside panes, and exposes the running app through the `aster` CLI.

Before issuing any control command, verify that this agent is running inside an Aster-managed pane:

```bash
test "${ASTER_ENV:-}" = 1
```

If the check fails, say that you are not running inside Aster and stop. Do not inspect or control Aster from outside Aster.

When the check passes, the `aster` binary in `PATH` (or `$ASTER_BIN_PATH`) talks to the running app over `$ASTER_SOCKET_PATH`. Use it to inspect neighboring work, start agents and commands, read output, and wait for state changes.

## Learn the current CLI

The installed binary is the authority for command syntax. Start with:

```bash
aster --help
```

Then print a command group by running the group without a subcommand:

```bash
aster agent
aster pane
aster events
aster notification
aster session
```

Bare `aster` prints help; it does not launch anything. Do not probe a mutating command by omitting arguments.

Control commands return JSON (`--json`). Read identifiers and state from those responses instead of predicting them.

## Understand layout, panes, and agents

- Window, tab, and pane topology organize terminal locations.
- Pane commands control raw terminals, shells, tests, servers, input, and output.
- Agent commands control the recognized coding agent currently occupying a pane.

A pane exists whether or not it contains an agent. `agent start` requires an existing available shell pane and never creates or splits layout. Use pane commands for ordinary processes. Use agent commands when Aster must validate agent identity or interpret `idle`, `working`, `blocked`, `done`, and `unknown` lifecycle states.

Agent commands accept either a unique live agent name or the pane ID currently hosting that agent. Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents. A name follows the current pane occupant and is cleared when that agent exits.

State meanings:

- `working`: the agent is processing.
- `blocked`: Aster recognized an approval or question UI. The agent is waiting for a person.
- `idle`: the agent is ready for input and its tab has been seen by the user.
- `done`: the same idle state after unseen background work finished. `agent focus` or `pane focus` marks it seen. CLI reads do not.
- `unknown`: an agent is present but Aster cannot classify it confidently; it does not prove completion.

Each agent also reports `detection`: `hook` (authoritative lifecycle hook installed by Aster), `screen` (screen-text rules), or `heuristic` (weak fallback).

## Use IDs and caller context

Public IDs are opaque stable handles:

- window: `w1`
- tab: `w1:t1`
- pane: `w1:p1`

Closed tab and pane IDs are not reused. Aster injects the caller's context into each managed pane:

```bash
printf '%s\n' "$ASTER_WINDOW_ID" "$ASTER_TAB_ID" "$ASTER_PANE_ID"
```

Prefer `--current` when a pane command should target the calling pane. Omitting a target may use the UI-focused pane, which can belong to the user.

Discover live state with:

```bash
aster session snapshot --json
aster agent list --json
aster agent get "$ASTER_PANE_ID" --json
```

To follow changes instead of polling, use `aster events wait --after-sequence <n>` with the `sequence` from the last snapshot or event. If Aster answers `replay_gap`, the events between your sequence and now are no longer available: run `aster session snapshot --json` again, take its `sequence`, and continue from there rather than retrying the old number.

## Start and coordinate an agent

Aster does not split panes from the CLI. To get a new terminal, ask the user to open one, or open a new tab with a command:

```bash
aster open "$PWD" --command "codex"
```

An available shell pane must be at its interactive prompt, with no foreground command, editor, or agent running. Start a supported agent in such a pane with a useful unique name:

```bash
aster agent start reviewer --kind codex --pane <pane-id>
```

Pass native agent arguments only after `--`:

```bash
aster agent start reviewer --kind codex --pane <pane-id> -- <agent-args...>
```

A successful `agent start` returns only after Aster detects the expected agent in the same pane and considers it ready. If the agent is blocked during startup, the command returns `agent_not_ready`. If the pane has a foreground command or another agent, it returns `pane_busy`. If the name is already used by a live agent, it returns `agent_name_taken` and starts nothing: pick a different unique name and retry (check `aster agent list --json` for names in use). Startup defaults to a 30-second timeout.

Submit work through the agent surface:

```bash
aster agent prompt reviewer "Review the current diff and report only actionable findings." --wait --timeout 120000
```

`agent prompt` honors the pane's bracketed-paste mode and sends text followed by Enter. It rejects an agent already waiting at an approval or question dialog with `agent_blocked` before sending any input. Inspect the blocked UI (`agent read`) and ask the user before answering it. `--wait` waits for the first settled `idle`, `done`, or `blocked` state.

A prompt sent from a non-working state must produce an observed lifecycle change within five seconds. Otherwise Aster returns `agent_prompt_stalled`.

Use `--until` only for a state-specific workflow:

```bash
aster agent wait reviewer --until blocked --timeout 120000
```

Use logical keys for interactive agent UI controls:

```bash
aster agent send-keys reviewer esc
aster agent send-keys reviewer ctrl+c
```

Read the result through the resolved agent:

```bash
aster agent get reviewer --json
aster agent read reviewer --source recent --lines 120
```

## Run an ordinary command in another pane

```bash
aster pane send-text <pane-id> "just test" --enter
aster pane wait-output <pane-id> --match "test result" --timeout 120000
aster pane read <pane-id> --source recent --lines 120
```

`pane wait-output` searches the current snapshot immediately, so output that already exists can match. Use `--match <text>` for a literal substring or `--regex <pattern>` for an ICU regular expression.

Read sources:

- `visible`: the currently rendered viewport.
- `recent`: recent output including scrollback.

If increasing `--lines` does not reveal more of a completed response, the pane is probably running the agent on the alternate screen. Ask the agent to write its complete response as Markdown to a temporary file and reply only with the path, then read the file. Use this only as a fallback.

## Safety and coordination rules

- Write commands (`prompt`, `send-text`, `send-keys`, `start`) require the user to enable "IPC: allow send keys" in Aster settings. On `write_not_allowed`, tell the user to enable it; do not retry.
- Panes running `ssh` or `sudo` are refused with `sensitive_session_not_allowed` unless the user enabled that setting.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on the user's focused pane.
- Parse IDs from JSON responses. Do not derive them from sidebar order or examples.
- Do not close tabs or panes you did not create unless the user explicitly asked.
- CLI server errors are JSON on stderr with exit status 1. CLI syntax errors exit with status 2. Exit status 69 means Aster is not reachable.
