#!/usr/bin/env bash
# Primary native-delegation guard behavior, scope, and harness wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
trap fm_test_cleanup EXIT

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_tool() { # <tool> [env assignment...]
  local tool=$1 rc=0
  shift
  : > "$OUT"; : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" >"$OUT" 2>"$ERR" || rc=$?
  return "$rc"
}

run_payload() { # <mode-or-empty> <json>
  local mode=$1 payload=$2 rc=0
  : > "$OUT"; : > "$ERR"
  if [ -n "$mode" ]; then
    printf '%s' "$payload" | env \
      FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" "$mode" >"$OUT" 2>"$ERR" || rc=$?
  else
    printf '%s' "$payload" | env \
      FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" >"$OUT" 2>"$ERR" || rc=$?
  fi
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote output"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) Claude deny wrote stdout"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) omitted Claude denial JSON: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) omitted routing reason"
}

test_guard_denies_known_and_future_launch_shapes() {
  local tool
  for tool in \
    Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage \
    EnterWorktree ExitWorktree CronCreate CronDelete TaskCreate TaskUpdate \
    SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun ScheduleJob \
    CreateWorktree DispatchAgent TaskHandoff RemoteExec BackgroundAgent \
    collaboration.spawn_agent collaboration.followup_task collaboration.send_message \
    collaborationspawn_agent collaborationfollowup_task collaborationsend_message \
    functions.subagent functionssubagent; do
    expect_deny "launch-shaped tool" "$tool"
  done
  pass "subagent guard: known current and hypothetical future launch shapes deny"
}

test_guard_allows_ordinary_observe_and_stop_tools() {
  local tool
  for tool in \
    Bash Edit Read Write Skill ToolSearch WebFetch WebSearch ReportFindings \
    TaskOutput TaskStop TaskGet TaskList TaskStatus CronList BashOutput KillShell \
    collaboration.list_agents collaboration.wait_agent collaboration.interrupt_agent \
    collaborationlist_agents collaborationwait collaborationinterrupt_agent \
    functions.subagent_wait functions.subagent_supervisor functionssubagent_wait \
    collaboration.get_command_or_subagent_output collaborationget_command_or_subagent_output; do
    expect_allow "ordinary or observe-stop tool" "$tool"
  done
  pass "subagent guard: ordinary and observe-or-stop operations remain available"
}

test_guard_excludes_mcp_names_before_shape_matching() {
  local tool
  for tool in \
    mcp__linear__list_issues mcp__tracker__create_task mcp__acme__spawn_agent \
    mcp.tracker.delegate_task mcp/tracker/monitor_agent functions.mcp__tracker__send_message; do
    expect_allow "MCP tool" "$tool"
  done
  pass "subagent guard: MCP-owned names never imply native delegation"
}

test_pi_multiplexed_actions_distinguish_launch_from_observe_stop() {
  local action rc
  for action in list get models status interrupt stop pending doctor watchdog.status watchdog.check schedule-list schedule-status schedule-cancel; do
    rc=0
    run_payload --stderr-only "{\"tool_name\":\"functions.subagent\",\"tool_input\":{\"action\":\"$action\"}}" || rc=$?
    [ "$rc" -eq 0 ] || fail "Pi observe/stop action $action must allow, got $rc: $(cat "$ERR")"
  done
  for action in resume steer append-step create update schedule; do
    rc=0
    run_payload --stderr-only "{\"tool_name\":\"functions.subagent\",\"tool_input\":{\"action\":\"$action\"}}" || rc=$?
    [ "$rc" -eq 2 ] || fail "Pi work-creating action $action must deny, got $rc"
  done
  rc=0
  run_payload --stderr-only '{"tool_name":"functions.subagent","tool_input":{"agent":"reviewer","task":"work"}}' || rc=$?
  [ "$rc" -eq 2 ] || fail "Pi omitted-action launch must deny, got $rc"
  pass "subagent guard: Pi multiplexed tool preserves observe and stop without preserving launch"
}

test_transport_and_output_contracts() {
  local rc=0 payload
  run_payload --claude '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude stdin payload must deny"
  [ ! -s "$OUT" ] || fail "Claude denial wrote stdout"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "Claude denial shape missing"

  rc=0
  run_payload --stderr-only '{"tool_name":"collaboration.spawn_agent","tool_input":{}}' || rc=$?
  [ "$rc" -eq 2 ] || fail "Codex stdin payload must deny"
  [ ! -s "$OUT" ] || fail "stderr-only denial wrote stdout"
  grep -F '[subagent-dispatch]' "$ERR" >/dev/null || fail "stderr-only reason missing"

  rc=0
  run_payload '' '{"toolName":"Agent"}' || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok stdin payload must deny"
  jq -e '.decision == "deny" and (.reason | startswith("[subagent-dispatch]"))' "$OUT" >/dev/null 2>&1 \
    || fail "Grok decision object missing"

  for payload in '' '{not-json' '{}' '{"tool_name":null}'; do
    rc=0
    run_payload --claude "$payload" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed payload must fail open: $payload"
    [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "malformed payload wrote output"
  done
  pass "subagent guard: Claude, Codex, Grok, and malformed transports honor output contracts"
}

test_missing_jq_stdin_fails_open() {
  local fakebin bash_bin cat_bin rc=0
  fakebin="$TMP_ROOT/no-jq"
  bash_bin=$(command -v bash) || fail "bash required"
  cat_bin=$(command -v cat) || fail "cat required"
  mkdir -p "$fakebin"
  ln -s "$bash_bin" "$fakebin/bash"
  ln -s "$cat_bin" "$fakebin/cat"
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent"}' | env PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --claude >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open, got $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "missing jq fail-open wrote output"
  pass "subagent guard: missing jq cannot disable every tool"
}

test_escape_hatch_is_exact() {
  local value rc
  expect_allow "exact escape" Agent FM_ALLOW_SUBAGENT=1
  for value in '' 0 yes true 11; do
    rc=0
    run_tool Agent "FM_ALLOW_SUBAGENT=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_SUBAGENT=$value must not escape, got $rc"
  done
  pass "subagent guard: only exact launch-time FM_ALLOW_SUBAGENT=1 escapes"
}

test_primary_secondmate_and_linked_worker_scope() {
  local child second plain rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture

  child="$TMP_ROOT/child"
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Agent >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "linked worker must remain out of scope, got $rc"

  second="$TMP_ROOT/second"
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  rc=0
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Agent >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "marked secondmate home must be guarded, got $rc"

  plain="$TMP_ROOT/plain"
  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Agent >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "non-Firstmate repo must be inert, got $rc"
  pass "subagent guard: genuine primaries and secondmates guard while linked workers remain enabled"
}

test_pi_extension_blocks_launch_and_preserves_observe_actions() {
  local fixture plugin out rc=0
  fixture="$TMP_ROOT/pi-integration"
  plugin="$fixture/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/bin" "$fixture/state"
  git -C "$fixture" init -q
  printf '# fixture\n' > "$fixture/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$plugin"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-subagent-pretool-check.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/"
  out=$(PLUGIN="$plugin" FM_HOME="$fixture" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const toolCall = handlers.get("tool_call");
if (!toolCall) throw new Error("tool_call handler missing");
const denied = await toolCall({
  type: "tool_call",
  toolName: "subagent",
  input: { agent: "reviewer", task: "reply probe" },
});
if (denied?.block !== true || !denied.reason?.includes("[subagent-dispatch]")) {
  throw new Error(`launch was not blocked: ${JSON.stringify(denied)}`);
}
const observed = await toolCall({
  type: "tool_call",
  toolName: "subagent",
  input: { action: "status", id: "existing" },
});
if (observed?.block) throw new Error(`status was blocked: ${JSON.stringify(observed)}`);
EOF
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "Pi extension integration failed: $out"
  [ -z "$out" ] || fail "Pi extension integration printed output: $out"
  pass "subagent guard: Pi tool_call integration blocks launch and preserves observation"
}

test_tracked_harness_wiring_preserves_existing_hooks() {
  local settings codex pi
  settings="$ROOT/.claude/settings.json"
  codex="$ROOT/.codex/hooks.json"
  pi="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  jq -e 'has("permissions") | not' "$settings" >/dev/null \
    || fail "tracked Claude settings shipped Claude-only permission denials"
  jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | contains("fm-subagent-pretool-check.sh")) | .matcher] == [".*"]' "$settings" >/dev/null \
    || fail "Claude delegation hook must match all tools"
  jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | any(contains("fm-arm-pretool-check.sh")) and any(contains("fm-cd-pretool-check.sh"))' "$settings" >/dev/null \
    || fail "Claude delegation wiring displaced Bash seatbelts"
  jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | contains("fm-subagent-pretool-check.sh")) | .matcher] == [".*"]' "$codex" >/dev/null \
    || fail "Codex delegation hook must match all tools"
  jq -e '.hooks.SessionStart and .hooks.Stop and ([.hooks.PreToolUse[].hooks[].command] | any(contains("fm-arm-pretool-check.sh")) and any(contains("fm-cd-pretool-check.sh")))' "$codex" >/dev/null \
    || fail "Codex delegation wiring displaced lifecycle or Bash hooks"
  assert_grep 'runDelegationCheck' "$pi" "Pi extension omits shared delegation checker"
  assert_grep 'fm-subagent-pretool-check.sh' "$pi" "Pi extension omits checker path"
  assert_grep 'event.toolName' "$pi" "Pi extension omits live tool token"
  assert_grep 'block: true' "$pi" "Pi extension cannot block denied tool"
  pass "subagent guard: Claude, Codex, and Pi wiring preserves existing lifecycle protections"
}

test_guard_denies_known_and_future_launch_shapes
test_guard_allows_ordinary_observe_and_stop_tools
test_guard_excludes_mcp_names_before_shape_matching
test_pi_multiplexed_actions_distinguish_launch_from_observe_stop
test_transport_and_output_contracts
test_missing_jq_stdin_fails_open
test_escape_hatch_is_exact
test_primary_secondmate_and_linked_worker_scope
test_pi_extension_blocks_launch_and_preserves_observe_actions
test_tracked_harness_wiring_preserves_existing_hooks
