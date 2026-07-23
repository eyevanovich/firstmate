#!/usr/bin/env bash
# fm-no-mistakes-observer.sh - start a worker-owned no-mistakes validation and
# own its separate captain-visible observer terminal.
#
# Usage:
#   fm-no-mistakes-observer.sh start <task-id>
#   fm-no-mistakes-observer.sh open <task-id> [--run <run-id>]
#   fm-no-mistakes-observer.sh reopen <task-id> [--run <run-id>]
#   fm-no-mistakes-observer.sh cleanup <task-id>
#
# `start` is the normal Firstmate entrypoint. It validates a no-mistakes ship,
# sends the recorded harness its verified skill invocation through fm-send.sh,
# waits until `no-mistakes axi status` returns an authoritative run id for the
# task branch, then opens the observer. An already-running branch run is adopted
# without sending the skill again, so retries do not start duplicate runs.
# claude and grok receive `/no-mistakes`; codex receives `$no-mistakes`;
# opencode and pi receive the natural-language instruction `Run the no-mistakes
# skill now to validate and ship this committed branch.`. The worker remains the
# sole owner of every `no-mistakes axi run/respond` call.
#
# `open` performs only run discovery plus observer reconciliation. It never
# sends the worker a validation command. `reopen` is the explicit action that
# may replace an observer the captain detached with q or whose terminal exited.
# Ordinary start/open retries preserve a detached observer record and print the
# exact manual `no-mistakes attach --run <id>` command instead of respawning it.
#
# Supported observer hosts:
#   tmux   A detached (`new-window -d`) sibling window in the worker session.
#          The record stores and cleanup verifies the stable window/pane ids,
#          unique label, task/run/token user options, and original worker target.
#   herdr  A `tab create --no-focus` sibling tab in the worker's recorded
#          session/workspace. The attach wrapper is typed into that new pane
#          with `pane send-text`, then started in the foreground with
#          `pane send-keys ... enter`; `pane run` is not used because it blocks
#          its caller for the foreground command's lifetime. The record stores
#          and cleanup verifies the exact session/workspace/tab/pane ids plus a
#          token-bearing unique label.
# zellij, orca, and cmux task runtimes are deliberately unsupported until their
# observer focus and exact-terminal cleanup behavior is empirically verified.
# Validation continues unchanged and this script prints the exact manual attach
# command on those backends or after any observer-only failure.
#
# Observer command: `no-mistakes attach --run <run-id>`. Upstream documents q as
# detach while the pipeline continues in the daemon. Observer launch, failure,
# interaction, and exit never invoke axi respond/abort, stop the daemon, cancel
# validation, change merge authority, or replace/type into the worker endpoint.
#
# State record: state/<task-id>.observer, an atomic mode-0600 regular file.
# Exact v1 fields are version, task, run, branch, worker_backend, worker_target,
# observer_backend, observer_label, observer_target, observer_session,
# observer_workspace_id, observer_tab_id, observer_pane_id, token, status,
# exit_code, created_at, and updated_at. Status is creating, ready, staging,
# staged, submitting, submitted, attached, detached, or failed. The token is generated
# before endpoint creation and is
# embedded in the visible label, so an interrupted create can be reconciled
# idempotently without guessing from a task label alone. Herdr additionally
# records staging, staged, and submitting around its separate text and Enter
# operations so retries never repeat an operation with an unknown outcome.
#
# `cleanup` is called by fm-teardown.sh after landing/safety checks and before
# destructive task cleanup. It refuses to close anything while the recorded run
# still reports running, validates the record against current task metadata,
# then closes only the exact identity-matched observer endpoint. A missing exact
# endpoint is treated as already detached; an identity mismatch refuses instead
# of touching a possibly unrelated terminal. cleanup never kills the worker.
#
# Test overrides:
#   FM_NM_OBSERVER_NO_MISTAKES  no-mistakes executable (default: PATH lookup)
#   FM_NM_OBSERVER_SEND_BIN     fm-send executable (default: sibling script)
#   FM_NM_OBSERVER_WAIT_SECS    run-id discovery budget (default: 180)
#   FM_NM_OBSERVER_POLL_SECS    discovery interval (default: 1)
#   FM_NM_OBSERVER_SETTLE_SECS  post-launch record check delay (default: 0.2)
#   FM_NM_OBSERVER_COMMAND_TIMEOUT seconds allowed per observer-only CLI read or
#                                  terminal mutation before safe fallback
#                                  (default: 10)
#   FM_NM_OBSERVER_SESSION_RETRIES bounded internal session lock attempts
#                                  (default: 100)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NM_BIN="${FM_NM_OBSERVER_NO_MISTAKES:-no-mistakes}"
SEND_BIN="${FM_NM_OBSERVER_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
WAIT_SECS="${FM_NM_OBSERVER_WAIT_SECS:-180}"
POLL_SECS="${FM_NM_OBSERVER_POLL_SECS:-1}"
SETTLE_SECS="${FM_NM_OBSERVER_SETTLE_SECS:-0.2}"
COMMAND_TIMEOUT="${FM_NM_OBSERVER_COMMAND_TIMEOUT:-10}"
SESSION_RETRIES="${FM_NM_OBSERVER_SESSION_RETRIES:-100}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

manual_attach_command() {  # <worktree> <run-id>
  printf 'cd %s && no-mistakes attach --run %s' "$(shell_quote "$1")" "$(shell_quote "$2")"
}

observer_notice_manual() {  # <reason> <worktree> <run-id>
  printf 'observer: %s\n' "$1" >&2
  printf 'observer: attach manually with: %s\n' "$(manual_attach_command "$2" "$3")" >&2
}

observer_id_valid() {
  fm_task_id_path_safe "${1:-}"
}

run_id_valid() {
  local id=${1:-} LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

number_valid() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

sleep_number_valid() {
  [[ "${1:-}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

run_bounded() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  fi
}

observer_tmux_cli() {
  run_bounded "$COMMAND_TIMEOUT" tmux "$@"
}

observer_herdr_cli() {  # <session> <herdr arguments...>
  local session=$1
  shift
  run_bounded "$COMMAND_TIMEOUT" env HERDR_SESSION="$session" herdr "$@" --session "$session"
}

record_reset() {
  R_VERSION=
  R_TASK=
  R_RUN=
  R_BRANCH=
  R_WORKER_BACKEND=
  R_WORKER_TARGET=
  R_OBSERVER_BACKEND=
  R_OBSERVER_LABEL=
  R_OBSERVER_TARGET=
  R_OBSERVER_SESSION=
  R_OBSERVER_WORKSPACE_ID=
  R_OBSERVER_TAB_ID=
  R_OBSERVER_PANE_ID=
  R_TOKEN=
  R_STATUS=
  R_EXIT_CODE=
  R_CREATED_AT=
  R_UPDATED_AT=
}

record_mode() {  # <path>
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

record_load() {  # <path>
  local path=$1 line key value seen='|' mode
  record_reset
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(record_mode "$path") || return 1
  [ "$mode" = 600 ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$seen" in *"|$key|"*) return 1 ;; esac
    seen="$seen$key|"
    case "$key" in
      version) R_VERSION=$value ;;
      task) R_TASK=$value ;;
      run) R_RUN=$value ;;
      branch) R_BRANCH=$value ;;
      worker_backend) R_WORKER_BACKEND=$value ;;
      worker_target) R_WORKER_TARGET=$value ;;
      observer_backend) R_OBSERVER_BACKEND=$value ;;
      observer_label) R_OBSERVER_LABEL=$value ;;
      observer_target) R_OBSERVER_TARGET=$value ;;
      observer_session) R_OBSERVER_SESSION=$value ;;
      observer_workspace_id) R_OBSERVER_WORKSPACE_ID=$value ;;
      observer_tab_id) R_OBSERVER_TAB_ID=$value ;;
      observer_pane_id) R_OBSERVER_PANE_ID=$value ;;
      token) R_TOKEN=$value ;;
      status) R_STATUS=$value ;;
      exit_code) R_EXIT_CODE=$value ;;
      created_at) R_CREATED_AT=$value ;;
      updated_at) R_UPDATED_AT=$value ;;
      *) return 1 ;;
    esac
  done < "$path"

  [ "$R_VERSION" = 1 ] || return 1
  observer_id_valid "$R_TASK" || return 1
  run_id_valid "$R_RUN" || return 1
  [ -n "$R_BRANCH" ] || return 1
  fm_backend_is_known "$R_WORKER_BACKEND" || return 1
  [ -n "$R_WORKER_TARGET" ] || return 1
  case "$R_OBSERVER_BACKEND" in tmux|herdr) ;; *) return 1 ;; esac
  [ -n "$R_OBSERVER_LABEL" ] || return 1
  case "$R_TOKEN" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  [ "${#R_TOKEN}" -eq 32 ] || return 1
  case "$R_STATUS" in creating|ready|staging|staged|submitting|submitted|attached|detached|failed) ;; *) return 1 ;; esac
  if [ "$R_STATUS" != creating ] && [ "$R_STATUS" != failed ]; then
    [ -n "$R_OBSERVER_TARGET" ] || return 1
  fi
  case "$R_EXIT_CODE" in ''|*[!0-9]*) [ -z "$R_EXIT_CODE" ] || return 1 ;; esac
  number_valid "$R_CREATED_AT" || return 1
  number_valid "$R_UPDATED_AT" || return 1
  return 0
}

record_write() {  # <path>; globals R_*
  local path=$1 tmp old_umask
  mkdir -p "$STATE"
  [ ! -L "$path" ] || return 1
  R_UPDATED_AT=$(date +%s)
  [ -n "$R_CREATED_AT" ] || R_CREATED_AT=$R_UPDATED_AT
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$STATE/.${R_TASK}.observer.XXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  {
    printf 'version=%s\n' "$R_VERSION"
    printf 'task=%s\n' "$R_TASK"
    printf 'run=%s\n' "$R_RUN"
    printf 'branch=%s\n' "$R_BRANCH"
    printf 'worker_backend=%s\n' "$R_WORKER_BACKEND"
    printf 'worker_target=%s\n' "$R_WORKER_TARGET"
    printf 'observer_backend=%s\n' "$R_OBSERVER_BACKEND"
    printf 'observer_label=%s\n' "$R_OBSERVER_LABEL"
    printf 'observer_target=%s\n' "$R_OBSERVER_TARGET"
    printf 'observer_session=%s\n' "$R_OBSERVER_SESSION"
    printf 'observer_workspace_id=%s\n' "$R_OBSERVER_WORKSPACE_ID"
    printf 'observer_tab_id=%s\n' "$R_OBSERVER_TAB_ID"
    printf 'observer_pane_id=%s\n' "$R_OBSERVER_PANE_ID"
    printf 'token=%s\n' "$R_TOKEN"
    printf 'status=%s\n' "$R_STATUS"
    printf 'exit_code=%s\n' "$R_EXIT_CODE"
    printf 'created_at=%s\n' "$R_CREATED_AT"
    printf 'updated_at=%s\n' "$R_UPDATED_AT"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

pending_load() {  # <path>
  local path=$1 line key value seen='|' mode
  P_TASK= P_RUN= P_TOKEN= P_EXIT_CODE=
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(record_mode "$path") || return 1
  [ "$mode" = 600 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$seen" in *"|$key|"*) return 1 ;; esac
    seen="$seen$key|"
    case "$key" in
      task) P_TASK=$value ;;
      run) P_RUN=$value ;;
      token) P_TOKEN=$value ;;
      exit_code) P_EXIT_CODE=$value ;;
      *) return 1 ;;
    esac
  done < "$path"
  observer_id_valid "$P_TASK" || return 1
  run_id_valid "$P_RUN" || return 1
  case "$P_TOKEN" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  [ "${#P_TOKEN}" -eq 32 ] || return 1
  case "$P_EXIT_CODE" in ''|*[!0-9]*) [ -z "$P_EXIT_CODE" ] || return 1 ;; esac
}

pending_write() {  # <task-id> <run-id> <token> <exit-code>
  local id=$1 run=$2 token=$3 exit_code=$4 path="$STATE/$1.observer.pending" tmp old_umask
  mkdir -p "$STATE"
  [ ! -L "$path" ] || return 1
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$STATE/.${id}.observer.pending.XXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  {
    printf 'task=%s\n' "$id"
    printf 'run=%s\n' "$run"
    printf 'token=%s\n' "$token"
    printf 'exit_code=%s\n' "$exit_code"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

pending_consume() {  # <task-id>
  local id=$1 pending="$STATE/$1.observer.pending" record="$STATE/$1.observer"
  [ -e "$pending" ] || [ -L "$pending" ] || return 0
  pending_load "$pending" || return 1
  [ "$P_TASK" = "$id" ] || return 1
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    rm -f "$pending"
    return 0
  fi
  record_load "$record" || return 1
  if [ "$R_TASK" != "$P_TASK" ] || [ "$R_RUN" != "$P_RUN" ] || [ "$R_TOKEN" != "$P_TOKEN" ]; then
    rm -f "$pending"
    return 0
  fi
  case "$R_STATUS" in
    ready|submitted|attached)
      R_STATUS=detached
      R_EXIT_CODE=$P_EXIT_CODE
      record_write "$record" || return 1
      ;;
  esac
  rm -f "$pending"
}

generate_token() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

lock_acquire() {  # <task-id>
  local id=$1 pid_file pid
  LOCK_DIR="$STATE/.$id.observer.lock"
  mkdir -p "$STATE"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || return 1
  pid_file="$LOCK_DIR/pid"
  pid=$(cat "$pid_file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  rm -f "$pid_file" 2>/dev/null || return 1
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

lock_release() {
  [ -n "${LOCK_DIR:-}" ] || return 0
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_DIR=
}

meta_load() {  # <task-id>
  local id=$1
  META="$STATE/$id.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe metadata for task $id at $META" >&2; return 1; }
  WT=$(fm_meta_get "$META" worktree)
  KIND=$(fm_meta_get "$META" kind)
  MODE=$(fm_meta_get "$META" mode)
  HARNESS=$(fm_meta_get "$META" harness)
  WORKER_BACKEND=$(fm_backend_of_meta "$META")
  WORKER_TARGET=$(fm_backend_target_of_meta "$META")
  [ -n "$KIND" ] || KIND=ship
  [ -n "$MODE" ] || MODE=no-mistakes
  [ -n "$WT" ] && [ -d "$WT" ] || { echo "error: task $id has no live worktree" >&2; return 1; }
  [ "$KIND" = ship ] || { echo "error: task $id is kind=$KIND, not a ship" >&2; return 1; }
  [ "$MODE" = no-mistakes ] || { echo "error: task $id uses mode=$MODE, not no-mistakes" >&2; return 1; }
  [ -n "$WORKER_TARGET" ] || { echo "error: task $id has no recorded worker endpoint" >&2; return 1; }
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: task $id is not on a named branch" >&2; return 1; }
}

record_matches_meta() {
  [ "$R_TASK" = "$ID" ] \
    && [ "$R_BRANCH" = "$BRANCH" ] \
    && [ "$R_WORKER_BACKEND" = "$WORKER_BACKEND" ] \
    && [ "$R_WORKER_TARGET" = "$WORKER_TARGET" ]
}

strip_toon_scalar() {  # <value>
  local value=${1:-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  printf '%s' "$value"
}

NM_OUT=
NM_ID=
NM_BRANCH=
NM_STATUS=
nm_capture() {  # [run-id]
  local run=${1:-}
  if [ -n "$run" ]; then
    NM_OUT=$(cd "$WT" && run_bounded "$COMMAND_TIMEOUT" "$NM_BIN" axi status --run "$run" 2>/dev/null) || NM_OUT=
  else
    NM_OUT=$(cd "$WT" && run_bounded "$COMMAND_TIMEOUT" "$NM_BIN" axi status 2>/dev/null) || NM_OUT=
  fi
  NM_ID=$(strip_toon_scalar "$(printf '%s\n' "$NM_OUT" | sed -n 's/^[[:space:]]*id:[[:space:]]*//p' | head -1)")
  NM_BRANCH=$(strip_toon_scalar "$(printf '%s\n' "$NM_OUT" | sed -n 's/^[[:space:]]*branch:[[:space:]]*//p' | head -1)")
  NM_STATUS=$(strip_toon_scalar "$(printf '%s\n' "$NM_OUT" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)")
  run_id_valid "$NM_ID" || return 1
  [ "$NM_BRANCH" = "$BRANCH" ] || return 1
  if [ -n "$run" ]; then
    [ "$NM_ID" = "$run" ] || return 1
  fi
  return 0
}

nm_status_terminal() {  # <run-id>
  nm_capture "$1" || return 1
  case "$NM_STATUS" in completed|failed|cancelled) return 0 ;; esac
  return 1
}

nm_status_running() {  # <run-id>
  nm_capture "$1" || return 1
  [ "$NM_STATUS" = running ]
}

validation_invocation() {  # <harness>
  # shellcheck disable=SC2016  # The dollar sign is the literal Codex skill prefix.
  case "$1" in
    claude|grok) printf '/no-mistakes' ;;
    codex) printf '$no-mistakes' ;;
    opencode|pi) printf 'Run the no-mistakes skill now to validate and ship this committed branch.' ;;
    *) return 1 ;;
  esac
}

resolve_nm_bin() {
  case "$NM_BIN" in
    */*) [ -x "$NM_BIN" ] || return 1 ;;
    *) NM_BIN=$(command -v "$NM_BIN") || return 1 ;;
  esac
}

observer_record_initialize() {  # <run-id>
  local run=$1 token label now
  token=$(generate_token)
  [ "${#token}" -eq 32 ] || return 1
  label="nm-observer-$ID-${token:0:8}"
  now=$(date +%s)
  record_reset
  R_VERSION=1
  R_TASK=$ID
  R_RUN=$run
  R_BRANCH=$BRANCH
  R_WORKER_BACKEND=$WORKER_BACKEND
  R_WORKER_TARGET=$WORKER_TARGET
  R_OBSERVER_BACKEND=$WORKER_BACKEND
  R_OBSERVER_LABEL=$label
  R_TOKEN=$token
  R_STATUS=creating
  R_CREATED_AT=$now
  R_UPDATED_AT=$now
  record_write "$RECORD"
}

session_command() {
  local script nm
  script=$(shell_quote "$SCRIPT_DIR/fm-no-mistakes-observer.sh")
  nm=$(shell_quote "$NM_BIN")
  printf 'exec env FM_HOME=%s FM_STATE_OVERRIDE=%s FM_ROOT_OVERRIDE=%s FM_NM_OBSERVER_NO_MISTAKES=%s %s _session %s %s %s' \
    "$(shell_quote "$FM_HOME")" "$(shell_quote "$STATE")" "$(shell_quote "$FM_ROOT")" "$nm" "$script" \
    "$(shell_quote "$ID")" "$(shell_quote "$R_RUN")" "$(shell_quote "$R_TOKEN")"
}

tmux_find_provisional_endpoint() {  # 0=one owned candidate, 1=gone, 2=ambiguous/error
  local rows count out wid pane label task run token
  [ -n "$R_OBSERVER_SESSION" ] || return 2
  rows=$(observer_tmux_cli list-windows -t "$R_OBSERVER_SESSION" \
    -F '#{window_id}	#{pane_id}	#{window_name}	#{@fm_observer_task}	#{@fm_observer_run}	#{@fm_observer_token}' 2>/dev/null) || return 2
  count=$(printf '%s\n' "$rows" | awk -F '\t' -v want="$R_OBSERVER_LABEL" '$3 == want { count++ } END { print count + 0 }')
  [ "$count" -ne 0 ] || return 1
  [ "$count" -eq 1 ] || return 2
  out=$(printf '%s\n' "$rows" | awk -F '\t' -v want="$R_OBSERVER_LABEL" '$3 == want { print; exit }')
  IFS=$'\t' read -r wid pane label task run token <<EOF
$out
EOF
  case "$wid" in @*[!0-9]*|'@'|'') return 2 ;; esac
  case "$pane" in %*[!0-9]*|'%'|'') return 2 ;; esac
  [ "$label" = "$R_OBSERVER_LABEL" ] || return 2
  [ -z "$task" ] || [ "$task" = "$ID" ] || return 2
  [ -z "$run" ] || [ "$run" = "$R_RUN" ] || return 2
  [ -z "$token" ] || [ "$token" = "$R_TOKEN" ] || return 2
  observer_tmux_cli set-option -w -q -t "$wid" @fm_observer_task "$ID" >/dev/null 2>&1 || return 2
  observer_tmux_cli set-option -w -q -t "$wid" @fm_observer_run "$R_RUN" >/dev/null 2>&1 || return 2
  observer_tmux_cli set-option -w -q -t "$wid" @fm_observer_token "$R_TOKEN" >/dev/null 2>&1 || return 2
  R_OBSERVER_TARGET=$wid
  R_OBSERVER_PANE_ID=$pane
  return 0
}

tmux_record_identity_state() {  # prints present|gone|mismatch
  local rows out wid pane label task run token
  [ -n "$R_OBSERVER_TARGET" ] || { printf 'gone'; return 0; }
  rows=$(observer_tmux_cli list-windows -a \
    -F '#{window_id}	#{pane_id}	#{window_name}	#{@fm_observer_task}	#{@fm_observer_run}	#{@fm_observer_token}' 2>/dev/null) \
    || { printf 'mismatch'; return 0; }
  out=$(printf '%s\n' "$rows" | awk -F '\t' -v want="$R_OBSERVER_TARGET" '$1 == want { print; exit }')
  [ -n "$out" ] || { printf 'gone'; return 0; }
  IFS=$'\t' read -r wid pane label task run token <<EOF
$out
EOF
  if [ "$wid" = "$R_OBSERVER_TARGET" ] \
     && [ "$pane" = "$R_OBSERVER_PANE_ID" ] \
     && [ "$label" = "$R_OBSERVER_LABEL" ] \
     && [ "$task" = "$R_TASK" ] \
     && [ "$run" = "$R_RUN" ] \
     && [ "$token" = "$R_TOKEN" ]; then
    printf 'present'
  else
    printf 'mismatch'
  fi
}

herdr_record_identity_state() {  # prints present|gone|mismatch
  local tabs panes tab_count pane_count
  [ -n "$R_OBSERVER_SESSION" ] && [ -n "$R_OBSERVER_WORKSPACE_ID" ] \
    && [ -n "$R_OBSERVER_TAB_ID" ] && [ -n "$R_OBSERVER_PANE_ID" ] \
    || { printf 'gone'; return 0; }
  tabs=$(observer_herdr_cli "$R_OBSERVER_SESSION" tab list --workspace "$R_OBSERVER_WORKSPACE_ID" 2>/dev/null) \
    || { printf 'mismatch'; return 0; }
  tab_count=$(printf '%s' "$tabs" | jq -r --arg tab "$R_OBSERVER_TAB_ID" --arg want "$R_OBSERVER_LABEL" --arg ws "$R_OBSERVER_WORKSPACE_ID" \
    '[.result.tabs[]? | select(.tab_id == $tab and .workspace_id == $ws and .label == $want)] | length' 2>/dev/null || true)
  if [ "$tab_count" = 0 ]; then
    if printf '%s' "$tabs" | jq -e --arg tab "$R_OBSERVER_TAB_ID" '[.result.tabs[]? | select(.tab_id == $tab)] | length > 0' >/dev/null 2>&1; then
      printf 'mismatch'
    else
      printf 'gone'
    fi
    return 0
  fi
  [ "$tab_count" = 1 ] || { printf 'mismatch'; return 0; }
  panes=$(observer_herdr_cli "$R_OBSERVER_SESSION" pane list --workspace "$R_OBSERVER_WORKSPACE_ID" 2>/dev/null) \
    || { printf 'mismatch'; return 0; }
  pane_count=$(printf '%s' "$panes" | jq -r --arg pane "$R_OBSERVER_PANE_ID" --arg tab "$R_OBSERVER_TAB_ID" \
    '[.result.panes[]? | select(.pane_id == $pane and .tab_id == $tab)] | length' 2>/dev/null || true)
  [ "$pane_count" = 1 ] && printf 'present' || printf 'mismatch'
}

observer_identity_state() {
  case "$R_OBSERVER_BACKEND" in
    tmux) tmux_record_identity_state ;;
    herdr) herdr_record_identity_state ;;
  esac
}

observer_close_exact() {
  local state reconcile_rc
  if [ -z "$R_OBSERVER_TARGET" ]; then
    reconcile_rc=0
    case "$R_OBSERVER_BACKEND" in
      tmux) tmux_find_provisional_endpoint || reconcile_rc=$? ;;
      herdr) herdr_find_provisional_endpoint || reconcile_rc=$? ;;
    esac
    case "$reconcile_rc" in
      0) record_write "$RECORD" || return 1 ;;
      1) return 0 ;;
      *)
        echo "error: provisional observer identity is ambiguous for task $ID run $R_RUN; refusing to close any terminal" >&2
        return 1
        ;;
    esac
  fi
  state=$(observer_identity_state)
  case "$state" in
    gone) return 0 ;;
    mismatch)
      echo "error: observer identity mismatch for task $ID run $R_RUN; refusing to close any terminal" >&2
      return 1
      ;;
  esac
  case "$R_OBSERVER_BACKEND" in
    tmux)
      observer_tmux_cli kill-window -t "$R_OBSERVER_TARGET" >/dev/null 2>&1 || return 1
      ;;
    herdr)
      observer_herdr_cli "$R_OBSERVER_SESSION" tab close "$R_OBSERVER_TAB_ID" >/dev/null 2>&1 || return 1
      ;;
  esac
}

observer_mark_detached_if_gone() {
  local state
  state=$(observer_identity_state)
  case "$state" in
    present) return 1 ;;
    mismatch) return 2 ;;
    gone)
      R_STATUS=detached
      R_EXIT_CODE=
      record_write "$RECORD" || return 2
      return 0
      ;;
  esac
}

observer_tmux_launch() {
  local session out wid pane cmd state reconcile_rc
  session=${WORKER_TARGET%%:*}
  [ -n "$session" ] && [ "$session" != "$WORKER_TARGET" ] || return 1
  observer_tmux_cli has-session -t "$session" 2>/dev/null || return 1

  if [ "$R_STATUS" = creating ]; then
    R_OBSERVER_SESSION=$session
    record_write "$RECORD" || return 1
    reconcile_rc=0
    tmux_find_provisional_endpoint || reconcile_rc=$?
    case "$reconcile_rc" in
      0) ;;
      1)
        cmd=$(session_command)
        out=$(observer_tmux_cli new-window -dP -F '#{window_id}	#{pane_id}' -t "$session:" -n "$R_OBSERVER_LABEL" -c "$WT" "$cmd") || return 1
        IFS=$'\t' read -r wid pane <<EOF
$out
EOF
        case "$wid" in @*[!0-9]*|'@'|'') observer_tmux_cli kill-window -t "$wid" 2>/dev/null || true; return 1 ;; esac
        case "$pane" in %*[!0-9]*|'%'|'') observer_tmux_cli kill-window -t "$wid" 2>/dev/null || true; return 1 ;; esac
        observer_tmux_cli set-option -w -q -t "$wid" @fm_observer_task "$ID" || { observer_tmux_cli kill-window -t "$wid" 2>/dev/null || true; return 1; }
        observer_tmux_cli set-option -w -q -t "$wid" @fm_observer_run "$R_RUN" || { observer_tmux_cli kill-window -t "$wid" 2>/dev/null || true; return 1; }
        observer_tmux_cli set-option -w -q -t "$wid" @fm_observer_token "$R_TOKEN" || { observer_tmux_cli kill-window -t "$wid" 2>/dev/null || true; return 1; }
        R_OBSERVER_TARGET=$wid
        R_OBSERVER_PANE_ID=$pane
        ;;
      *) return 1 ;;
    esac
    R_STATUS=ready
    record_write "$RECORD" || return 1
    return 0
  fi

  state=$(tmux_record_identity_state)
  [ "$state" = present ] || return 1
  return 0
}

herdr_find_provisional_endpoint() {  # 0=one owned candidate, 1=gone, 2=ambiguous/error
  local tabs panes tab_count pane_count tab pane
  [ -n "$R_OBSERVER_SESSION" ] && [ -n "$R_OBSERVER_WORKSPACE_ID" ] || return 2
  tabs=$(observer_herdr_cli "$R_OBSERVER_SESSION" tab list --workspace "$R_OBSERVER_WORKSPACE_ID" 2>/dev/null) || return 2
  tab_count=$(printf '%s' "$tabs" | jq -r --arg want "$R_OBSERVER_LABEL" '[.result.tabs[]? | select(.label == $want)] | length' 2>/dev/null) || return 2
  [ "$tab_count" -ne 0 ] || return 1
  [ "$tab_count" -eq 1 ] || return 2
  tab=$(printf '%s' "$tabs" | jq -r --arg want "$R_OBSERVER_LABEL" '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null)
  panes=$(observer_herdr_cli "$R_OBSERVER_SESSION" pane list --workspace "$R_OBSERVER_WORKSPACE_ID" 2>/dev/null) || return 2
  pane_count=$(printf '%s' "$panes" | jq -r --arg tab "$tab" '[.result.panes[]? | select(.tab_id == $tab)] | length' 2>/dev/null) || return 2
  [ "$pane_count" -eq 1 ] || return 2
  pane=$(printf '%s' "$panes" | jq -r --arg tab "$tab" '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null)
  [ -n "$tab" ] && [ -n "$pane" ] || return 2
  R_OBSERVER_TAB_ID=$tab
  R_OBSERVER_PANE_ID=$pane
  R_OBSERVER_TARGET="$R_OBSERVER_SESSION:$pane"
}

observer_herdr_launch() {
  local session workspace worker_pane out tab pane cmd state reconcile_rc
  session=$(fm_meta_get "$META" herdr_session)
  workspace=$(fm_meta_get "$META" herdr_workspace_id)
  [ -n "$session" ] && [ -n "$workspace" ] || return 1
  case "$WORKER_TARGET" in "$session":*) worker_pane=${WORKER_TARGET#*:} ;; *) return 1 ;; esac
  [ -n "$worker_pane" ] || return 1
  observer_herdr_cli "$session" pane get "$worker_pane" >/dev/null 2>&1 || return 1

  if [ "$R_STATUS" = creating ]; then
    R_OBSERVER_SESSION=$session
    R_OBSERVER_WORKSPACE_ID=$workspace
    record_write "$RECORD" || return 1
    reconcile_rc=0
    herdr_find_provisional_endpoint || reconcile_rc=$?
    case "$reconcile_rc" in
      0) ;;
      1)
        out=$(observer_herdr_cli "$session" tab create --workspace "$workspace" --cwd "$WT" --label "$R_OBSERVER_LABEL" --no-focus 2>/dev/null) || return 1
        tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
        pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
        [ -n "$tab" ] && [ -n "$pane" ] || return 1
        R_OBSERVER_TAB_ID=$tab
        R_OBSERVER_PANE_ID=$pane
        R_OBSERVER_TARGET="$session:$pane"
        ;;
      *) return 1 ;;
    esac
    R_STATUS=ready
    record_write "$RECORD" || return 1
  fi

  state=$(herdr_record_identity_state)
  [ "$state" = present ] || return 1
  case "$R_STATUS" in
    staging|submitting) return 1 ;;
  esac
  if [ "$R_STATUS" = ready ]; then
    R_STATUS=staging
    record_write "$RECORD" || return 1
    cmd=$(session_command)
    observer_herdr_cli "$R_OBSERVER_SESSION" pane send-text "$R_OBSERVER_PANE_ID" "$cmd" >/dev/null 2>&1 || return 1
    R_STATUS=staged
    record_write "$RECORD" || return 1
  fi
  if [ "$R_STATUS" = staged ]; then
    R_STATUS=submitting
    record_write "$RECORD" || return 1
    observer_herdr_cli "$R_OBSERVER_SESSION" pane send-keys "$R_OBSERVER_PANE_ID" enter >/dev/null 2>&1 || return 1
    R_STATUS=submitted
    record_write "$RECORD" || return 1
  fi
  return 0
}

observer_launch() {
  case "$WORKER_BACKEND" in
    tmux) observer_tmux_launch ;;
    herdr) observer_herdr_launch ;;
    *) return 2 ;;
  esac
}

observer_manual_only() {  # <reason> <run-id>
  observer_notice_manual "$1" "$WT" "$2"
  return 0
}

observer_prepare_run() {  # <run-id> <allow-reopen:0|1>
  local run=$1 allow_reopen=$2 existing_state old_run
  RECORD="$STATE/$ID.observer"
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    if ! record_load "$RECORD"; then
      observer_manual_only "unsafe or malformed observer record at $RECORD; refusing to guess" "$run"
      return 1
    fi
    if ! record_matches_meta; then
      observer_manual_only "observer record does not match task $ID metadata; refusing to touch it" "$run"
      return 1
    fi
    old_run=$R_RUN
    if [ "$old_run" != "$run" ]; then
      if ! nm_status_terminal "$old_run"; then
        observer_manual_only "task/run mismatch: recorded observer run $old_run is not terminal, requested $run" "$run"
        return 1
      fi
      if ! observer_close_exact; then
        observer_manual_only "could not safely retire the exact observer for terminal run $old_run" "$run"
        return 1
      fi
      rm -f "$RECORD"
      observer_record_initialize "$run" || return 1
      return 0
    fi

    case "$R_STATUS" in
      attached)
        set +e
        observer_mark_detached_if_gone
        existing_state=$?
        set -e
        if [ "$existing_state" -eq 0 ]; then
          observer_manual_only "the observer terminal exited or was detached; it remains detached" "$run"
          return 1
        fi
        if [ "$existing_state" -eq 2 ]; then
          observer_manual_only "recorded observer identity no longer matches its terminal; refusing to touch it" "$run"
          return 1
        fi
        printf 'observer: already open for task %s run %s at %s\n' "$ID" "$run" "$R_OBSERVER_TARGET"
        return 2
        ;;
      detached|failed)
        if [ "$allow_reopen" != 1 ]; then
          observer_manual_only "the observer is $R_STATUS and will not be respawned automatically" "$run"
          return 1
        fi
        if ! observer_close_exact; then
          observer_manual_only "could not safely retire the exact $R_STATUS observer" "$run"
          return 1
        fi
        rm -f "$RECORD"
        observer_record_initialize "$run" || return 1
        return 0
        ;;
      submitted)
        observer_manual_only "the Herdr observer command was submitted and is awaiting attachment; refusing to resubmit it" "$run"
        return 1
        ;;
      creating|ready|staging|staged|submitting)
        return 0
        ;;
    esac
  fi
  observer_record_initialize "$run" || return 1
  return 0
}

observer_open_run() {  # <run-id> <allow-reopen:0|1>
  local run=$1 allow_reopen=$2 prepare_rc launch_rc current_status
  if ! nm_capture "$run"; then
    observer_manual_only "run $run is not attributable to task $ID branch $BRANCH" "$run"
    return 0
  fi
  if ! resolve_nm_bin; then
    observer_manual_only "no-mistakes executable is unavailable" "$run"
    return 0
  fi
  case "$WORKER_BACKEND" in
    tmux|herdr) ;;
    *) observer_manual_only "backend $WORKER_BACKEND cannot host a no-focus observer safely" "$run"; return 0 ;;
  esac

  set +e
  observer_prepare_run "$run" "$allow_reopen"
  prepare_rc=$?
  set -e
  case "$prepare_rc" in
    0) ;;
    2) return 0 ;;
    *) return 0 ;;
  esac

  set +e
  observer_launch
  launch_rc=$?
  set -e
  if [ "$launch_rc" -ne 0 ]; then
    if record_load "$RECORD" && [ "$R_RUN" = "$run" ]; then
      R_STATUS=failed
      record_write "$RECORD" || true
    fi
    observer_manual_only "automatic observer launch failed without affecting validation" "$run"
    return 0
  fi

  sleep "$SETTLE_SECS"
  if record_load "$RECORD" && [ "$R_RUN" = "$run" ]; then
    current_status=$R_STATUS
    case "$current_status" in
      detached|failed)
        observer_manual_only "observer terminal exited during launch without affecting validation" "$run"
        return 0
        ;;
    esac
    printf 'observer: opened task %s run %s at %s (%s, no focus)\n' "$ID" "$run" "$R_OBSERVER_TARGET" "$R_OBSERVER_BACKEND"
  fi
  return 0
}

discover_run_after_start() {  # <prior-id>
  local prior=$1 started now deadline
  started=$(date +%s)
  deadline=$((started + WAIT_SECS))
  while :; do
    if nm_capture; then
      if [ "$NM_ID" != "$prior" ]; then
        printf '%s' "$NM_ID"
        return 0
      fi
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep "$POLL_SECS"
  done
}

start_action() {
  local prior_id="" run invocation
  if nm_capture; then
    case "$NM_STATUS" in
      completed|failed|cancelled) ;;
      *)
        observer_open_run "$NM_ID" 0
        return 0
        ;;
    esac
  fi
  prior_id=$NM_ID
  invocation=$(validation_invocation "$HARNESS") || {
    echo "error: task $ID records unsupported harness '$HARNESS'; validation was not started" >&2
    return 1
  }
  FM_HOME="$FM_HOME" "$SEND_BIN" "$ID" "$invocation"
  if ! run=$(discover_run_after_start "$prior_id"); then
    echo "observer: validation instruction landed, but no new authoritative run id appeared within ${WAIT_SECS}s" >&2
    printf 'observer: retry discovery with: FM_HOME=%s %s open %s\n' \
      "$(shell_quote "$FM_HOME")" "$(shell_quote "$SCRIPT_DIR/fm-no-mistakes-observer.sh")" "$(shell_quote "$ID")" >&2
    return 0
  fi
  observer_open_run "$run" 0
}

open_action() {  # <allow-reopen:0|1> [run-id]
  local allow_reopen=$1 requested=${2:-}
  if [ -n "$requested" ]; then
    observer_open_run "$requested" "$allow_reopen"
    return 0
  fi
  if ! nm_capture; then
    echo "observer: no authoritative no-mistakes run found for task $ID branch $BRANCH" >&2
    return 0
  fi
  observer_open_run "$NM_ID" "$allow_reopen"
}

cleanup_action() {
  RECORD="$STATE/$ID.observer"
  [ -e "$RECORD" ] || [ -L "$RECORD" ] || return 0
  record_load "$RECORD" || { echo "error: unsafe or malformed observer record at $RECORD; preserving it" >&2; return 1; }
  record_matches_meta || { echo "error: observer record at $RECORD does not match task metadata; preserving it" >&2; return 1; }
  if ! nm_status_terminal "$R_RUN"; then
    echo "error: no-mistakes run $R_RUN is still running or unreadable; preserving its observer and task" >&2
    return 1
  fi
  observer_close_exact \
    || { echo "error: failed to close exact observer for task $ID run $R_RUN" >&2; return 1; }
  rm -f "$RECORD"
  rm -f "$STATE/$ID.observer.pending"
  printf 'observer: cleaned task %s run %s\n' "$ID" "$R_RUN"
}

session_record_transition() {  # <task-id> <run-id> <token> <claim|detach> <exit-code>
  local id=$1 run=$2 token=$3 action=$4 exit_code=$5 record="$STATE/$1.observer"
  lock_acquire "$id" || return 2
  if ! pending_consume "$id"; then
    lock_release
    return 1
  fi
  if ! record_load "$record" \
     || [ "$R_TASK" != "$id" ] \
     || [ "$R_RUN" != "$run" ] \
     || [ "$R_TOKEN" != "$token" ]; then
    lock_release
    return 1
  fi
  case "$action:$R_STATUS" in
    claim:ready|claim:submitted) R_STATUS=attached; R_EXIT_CODE= ;;
    detach:ready|detach:submitted|detach:attached) R_STATUS=detached; R_EXIT_CODE=$exit_code ;;
    *) lock_release; return 1 ;;
  esac
  if ! record_write "$record"; then
    lock_release
    return 1
  fi
  lock_release
  return 0
}

session_transition_bounded() {  # <task-id> <run-id> <token> <claim|detach> <exit-code>
  local id=$1 run=$2 token=$3 action=$4 exit_code=$5 transition_rc
  for _ in $(seq 1 "$SESSION_RETRIES"); do
    transition_rc=0
    session_record_transition "$id" "$run" "$token" "$action" "$exit_code" || transition_rc=$?
    if [ "$transition_rc" -eq 0 ]; then
      return 0
    fi
    [ "$transition_rc" -eq 2 ] || return 1
    sleep 0.1
  done
  return 2
}

session_action() {  # internal: <task-id> <run-id> <token>
  local id=$1 run=$2 token=$3 rc=0 claim_rc detach_rc
  observer_id_valid "$id" && run_id_valid "$run" || exit 0
  case "$token" in ''|*[!A-Fa-f0-9]*) exit 0 ;; esac
  [ "${#token}" -eq 32 ] || exit 0
  claim_rc=0
  session_transition_bounded "$id" "$run" "$token" claim "" || claim_rc=$?
  if [ "$claim_rc" -ne 0 ]; then
    if [ "$claim_rc" -eq 2 ]; then
      detach_rc=0
      session_transition_bounded "$id" "$run" "$token" detach "" || detach_rc=$?
      [ "$detach_rc" -ne 2 ] || pending_write "$id" "$run" "$token" "" || true
    fi
    exit 0
  fi
  set +e
  "$NM_BIN" attach --run "$run"
  rc=$?
  set -e
  detach_rc=0
  session_transition_bounded "$id" "$run" "$token" detach "$rc" || detach_rc=$?
  [ "$detach_rc" -ne 2 ] || pending_write "$id" "$run" "$token" "$rc" || true
  exit 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  _session)
    [ "$#" -eq 4 ] || exit 0
    number_valid "$SESSION_RETRIES" && [ "$SESSION_RETRIES" -gt 0 ] || exit 0
    session_action "$2" "$3" "$4"
    ;;
esac

fm_refuse_if_gate_agent
ACTION=${1:-}
ID=${2:-}
observer_id_valid "$ID" || { usage >&2; exit 2; }
shift 2
RUN_ARG=
case "$ACTION" in
  start|cleanup)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    ;;
  open|reopen)
    if [ "$#" -gt 0 ]; then
      if [ "$#" -ne 2 ] || [ "$1" != --run ] || ! run_id_valid "$2"; then
        usage >&2
        exit 2
      fi
      RUN_ARG=$2
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac
number_valid "$WAIT_SECS" || { echo "error: FM_NM_OBSERVER_WAIT_SECS must be a non-negative integer" >&2; exit 2; }
number_valid "$COMMAND_TIMEOUT" && [ "$COMMAND_TIMEOUT" -gt 0 ] \
  || { echo "error: FM_NM_OBSERVER_COMMAND_TIMEOUT must be a positive integer" >&2; exit 2; }
sleep_number_valid "$POLL_SECS" || { echo "error: FM_NM_OBSERVER_POLL_SECS must be a non-negative number" >&2; exit 2; }
sleep_number_valid "$SETTLE_SECS" || { echo "error: FM_NM_OBSERVER_SETTLE_SECS must be a non-negative number" >&2; exit 2; }
meta_load "$ID" || exit 1
resolve_nm_bin || { echo "error: no-mistakes executable is unavailable" >&2; exit 1; }
lock_acquire "$ID" || { echo "error: observer lifecycle is already active for task $ID" >&2; exit 1; }
trap lock_release EXIT
pending_consume "$ID" || { echo "error: unsafe pending observer transition for task $ID" >&2; exit 1; }

case "$ACTION" in
  start) start_action ;;
  open) open_action 0 "$RUN_ARG" ;;
  reopen) open_action 1 "$RUN_ARG" ;;
  cleanup) cleanup_action ;;
esac
