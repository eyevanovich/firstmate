#!/usr/bin/env bash
# Guard a genuine Firstmate primary against native delegation outside the fleet.
#
# Usage:
#   <PreToolUse JSON> | bin/fm-subagent-pretool-check.sh [--claude|--stderr-only]
#   bin/fm-subagent-pretool-check.sh --tool <tool-name> [--claude|--stderr-only]
#
# The tool-name classifier is the single owner of launch-shaped delegation
# detection. Stdin payloads may also carry tool_input.action so multiplexed tools
# such as Pi's subagent can retain observe and stop operations without retaining
# launch, resume, scheduling, or steering operations.
#
# Exit contract:
#   0 - allow or inert outside a genuine Firstmate primary home; no output.
#   2 - deny. --claude writes Claude's JSON to stderr and nothing to stdout.
#       --stderr-only writes a plain reason to stderr. Default additionally
#       writes Grok's decision JSON to stdout.
#
# Malformed or empty stdin and missing jq fail open. Set FM_ALLOW_SUBAGENT=1 in
# the primary session's launch environment for the only deliberate escape.
set -u

DELEGATION_STEMS='agent subagent task workflow cron schedul worktree delegate spawn dispatch handoff remote sendmessage monitor'
OBSERVE_ONLY_TOOLS='taskoutput taskstop taskget tasklist taskstatus cronlist bashoutput killshell listagents wait waitagent interruptagent subagentwait subagentsupervisor getcommandorsubagentoutput'
MULTIPLEXED_OBSERVE_ACTIONS='list get models status interrupt stop pending doctor watchdog.status watchdog.check watchdog.recommend-model schedule-list schedule-status schedule-cancel'

TOOL=""
TOOL_SET=0
TOOL_ACTION=""
CLAUDE_MODE=0
STDERR_ONLY=0

usage() {
  cat <<'EOF'
Usage: fm-subagent-pretool-check.sh [--tool <tool-name>] [--claude|--stderr-only]

Denies launch-shaped native delegation in a genuine Firstmate primary home.
Stdin mode reads tool_name/tool_input (Claude and Codex) or toolName/toolInput
(Grok). CLI mode is for adapters that already hold the tool name.
Set FM_ALLOW_SUBAGENT=1 when launching the primary session for the sole escape.
Malformed stdin fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --stderr-only)
      STDERR_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty) | select(type == "string")' 2>/dev/null) || exit 0
  TOOL_ACTION=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.action // .toolInput.action // empty) | select(type == "string")' 2>/dev/null) || exit 0
fi

[ -n "$TOOL" ] || exit 0
LC_ALL=C TOOL_LOWER=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')

# MCP servers choose their own tool names; delegation nouns there do not imply
# native harness delegation.
case "$TOOL_LOWER" in
  mcp__*|mcp.*|mcp/*|functions.mcp__*) exit 0 ;;
esac

TOOL_BASENAME=${TOOL_LOWER##*.}
TOOL_BASENAME=${TOOL_BASENAME##*/}
TOOL_BASENAME=${TOOL_BASENAME##*__}
LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL_LOWER" | tr -cd 'a-z0-9')
LC_ALL=C NORMALIZED_BASENAME=$(printf '%s' "$TOOL_BASENAME" | tr -cd 'a-z0-9')
NORMALIZED_OPERATION=$NORMALIZED_BASENAME
# Codex currently removes the namespace separator before delivering hook tool
# names (for example collaborationlist_agents). Pi or another adapter may do
# the same with a functions namespace.
case "$NORMALIZED_OPERATION" in
  collaborations*) NORMALIZED_OPERATION=${NORMALIZED_OPERATION#collaborations} ;;
  collaboration*) NORMALIZED_OPERATION=${NORMALIZED_OPERATION#collaboration} ;;
  functions*) NORMALIZED_OPERATION=${NORMALIZED_OPERATION#functions} ;;
esac

for allowed in $OBSERVE_ONLY_TOOLS; do
  [ "$NORMALIZED_OPERATION" != "$allowed" ] || exit 0
done

# Pi exposes launch and management through one `subagent` tool. An explicit
# observe-or-stop action stays available; missing action is launch-shaped.
if [ "$NORMALIZED_OPERATION" = subagent ] && [ -n "$TOOL_ACTION" ]; then
  for allowed_action in $MULTIPLEXED_OBSERVE_ACTIONS; do
    [ "$TOOL_ACTION" != "$allowed_action" ] || exit 0
  done
fi

MATCHED=""
for stem in $DELEGATION_STEMS; do
  case "$NORMALIZED" in
    *"$stem"*) MATCHED=$stem; break ;;
  esac
done
[ -n "$MATCHED" ] || exit 0

# The environment-only launch escape cannot be forged by an in-session tool
# call for the call that follows. Every other value retains the guard.
[ "${FM_ALLOW_SUBAGENT:-}" != 1 ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

ROUTE='first classify the work under the AGENTS.md intake contract, then write its instructions with bin/fm-brief.sh and dispatch it with bin/fm-spawn.sh'
REASON="[subagent-dispatch] the Firstmate primary dispatches through its durable supervised lifecycle, not native delegation tools: work started natively has no durable fleet record and dies with this session. Instead, $ROUTE (blocked tool: $TOOL, launch-shaped on \"$MATCHED\"). Launch the primary session with FM_ALLOW_SUBAGENT=1 for a deliberate exception."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
if [ "$STDERR_ONLY" -eq 1 ]; then
  printf '%s\n' "$REASON" >&2
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
fi
[ "$CLAUDE_MODE" -eq 1 ] || [ "$STDERR_ONLY" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
