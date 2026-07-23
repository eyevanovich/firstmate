#!/usr/bin/env bash
# Behavior tests for the worker-owned no-mistakes observer lifecycle.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-no-mistakes-observer.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-observer)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export FM_TEST_NM_STATE="$TMP_ROOT/nm-state"
export FM_TEST_NM_LOG="$TMP_ROOT/nm.log"
export FM_TEST_SEND_LOG="$TMP_ROOT/send.log"
export FM_TEST_TMUX_STATE="$TMP_ROOT/tmux-state"
export FM_TEST_TMUX_LOG="$TMP_ROOT/tmux.log"
export FM_TEST_HERDR_STATE="$TMP_ROOT/herdr-state"
export FM_TEST_HERDR_LOG="$TMP_ROOT/herdr.log"
mkdir -p "$FM_TEST_TMUX_STATE" "$FM_TEST_HERDR_STATE"

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  run=
  if [ "${3:-}" = --run ]; then run=$4; fi
  if [ -n "$run" ] && [ -f "$FM_TEST_NM_STATE/$run" ]; then
    file="$FM_TEST_NM_STATE/$run"
  else
    file="$FM_TEST_NM_STATE/current"
  fi
  [ -f "$file" ] || exit 1
  IFS='|' read -r id branch status < "$file"
  cat <<EOF
run:
  id: $id
  branch: $branch
  status: $status
EOF
  exit 0
fi
if [ "${1:-}" = attach ] && [ "${2:-}" = --run ]; then
  printf 'attach %s\n' "$3" >> "$FM_TEST_NM_LOG"
  exit "${FM_TEST_ATTACH_RC:-0}"
fi
exit 1
SH

cat > "$FAKEBIN/fm-send" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\n' "$1" "$2" >> "$FM_TEST_SEND_LOG"
if [ -f "$FM_TEST_NM_STATE/after-send" ]; then
  cp "$FM_TEST_NM_STATE/after-send" "$FM_TEST_NM_STATE/current"
fi
SH

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s' "${1:-}" >> "$FM_TEST_TMUX_LOG"
for arg in "${@:2}"; do printf '\037%s' "$arg" >> "$FM_TEST_TMUX_LOG"; done
printf '\n' >> "$FM_TEST_TMUX_LOG"
cmd=${1:-}
shift || true
case "$cmd" in
  has-session) exit 0 ;;
  new-window)
    next=$(cat "$FM_TEST_TMUX_STATE/next" 2>/dev/null || printf 2)
    printf '%s\n' $((next + 1)) > "$FM_TEST_TMUX_STATE/next"
    wid="@$next"
    pane="%$next"
    label=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -n) label=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    {
      printf 'pane=%s\n' "$pane"
      printf 'label=%s\n' "$label"
      printf 'task=\nrun=\ntoken=\n'
    } > "$FM_TEST_TMUX_STATE/$wid"
    if [ "${FM_TEST_TMUX_BLOCK_AFTER_CREATE:-0}" = 1 ]; then
      sleep 10
    fi
    printf '%s\t%s\n' "$wid" "$pane"
    ;;
  set-option)
    target= option= value=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        @*) option=$1; value=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    file="$FM_TEST_TMUX_STATE/$target"
    [ -f "$file" ] || exit 1
    case "$option" in
      @fm_observer_task) key=task ;;
      @fm_observer_run) key=run ;;
      @fm_observer_token) key=token ;;
      *) exit 1 ;;
    esac
    tmp="$file.tmp"
    grep -v "^$key=" "$file" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
    ;;
  display-message)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    file="$FM_TEST_TMUX_STATE/$target"
    [ -f "$file" ] || exit 1
    # shellcheck disable=SC1090
    . "$file"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$pane" "$label" "$task" "$run" "$token"
    ;;
  list-windows)
    [ "${FM_TEST_TMUX_LIST_FAIL:-0}" != 1 ] || exit 1
    for file in "$FM_TEST_TMUX_STATE"/@*; do
      [ -f "$file" ] || continue
      target=${file##*/}
      # shellcheck disable=SC1090
      . "$file"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$pane" "$label" "$task" "$run" "$token"
    done
    ;;
  kill-window)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=$2; shift 2 ;; *) shift ;; esac
    done
    rm -f "$FM_TEST_TMUX_STATE/$target"
    ;;
  *) exit 1 ;;
esac
SH

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
if [ "$last" -ge 1 ] && [ "${args[$((last - 1))]}" = --session ]; then
  args=("${args[@]:0:$((last - 1))}")
fi
printf '%s' "${args[0]:-}" >> "$FM_TEST_HERDR_LOG"
for arg in "${args[@]:1}"; do printf '\037%s' "$arg" >> "$FM_TEST_HERDR_LOG"; done
printf '\n' >> "$FM_TEST_HERDR_LOG"
command="${args[0]:-} ${args[1]:-} ${args[2]:-} ${args[3]:-}"
command=${command% }
if [ "${FM_TEST_HERDR_BLOCK_ON:-}" = "$command" ]; then
  sleep 10
fi
case "${args[0]:-} ${args[1]:-}" in
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${args[2]}"
    ;;
  'tab list')
    [ "${FM_TEST_HERDR_LIST_FAIL:-0}" != 1 ] || exit 1
    if [ -f "$FM_TEST_HERDR_STATE/observer" ]; then
      # shellcheck disable=SC1090
      . "$FM_TEST_HERDR_STATE/observer"
      printf '{"result":{"tabs":[{"tab_id":"%s","workspace_id":"ws-1","label":"%s"}]}}\n' "$tab" "$label"
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    ;;
  'tab create')
    label=
    i=2
    while [ "$i" -lt "${#args[@]}" ]; do
      case "${args[$i]}" in --label) i=$((i + 1)); label=${args[$i]} ;; esac
      i=$((i + 1))
    done
    printf 'tab=tab-observer\npane=w1:p-observer\nlabel=%s\n' "$label" > "$FM_TEST_HERDR_STATE/observer"
    if [ "${FM_TEST_HERDR_BLOCK_AFTER_CREATE:-0}" = 1 ]; then
      sleep 10
    fi
    printf '{"result":{"tab":{"tab_id":"tab-observer"},"root_pane":{"pane_id":"w1:p-observer"}}}\n'
    ;;
  'pane list')
    if [ -f "$FM_TEST_HERDR_STATE/observer" ]; then
      printf '{"result":{"panes":[{"pane_id":"w1:p-observer","tab_id":"tab-observer"}]}}\n'
    else
      printf '{"result":{"panes":[]}}\n'
    fi
    ;;
  'pane send-text'|'pane send-keys') exit 0 ;;
  'tab close') rm -f "$FM_TEST_HERDR_STATE/observer" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/fm-send" "$FAKEBIN/tmux" "$FAKEBIN/herdr"

write_nm() {  # <run> <branch> <status> [current]
  local run=$1 branch=$2 status=$3 current=${4:-yes}
  mkdir -p "$FM_TEST_NM_STATE"
  printf '%s|%s|%s\n' "$run" "$branch" "$status" > "$FM_TEST_NM_STATE/$run"
  [ "$current" = yes ] && cp "$FM_TEST_NM_STATE/$run" "$FM_TEST_NM_STATE/current"
}

make_home() {  # <name> <harness> <backend>
  local name=$1 harness=$2 backend=$3 home repo branch
  home="$TMP_ROOT/$name"
  repo="$TMP_ROOT/$name-repo"
  branch="fm/$name"
  fm_git_worktree "$TMP_ROOT/$name-base" "$repo" "$branch"
  mkdir -p "$home/state"
  extra=()
  case "$backend" in
    tmux) : ;;
    herdr) extra=("backend=herdr" "herdr_session=lab" "herdr_workspace_id=ws-1" "herdr_tab_id=tab-worker" "herdr_pane_id=w1:p-worker") ;;
    *) extra=("backend=$backend") ;;
  esac
  fm_write_meta "$home/state/task.meta" \
    "window=$(case "$backend" in herdr) printf 'lab:w1:p-worker' ;; *) printf 'crew:fm-task' ;; esac)" \
    "worktree=$repo" "project=$repo" "harness=$harness" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "${extra[@]+"${extra[@]}"}"
  printf '%s\t%s\t%s\n' "$home" "$repo" "$branch"
}

run_observer() {  # <home> <args...>
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$home" \
    FM_NM_OBSERVER_NO_MISTAKES="$FAKEBIN/no-mistakes" \
    FM_NM_OBSERVER_SEND_BIN="$FAKEBIN/fm-send" \
    FM_NM_OBSERVER_WAIT_SECS=1 \
    FM_NM_OBSERVER_POLL_SECS=0 \
    FM_NM_OBSERVER_SETTLE_SECS=0 \
    "$SCRIPT" "$@"
}

record_value() {  # <record> <key>
  grep "^$2=" "$1" | tail -1 | cut -d= -f2-
}

reset_fakes() {
  rm -rf "$FM_TEST_NM_STATE" "$FM_TEST_TMUX_STATE" "$FM_TEST_HERDR_STATE"
  mkdir -p "$FM_TEST_NM_STATE" "$FM_TEST_TMUX_STATE" "$FM_TEST_HERDR_STATE"
  : > "$FM_TEST_NM_LOG"
  : > "$FM_TEST_SEND_LOG"
  : > "$FM_TEST_TMUX_LOG"
  : > "$FM_TEST_HERDR_LOG"
}

# shellcheck disable=SC2016  # Codex receives a literal dollar-prefixed skill name.
test_harness_start_invocations_and_run_discovery() {
  local row harness expected vals home repo branch out
  for row in \
    'claude|/no-mistakes' \
    'codex|$no-mistakes' \
    'grok|/no-mistakes' \
    'opencode|Run the no-mistakes skill now to validate and ship this committed branch.' \
    'pi|Run the no-mistakes skill now to validate and ship this committed branch.'; do
    reset_fakes
    IFS='|' read -r harness expected <<EOF
$row
EOF
    vals=$(make_home "harness-$harness" "$harness" zellij)
    IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
    write_nm old-run "$branch" completed
    printf 'new-run|%s|running\n' "$branch" > "$FM_TEST_NM_STATE/after-send"
    out=$(run_observer "$home" start task 2>&1)
    assert_grep $'task\t'"$expected" "$FM_TEST_SEND_LOG" "$harness validation invocation was wrong"
    assert_contains "$out" "backend zellij cannot host a no-focus observer safely" "$harness start did not preserve validation with manual fallback"
    assert_contains "$out" "no-mistakes attach --run 'new-run'" "$harness start did not discover the new authoritative run id"
    git -C "$TMP_ROOT/harness-$harness-base" worktree remove --force "$repo" >/dev/null
  done
  pass "observer start uses every verified harness invocation and discovers the new run id"
}

test_start_adopts_every_nonterminal_run() {
  local status vals home repo branch out
  for status in awaiting_approval fix_review queued; do
    reset_fakes
    vals=$(make_home "nonterminal-$status" claude zellij)
    IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
    write_nm "run-$status" "$branch" "$status"
    out=$(run_observer "$home" start task 2>&1)
    [ ! -s "$FM_TEST_SEND_LOG" ] || fail "start reinvoked validation for nonterminal status $status"
    assert_contains "$out" "no-mistakes attach --run 'run-$status'" "start did not adopt nonterminal status $status"
    git -C "$TMP_ROOT/nonterminal-$status-base" worktree remove --force "$repo" >/dev/null
  done
  pass "start adopts every authoritative nonterminal branch run"
}

test_tmux_one_observer_no_focus_and_worker_separation() {
  local vals home repo branch out record target
  reset_fakes
  vals=$(make_home tmux-idempotent claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-one "$branch" running
  out=$(run_observer "$home" open task --run run-one 2>&1)
  record="$home/state/task.observer"
  assert_present "$record" "tmux observer record was not written"
  target=$(record_value "$record" observer_target)
  [ "$target" = @2 ] || fail "tmux observer did not record the stable observer window id"
  assert_contains "$out" "(tmux, no focus)" "tmux observer did not report no-focus launch"
  assert_grep $'new-window\037-dP' "$FM_TEST_TMUX_LOG" "tmux observer was not created detached"
  assert_no_grep $'send-keys\037-t\037crew:fm-task' "$FM_TEST_TMUX_LOG" "observer launch typed into the worker"

  out=$(run_observer "$home" open task --run run-one 2>&1)
  [ "$(grep -c '^new-window' "$FM_TEST_TMUX_LOG")" -eq 1 ] || fail "idempotent open created more than one tmux observer"
  assert_contains "$out" "at @2" "idempotent open did not preserve its exact observer"
  assert_no_grep $'kill-window\037-t\037crew:fm-task' "$FM_TEST_TMUX_LOG" "observer lifecycle targeted the worker for cleanup"
  git -C "$TMP_ROOT/tmux-idempotent-base" worktree remove --force "$repo" >/dev/null
  pass "tmux observer is one detached window and remains separate from the worker"
}

test_detach_stays_detached_until_reopen() {
  local vals home repo branch record target out
  reset_fakes
  vals=$(make_home detach claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-detach "$branch" running
  run_observer "$home" open task --run run-detach >/dev/null
  record="$home/state/task.observer"
  target=$(record_value "$record" observer_target)
  sed 's/^status=ready$/status=attached/' "$record" > "$record.tmp"
  chmod 600 "$record.tmp"
  mv "$record.tmp" "$record"
  rm -f "$FM_TEST_TMUX_STATE/$target"

  out=$(run_observer "$home" open task --run run-detach 2>&1)
  [ "$(record_value "$record" status)" = detached ] || fail "gone observer was not marked detached"
  [ "$(grep -c '^new-window' "$FM_TEST_TMUX_LOG")" -eq 1 ] || fail "ordinary retry respawned a detached observer"
  assert_contains "$out" "remains detached" "ordinary retry did not explain detach persistence"

  run_observer "$home" reopen task --run run-detach >/dev/null
  [ "$(grep -c '^new-window' "$FM_TEST_TMUX_LOG")" -eq 2 ] || fail "explicit reopen did not create a replacement observer"
  git -C "$TMP_ROOT/detach-base" worktree remove --force "$repo" >/dev/null
  pass "q or terminal exit stays detached until explicit reopen"
}

test_internal_attach_exit_marks_detached() {
  local vals home repo branch record run token
  reset_fakes
  vals=$(make_home terminal-exit claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-exit "$branch" running
  run_observer "$home" open task --run run-exit >/dev/null
  record="$home/state/task.observer"
  run=$(record_value "$record" run)
  token=$(record_value "$record" token)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_NM_OBSERVER_NO_MISTAKES="$FAKEBIN/no-mistakes" "$SCRIPT" _session task "$run" "$token"
  [ "$(record_value "$record" status)" = detached ] || fail "observer terminal exit did not mark the record detached"
  assert_grep 'attach run-exit' "$FM_TEST_NM_LOG" "observer session did not execute the exact attach command"
  git -C "$TMP_ROOT/terminal-exit-base" worktree remove --force "$repo" >/dev/null
  pass "observer attach exit is recorded as detach without affecting validation"
}

test_unsupported_backends_fall_back_without_terminal_commands() {
  local backend vals home repo branch out
  for backend in zellij orca cmux; do
    reset_fakes
    vals=$(make_home "unsupported-$backend" claude "$backend")
    IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
    write_nm "run-$backend" "$branch" running
    out=$(run_observer "$home" open task --run "run-$backend" 2>&1)
    assert_contains "$out" "backend $backend cannot host a no-focus observer safely" "$backend did not surface safe fallback"
    assert_contains "$out" "no-mistakes attach --run 'run-$backend'" "$backend fallback omitted the exact manual attach command"
    [ ! -s "$FM_TEST_TMUX_LOG" ] || fail "$backend fallback issued tmux commands"
    [ ! -s "$FM_TEST_HERDR_LOG" ] || fail "$backend fallback issued Herdr commands"
    assert_absent "$home/state/task.observer" "$backend fallback wrote a misleading observer record"
    git -C "$TMP_ROOT/unsupported-$backend-base" worktree remove --force "$repo" >/dev/null
  done
  pass "unsupported experimental backends preserve validation and print exact manual attach"
}

test_task_run_mismatch_preserves_existing_observer() {
  local vals home repo branch out record target
  reset_fakes
  vals=$(make_home mismatch claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-old "$branch" running
  run_observer "$home" open task --run run-old >/dev/null
  record="$home/state/task.observer"
  target=$(record_value "$record" observer_target)
  write_nm run-new "$branch" running
  out=$(run_observer "$home" open task --run run-new 2>&1)
  assert_contains "$out" "task/run mismatch" "run mismatch was not surfaced"
  [ -f "$FM_TEST_TMUX_STATE/$target" ] || fail "run mismatch closed the existing observer"
  [ "$(grep -c '^new-window' "$FM_TEST_TMUX_LOG")" -eq 1 ] || fail "run mismatch created a duplicate observer"
  assert_no_grep $'kill-window\037-t\037@2' "$FM_TEST_TMUX_LOG" "run mismatch killed the prior running observer"
  git -C "$TMP_ROOT/mismatch-base" worktree remove --force "$repo" >/dev/null
  pass "task/run mismatch preserves a running observer and refuses to guess"
}

test_stale_and_malformed_records_are_safe() {
  local vals home repo branch record target out
  reset_fakes
  vals=$(make_home stale claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-stale "$branch" running
  run_observer "$home" open task --run run-stale >/dev/null
  record="$home/state/task.observer"
  target=$(record_value "$record" observer_target)
  sed 's/^status=ready$/status=attached/' "$record" > "$record.tmp"
  chmod 600 "$record.tmp"
  mv "$record.tmp" "$record"
  rm -f "$FM_TEST_TMUX_STATE/$target"
  run_observer "$home" open task --run run-stale >/dev/null 2>&1
  [ "$(record_value "$record" status)" = detached ] || fail "stale gone endpoint was not converged to detached"

  rm -f "$record"
  printf 'version=bogus\n' > "$record"
  chmod 600 "$record"
  out=$(run_observer "$home" open task --run run-stale 2>&1)
  assert_contains "$out" "unsafe or malformed observer record" "malformed record did not trigger safe fallback"
  [ "$(grep -c '^new-window' "$FM_TEST_TMUX_LOG")" -eq 1 ] || fail "malformed record launched another observer"
  git -C "$TMP_ROOT/stale-base" worktree remove --force "$repo" >/dev/null
  pass "stale records converge safely and malformed records never authorize a terminal action"
}

test_exact_cleanup_and_running_refusal() {
  local vals home repo branch record target out rc
  reset_fakes
  vals=$(make_home cleanup claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-clean "$branch" running
  run_observer "$home" open task --run run-clean >/dev/null
  record="$home/state/task.observer"
  target=$(record_value "$record" observer_target)

  set +e
  out=$(run_observer "$home" cleanup task 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup accepted a still-running validation"
  assert_contains "$out" "still running or unreadable" "running cleanup refusal was not explicit"
  [ -f "$FM_TEST_TMUX_STATE/$target" ] || fail "running cleanup closed the observer"
  assert_present "$record" "running cleanup removed the observer record"

  write_nm run-clean "$branch" completed
  run_observer "$home" cleanup task >/dev/null
  assert_absent "$record" "terminal cleanup did not remove the observer record"
  [ ! -f "$FM_TEST_TMUX_STATE/$target" ] || fail "terminal cleanup did not close the exact observer"
  assert_grep $'kill-window\037-t\037@2' "$FM_TEST_TMUX_LOG" "cleanup did not target the stable observer id"
  assert_no_grep $'kill-window\037-t\037crew:fm-task' "$FM_TEST_TMUX_LOG" "cleanup targeted the worker endpoint"
  git -C "$TMP_ROOT/cleanup-base" worktree remove --force "$repo" >/dev/null
  pass "cleanup refuses a running run and closes only the exact terminal observer"
}

test_cleanup_identity_mismatch_refuses() {
  local vals home repo branch record target out rc
  reset_fakes
  vals=$(make_home identity-mismatch claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-identity "$branch" running
  run_observer "$home" open task --run run-identity >/dev/null
  record="$home/state/task.observer"
  target=$(record_value "$record" observer_target)
  sed 's/^token=.*/token=ffffffffffffffffffffffffffffffff/' "$FM_TEST_TMUX_STATE/$target" > "$FM_TEST_TMUX_STATE/$target.tmp"
  mv "$FM_TEST_TMUX_STATE/$target.tmp" "$FM_TEST_TMUX_STATE/$target"
  write_nm run-identity "$branch" completed
  set +e
  out=$(run_observer "$home" cleanup task 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "identity-mismatched cleanup succeeded"
  assert_contains "$out" "identity mismatch" "identity-mismatched cleanup was not explicit"
  [ -f "$FM_TEST_TMUX_STATE/$target" ] || fail "identity-mismatched cleanup killed a terminal"
  assert_present "$record" "identity-mismatched cleanup removed its evidence"
  git -C "$TMP_ROOT/identity-mismatch-base" worktree remove --force "$repo" >/dev/null
  pass "identity mismatch preserves both terminal and observer evidence"
}

test_unreadable_identity_refuses_cleanup() {
  local vals home repo branch record target out rc

  reset_fakes
  vals=$(make_home unreadable-tmux claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-unreadable-tmux "$branch" running
  run_observer "$home" open task --run run-unreadable-tmux >/dev/null
  record="$home/state/task.observer"
  target=$(record_value "$record" observer_target)
  write_nm run-unreadable-tmux "$branch" completed
  set +e
  out=$(FM_TEST_TMUX_LIST_FAIL=1 run_observer "$home" cleanup task 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreadable tmux identity allowed cleanup"
  assert_contains "$out" "identity mismatch" "unreadable tmux identity did not explain safe refusal"
  assert_present "$record" "unreadable tmux identity removed observer evidence"
  assert_present "$FM_TEST_TMUX_STATE/$target" "unreadable tmux identity closed an unverified terminal"
  git -C "$TMP_ROOT/unreadable-tmux-base" worktree remove --force "$repo" >/dev/null

  reset_fakes
  vals=$(make_home unreadable-herdr claude herdr)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-unreadable-herdr "$branch" running
  run_observer "$home" open task --run run-unreadable-herdr >/dev/null
  record="$home/state/task.observer"
  write_nm run-unreadable-herdr "$branch" completed
  set +e
  out=$(FM_TEST_HERDR_LIST_FAIL=1 run_observer "$home" cleanup task 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreadable Herdr identity allowed cleanup"
  assert_contains "$out" "identity mismatch" "unreadable Herdr identity did not explain safe refusal"
  assert_present "$record" "unreadable Herdr identity removed observer evidence"
  assert_present "$FM_TEST_HERDR_STATE/observer" "unreadable Herdr identity closed an unverified terminal"
  git -C "$TMP_ROOT/unreadable-herdr-base" worktree remove --force "$repo" >/dev/null

  pass "unreadable endpoint identity preserves terminals and observer evidence"
}

test_interrupted_creates_reconcile_without_duplicates() {
  local vals home repo branch out record

  reset_fakes
  vals=$(make_home interrupted-tmux claude tmux)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-interrupted-tmux "$branch" running
  out=$(FM_TEST_TMUX_BLOCK_AFTER_CREATE=1 FM_NM_OBSERVER_COMMAND_TIMEOUT=1 \
    run_observer "$home" open task --run run-interrupted-tmux 2>&1)
  record="$home/state/task.observer"
  assert_contains "$out" "automatic observer launch failed without affecting validation" "interrupted tmux create was not isolated to observer failure"
  grep -q '^status=failed$' "$record" \
    || fail "interrupted tmux create did not leave a failure tombstone: $(cat "$record"); log: $(cat "$FM_TEST_TMUX_LOG")"
  [ "$(find "$FM_TEST_TMUX_STATE" -maxdepth 1 -name '@*' | wc -l | tr -d ' ')" -eq 1 ] || fail "interrupted tmux create lost its unique provisional window"
  run_observer "$home" open task --run run-interrupted-tmux >/dev/null 2>&1
  [ "$(grep -c '^new-window' "$FM_TEST_TMUX_LOG")" -eq 1 ] || fail "ordinary retry duplicated an interrupted tmux observer"
  write_nm run-interrupted-tmux "$branch" completed
  run_observer "$home" cleanup task >/dev/null
  [ "$(find "$FM_TEST_TMUX_STATE" -maxdepth 1 -name '@*' | wc -l | tr -d ' ')" -eq 0 ] || fail "tmux cleanup did not reconcile and close the provisional observer"
  assert_no_grep $'kill-window\037-t\037crew:fm-task' "$FM_TEST_TMUX_LOG" "tmux provisional cleanup targeted the worker"
  git -C "$TMP_ROOT/interrupted-tmux-base" worktree remove --force "$repo" >/dev/null

  reset_fakes
  vals=$(make_home interrupted-herdr claude herdr)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-interrupted-herdr "$branch" running
  out=$(FM_TEST_HERDR_BLOCK_AFTER_CREATE=1 FM_NM_OBSERVER_COMMAND_TIMEOUT=1 \
    run_observer "$home" open task --run run-interrupted-herdr 2>&1)
  record="$home/state/task.observer"
  assert_contains "$out" "automatic observer launch failed without affecting validation" "interrupted Herdr create was not isolated to observer failure"
  grep -q '^status=failed$' "$record" \
    || fail "interrupted Herdr create did not leave a failure tombstone: $(cat "$record"); log: $(cat "$FM_TEST_HERDR_LOG")"
  assert_present "$FM_TEST_HERDR_STATE/observer" "interrupted Herdr create lost its unique provisional tab"
  run_observer "$home" open task --run run-interrupted-herdr >/dev/null 2>&1
  [ "$(grep -c $'tab\037create' "$FM_TEST_HERDR_LOG")" -eq 1 ] || fail "ordinary retry duplicated an interrupted Herdr observer"
  write_nm run-interrupted-herdr "$branch" completed
  run_observer "$home" cleanup task >/dev/null
  assert_absent "$FM_TEST_HERDR_STATE/observer" "Herdr cleanup did not reconcile and close the provisional observer"
  assert_no_grep $'tab\037close\037tab-worker' "$FM_TEST_HERDR_LOG" "Herdr provisional cleanup targeted the worker"
  git -C "$TMP_ROOT/interrupted-herdr-base" worktree remove --force "$repo" >/dev/null

  pass "interrupted creates reconcile by token identity without duplicate observers"
}

test_herdr_timeout_falls_back_without_touching_worker() {
  local vals home repo branch out started elapsed
  reset_fakes
  vals=$(make_home herdr-timeout claude herdr)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-herdr-timeout "$branch" running

  started=$(date +%s)
  out=$(FM_TEST_HERDR_BLOCK_ON='pane send-keys w1:p-observer enter' \
    FM_NM_OBSERVER_COMMAND_TIMEOUT=1 run_observer "$home" open task --run run-herdr-timeout 2>&1)
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 5 ] || fail "blocked Herdr observer command exceeded its safe fallback bound"
  assert_contains "$out" "automatic observer launch failed without affecting validation" "Herdr timeout was not reported as observer-only"
  assert_contains "$out" "no-mistakes attach --run 'run-herdr-timeout'" "Herdr timeout omitted exact manual attach fallback"
  grep -q '^status=failed$' "$home/state/task.observer" \
    || fail "Herdr timeout did not preserve a non-respawning failure tombstone: $(cat "$home/state/task.observer"); log: $(cat "$FM_TEST_HERDR_LOG")"
  assert_no_grep $'pane\037send-text\037w1:p-worker' "$FM_TEST_HERDR_LOG" "Herdr timeout typed into the worker pane"
  assert_no_grep $'tab\037close\037tab-worker' "$FM_TEST_HERDR_LOG" "Herdr timeout closed the worker tab"
  git -C "$TMP_ROOT/herdr-timeout-base" worktree remove --force "$repo" >/dev/null
  pass "bounded Herdr observer failures preserve validation and exact manual attach fallback"
}

test_herdr_submit_phases_reconcile_without_duplicate_text() {
  local vals home repo branch record out
  reset_fakes
  vals=$(make_home herdr-submit-phases claude herdr)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-herdr-phases "$branch" running
  run_observer "$home" open task --run run-herdr-phases >/dev/null
  record="$home/state/task.observer"
  [ "$(record_value "$record" status)" = submitted ] || fail "successful Herdr submission was not durably distinguished from ready"
  : > "$FM_TEST_HERDR_LOG"
  out=$(run_observer "$home" open task --run run-herdr-phases 2>&1)
  assert_contains "$out" "awaiting attachment; refusing to resubmit it" "submitted retry did not preserve the pending observer"
  [ "$(record_value "$record" status)" = submitted ] || fail "submitted retry replaced the pending observer state"
  assert_no_grep $'pane\037send-text' "$FM_TEST_HERDR_LOG" "submitted retry typed the attach command twice"
  assert_no_grep $'pane\037send-keys' "$FM_TEST_HERDR_LOG" "submitted retry pressed Enter twice"

  sed 's/^status=submitted$/status=staged/' "$record" > "$record.tmp"
  chmod 600 "$record.tmp"
  mv "$record.tmp" "$record"
  : > "$FM_TEST_HERDR_LOG"
  run_observer "$home" open task --run run-herdr-phases >/dev/null
  assert_no_grep $'pane\037send-text' "$FM_TEST_HERDR_LOG" "staged retry typed the attach command twice"
  assert_grep $'pane\037send-keys\037w1:p-observer\037enter' "$FM_TEST_HERDR_LOG" "staged retry did not submit the existing command"

  sed 's/^status=submitted$/status=staging/' "$record" > "$record.tmp"
  chmod 600 "$record.tmp"
  mv "$record.tmp" "$record"
  : > "$FM_TEST_HERDR_LOG"
  out=$(run_observer "$home" open task --run run-herdr-phases 2>&1)
  assert_contains "$out" "automatic observer launch failed without affecting validation" "unknown send-text outcome did not fail safely"
  assert_no_grep $'pane\037send-text' "$FM_TEST_HERDR_LOG" "unknown send-text outcome repeated the attach command"
  assert_no_grep $'pane\037send-keys' "$FM_TEST_HERDR_LOG" "unknown send-text outcome submitted unknown input"
  git -C "$TMP_ROOT/herdr-submit-phases-base" worktree remove --force "$repo" >/dev/null
  pass "Herdr submit phases resume only a known staged command"
}

test_herdr_no_focus_separation_and_exact_cleanup() {
  local vals home repo branch record out
  reset_fakes
  vals=$(make_home herdr claude herdr)
  IFS=$'\t' read -r home repo branch <<EOF
$vals
EOF
  write_nm run-herdr "$branch" running
  out=$(run_observer "$home" open task --run run-herdr 2>&1)
  record="$home/state/task.observer"
  assert_contains "$out" "(herdr, no focus)" "Herdr observer did not report no-focus launch"
  assert_grep $'tab\037create\037--workspace\037ws-1' "$FM_TEST_HERDR_LOG" "Herdr observer was not created in the worker workspace"
  assert_grep $'--no-focus' "$FM_TEST_HERDR_LOG" "Herdr observer omitted --no-focus"
  assert_grep $'pane\037send-text\037w1:p-observer' "$FM_TEST_HERDR_LOG" "Herdr observer attach command was not typed into the observer pane"
  assert_grep $'pane\037send-keys\037w1:p-observer\037enter' "$FM_TEST_HERDR_LOG" "Herdr observer attach command was not started in the observer pane"
  assert_no_grep $'pane\037send-text\037w1:p-worker' "$FM_TEST_HERDR_LOG" "Herdr observer launch replaced the worker pane"
  [ "$(record_value "$record" worker_target)" = 'lab:w1:p-worker' ] || fail "Herdr record lost worker identity"
  [ "$(record_value "$record" observer_target)" = 'lab:w1:p-observer' ] || fail "Herdr record did not distinguish observer identity"

  write_nm run-herdr "$branch" completed
  if ! out=$(run_observer "$home" cleanup task 2>&1); then
    fail "Herdr observer cleanup failed: $out; log: $(cat "$FM_TEST_HERDR_LOG")"
  fi
  assert_grep $'tab\037close\037tab-observer' "$FM_TEST_HERDR_LOG" "Herdr cleanup did not close the exact observer tab"
  assert_no_grep $'pane\037close\037w1:p-worker' "$FM_TEST_HERDR_LOG" "Herdr cleanup targeted the worker pane"
  git -C "$TMP_ROOT/herdr-base" worktree remove --force "$repo" >/dev/null
  pass "Herdr observer uses no-focus sibling tab and exact tab cleanup"
}

# shellcheck disable=SC2016  # Backticks are literal contract text, not command substitution.
test_header_and_contract_keep_observer_non_owner() {
  local help contract
  help=$($SCRIPT --help)
  contract=$(awk '/^### Validate$/ { found=1; next } found && /^### / { exit } found { print }' "$ROOT/AGENTS.md")
  assert_contains "$help" 'never invoke axi respond/abort' "observer header lost its non-owner boundary"
  assert_contains "$help" 'no-mistakes attach --run <run-id>' "observer header lost the exact attach command"
  assert_contains "$contract" 'bin/fm-no-mistakes-observer.sh start <id>' "Validate contract does not trigger the lifecycle owner"
  assert_contains "$contract" 'The task worker that starts a no-mistakes run drives the pipeline' "worker ownership changed"
  assert_contains "$contract" 'Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.' "Firstmate response prohibition changed"
  pass "observer visibility remains separate from worker pipeline ownership"
}

test_harness_start_invocations_and_run_discovery
test_start_adopts_every_nonterminal_run
test_tmux_one_observer_no_focus_and_worker_separation
test_detach_stays_detached_until_reopen
test_internal_attach_exit_marks_detached
test_unsupported_backends_fall_back_without_terminal_commands
test_task_run_mismatch_preserves_existing_observer
test_stale_and_malformed_records_are_safe
test_exact_cleanup_and_running_refusal
test_cleanup_identity_mismatch_refuses
test_unreadable_identity_refuses_cleanup
test_interrupted_creates_reconcile_without_duplicates
test_herdr_timeout_falls_back_without_touching_worker
test_herdr_submit_phases_reconcile_without_duplicate_text
test_herdr_no_focus_separation_and_exact_cleanup
test_header_and_contract_keep_observer_non_owner
