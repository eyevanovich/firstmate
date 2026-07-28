# Primary-session delegation guard

This document is the human-readable contract for the guard that prevents a Firstmate primary from creating project work outside the durable fleet.
`bin/fm-subagent-pretool-check.sh` is the shipped classifier and enforcement mechanism.

## Why it exists

Only `bin/fm-spawn.sh` creates the durable instructions, task record, isolated copy, endpoint, and supervision signals required to survive a primary-session restart.
A harness-native delegated worker bypasses those records, is absent from fleet reconciliation, and can disappear with the primary session while supervision incorrectly sees no work under way.
The primary must therefore classify work under `AGENTS.md`, write instructions with `bin/fm-brief.sh`, and dispatch with `bin/fm-spawn.sh`.

The guard does not judge whether work deserves delegation or whether the resulting task instructions are good.
It only rejects a native launch-shaped tool at the wrong lifecycle boundary.

## Classification

The guard normalizes a tool name to lowercase ASCII letters and digits and denies names containing a launch-shaped stem:

```text
agent subagent task workflow cron schedul worktree delegate spawn dispatch
handoff remote sendmessage monitor
```

It excludes MCP tools before shape matching because an MCP server owns those names and a task or agent noun there does not imply native harness delegation.
It also preserves exact observe-or-stop tools such as task output/list/status, process output/kill, agent list/wait/interrupt, and Pi's `subagent_wait`.

Pi multiplexes launch and management through `subagent`.
For a stdin payload with an explicit observe-or-stop `tool_input.action`, the guard allows the call; omitted action remains a launch and resume, steer, append, create, update, and scheduling actions remain denied.
This avoids both untracked project work and stranding an already-running operation with no inspection or stop path.

## Scope

The guard uses `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh`, the shared genuine-home predicate used by primary lifecycle hooks.
A plain Firstmate checkout with its required tracked and private directories is in scope.
A valid marked secondmate home is also in scope because it operates its own durable fleet.
A linked task worktree is out of scope, so a worker in its isolated copy retains legitimate delegation tooling.
A non-Firstmate repository and any environment that cannot prove the scope are inert rather than globally blocking tools.

`FM_ALLOW_SUBAGENT=1` in the primary session's launch environment is the sole deliberate escape.
Every other value retains enforcement.
The escape does not bypass normal captain authority or make native work durable.

## Hook contract

Allow returns exit 0 with both streams empty.
Deny returns exit 2 and a reason beginning `[subagent-dispatch]`.
`--claude` writes Claude's `PreToolUse` denial JSON to stderr and leaves stdout empty.
Default mode additionally writes Grok's decision JSON to stdout.
`--stderr-only` emits only the plain reason for Codex and Pi, which honor exit 2 or the adapter's block result.
Malformed or empty stdin, missing tool names, and missing `jq` fail open so a broken parser cannot disable every tool.

Tracked Claude settings use an all-tools matcher and invoke the guard with `--claude`.
Tracked Codex hooks use an all-tools `PreToolUse` matcher and invoke it with `--stderr-only`.
Pi's primary turn-end extension forwards every `tool_call` name and input to the same checker before its Bash-specific protections.

OpenCode 1.18.4 has a wireable `tool.execute.before` plugin surface, but live verification was blocked by workspace billing during this change, so this guard is not trusted there yet.
Grok was not installed on the validation host, so its matcher was not broadened without live evidence.
The current tracked Grok Bash-only checks remain unchanged.

## Current verification record

On 2026-07-28, Pi 0.81.1 live-reported native `subagent` and a scratch extension verified that its `tool_call` event can block that exact tool.
Codex 0.145.0 live-reported `collaboration.spawn_agent`, `collaboration.followup_task`, `collaboration.list_agents`, `collaboration.wait_agent`, `collaboration.interrupt_agent`, and `collaboration.send_message`; its hook payload flattens those to tokens such as `collaborationspawn_agent` and `collaborationlist_agents`.
A scratch primary verified that `PreToolUse` exit 2 blocks the spawn call with stderr as the model-visible reason, while the flattened list operation remains allowed.
OpenCode 1.18.4 returned a billing error before a live tool-call probe, and Grok was unavailable.
Do not describe either unverified runtime as enforced until its exact tool token and block behavior pass a scratch-project smoke test.

## Local Claude hardening

A captain may additionally maintain an untracked per-home Claude `permissions.deny` list for known delegation tools.
That list removes tools from the model schema and is stronger than interception, but it must never be committed to tracked `.claude/settings.json`: linked worker copies inherit tracked settings and must retain legitimate delegation.
The shape-based hook remains necessary for future tool names absent from a fixed local list.
