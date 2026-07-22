#!/usr/bin/env bash
# Live tmux smoke test for the no-mistakes observer on an isolated socket.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-no-mistakes-observer.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-observer-tmux)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_TMUX=$(command -v tmux) || fail "tmux is required"
SOCKET="fm-nm-observer-$$"
HOME_DIR="$TMP_ROOT/home"
REPO="$TMP_ROOT/repo-wt"
STATUS_FILE="$TMP_ROOT/nm-status"
ATTACH_LOG="$TMP_ROOT/attach.log"
mkdir -p "$HOME_DIR/state"

cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
EOF
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ]; then
  IFS='|' read -r id branch status < "$STATUS_FILE"
  cat <<OUT
run:
  id: \$id
  branch: \$branch
  status: \$status
OUT
  exit 0
fi
if [ "\${1:-}" = attach ] && [ "\${2:-}" = --run ]; then
  printf 'attach %s\n' "\$3" >> "$ATTACH_LOG"
  IFS= read -r -n 1 _ || true
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

cleanup() {
  PATH="$FAKEBIN:$PATH" tmux kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

fm_git_worktree "$TMP_ROOT/repo" "$REPO" fm/tmux-live
printf 'run-live|fm/tmux-live|running\n' > "$STATUS_FILE"
PATH="$FAKEBIN:$PATH" tmux new-session -d -s crew -n fm-task -c "$REPO" 'sleep 300'
fm_write_meta "$HOME_DIR/state/task.meta" \
  'window=crew:fm-task' "worktree=$REPO" "project=$REPO" \
  'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off'

run_observer() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_NM_OBSERVER_NO_MISTAKES="$FAKEBIN/no-mistakes" \
    FM_NM_OBSERVER_SETTLE_SECS=0 \
    "$SCRIPT" "$@"
}

record_value() {
  grep "^$2=" "$1" | tail -1 | cut -d= -f2-
}

tmux_window_exists() {  # <stable-window-id>
  PATH="$FAKEBIN:$PATH" tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF "$1"
}

wait_for_record_status() {  # <status>
  local want=$1 got
  for _ in $(seq 1 50); do
    got=$(record_value "$HOME_DIR/state/task.observer" status 2>/dev/null || true)
    [ "$got" = "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

run_observer open task --run run-live >/dev/null
wait_for_record_status attached || fail "live tmux observer never reached attached"
record="$HOME_DIR/state/task.observer"
observer=$(record_value "$record" observer_target)
worker_active=$(PATH="$FAKEBIN:$PATH" tmux display-message -p -t 'crew:fm-task' '#{window_active}')
observer_active=$(PATH="$FAKEBIN:$PATH" tmux display-message -p -t "$observer" '#{window_active}')
[ "$worker_active" = 1 ] || fail "tmux observer stole focus from the worker window"
[ "$observer_active" = 0 ] || fail "tmux observer window became active"
PATH="$FAKEBIN:$PATH" tmux display-message -p -t 'crew:fm-task' '#{pane_id}' >/dev/null \
  || fail "tmux observer replaced the worker window"
[ "$(PATH="$FAKEBIN:$PATH" tmux list-windows -t crew -F '#{window_id}' | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "tmux observer did not create exactly one sibling window"

PATH="$FAKEBIN:$PATH" tmux send-keys -t "$observer" q
wait_for_record_status detached || fail "q did not leave the observer detached"
for _ in $(seq 1 50); do
  tmux_window_exists "$observer" || break
  sleep 0.1
done
if tmux_window_exists "$observer"; then
  inventory=$(PATH="$FAKEBIN:$PATH" tmux list-windows -t crew -F '#{window_id} #{window_name} #{pane_id} #{pane_dead}')
  fail "detached tmux observer window did not exit: $inventory"
fi
run_observer open task --run run-live >/dev/null 2>&1
[ "$(PATH="$FAKEBIN:$PATH" tmux list-windows -t crew -F '#{window_id}' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "ordinary retry respawned the detached tmux observer"

run_observer reopen task --run run-live >/dev/null
wait_for_record_status attached || fail "explicit reopen did not reattach the tmux observer"
observer=$(record_value "$record" observer_target)
printf 'run-live|fm/tmux-live|completed\n' > "$STATUS_FILE"
run_observer cleanup task >/dev/null
assert_absent "$record" "live tmux cleanup did not remove observer record"
tmux_window_exists "$observer" && fail "live tmux cleanup left the observer window open"
PATH="$FAKEBIN:$PATH" tmux display-message -p -t 'crew:fm-task' '#{pane_id}' >/dev/null \
  || fail "live tmux cleanup touched the worker window"
[ "$(grep -c '^attach run-live$' "$ATTACH_LOG")" -eq 2 ] || fail "tmux observer attach count did not match initial open plus explicit reopen"

pass "live tmux observer uses one no-focus sibling, q detaches, reopen is explicit, and cleanup is exact"
