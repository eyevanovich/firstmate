#!/usr/bin/env bash
# Opt-in OpenCode continuity regression on an isolated persistent TUI, project,
# database, tmux socket, and FM_HOME. It verifies the native plugin lifecycle
# without requiring a successful provider response: current adapter behavior is
# observable before any model handles the canonical watcher prompt.
set -u

if [ "${FM_OPENCODE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OPENCODE_LIVE_E2E=1 to run the interactive OpenCode continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v opencode >/dev/null 2>&1 || fail "opencode not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found"

TMUX=$(command -v tmux)
SOCKET="fm-opencode-live-e2e-$$"
SESSION=opencode-live-e2e
LAB="$ROOT/.opencode-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
DB="$LAB/opencode.db"
OPENCODE_VERSION=$(opencode --version)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

wait_for_watcher() {
  local i=0 watcher_pid
  while [ "$i" -lt 120 ]; do
    watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
# git clone carries only committed state, so overlay the complete working-tree
# plugin and script surfaces under verification.
cp -R "$ROOT/.opencode/." "$PROJECT/.opencode/"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/opencode-e2e.meta"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "bash -lc 'export OPENCODE_DB=\"$DB\" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT=\"{\\\"permission\\\":{\\\"*\\\":\\\"allow\\\"}}\" FM_HOME=\"$HOME_DIR\" FM_ROOT_OVERRIDE=\"$PROJECT\" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600; printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; opencode --auto; rc=\$?; printf \"OPENCODE_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

wait_for_text "$OPENCODE_VERSION" 120 || fail "OpenCode did not reach its persistent TUI"

# Some versions create and idle a session at startup; others need one submitted
# message before session.idle has a session id. The provider response may fail,
# but the native event and plugin lifecycle remain observable.
if ! wait_for_watcher; then
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "Respond exactly INITIAL."
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
  wait_for_watcher || fail "OpenCode did not emit a session.idle event that armed the watcher"
fi

printf 'done: opencode live e2e watcher fire\n' > "$HOME_DIR/state/opencode-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "OpenCode plugin did not start and ledger-link a successor before wake delivery"

prompt_text=
i=0
while [ "$i" -lt 120 ]; do
  if [ -f "$DB" ]; then
    prompt_text=$(sqlite3 "$DB" \
      "select json_extract(p.data,'$.text') from message m join part p on p.message_id=m.id where json_extract(p.data,'$.text') like '%FIRSTMATE_OP: v1 watcher:%' order by m.time_created desc limit 1;" \
      2>/dev/null || true)
  fi
  [ -n "$prompt_text" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -n "$prompt_text" ] || fail "OpenCode watcher wake was not persisted as a typed operational input"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
kind=
fm_operational_input_classify "$prompt_text" kind || fail "OpenCode watcher wake is not a valid current operational input"
[ "$kind" = watcher ] || fail "OpenCode watcher wake classified as '$kind', not watcher"

watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
if [ -z "$watcher_pid" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
  fail "OpenCode successor watcher was not live after canonical wake delivery"
fi

printf 'ok - OpenCode %s live TUI started one successor before canonical watcher delivery; provider handling was not required\n' "$OPENCODE_VERSION"
