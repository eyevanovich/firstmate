#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_test_enter_neutral_cwd() { # <session>
  local server_cwd
  server_cwd="$(fm_herdr_lab_state_dir)/$1.server-cwd"
  mkdir -p "$server_cwd" || return 1
  cd "$server_cwd" || return 1
  HERDR_TEST_NEUTRAL_CWD=$PWD
  export HERDR_STARTUP_CWD="$PWD"
}

herdr_safe_stop_and_delete() { # <session>
  local session=$1 neutral_cwd=${HERDR_TEST_NEUTRAL_CWD:-}
  fm_herdr_lab_teardown "$session" || return 1
  [ -n "$neutral_cwd" ] || return 0
  cd "$(fm_herdr_lab_state_dir)" || return 1
  rmdir "$neutral_cwd" || return 1
  unset HERDR_TEST_NEUTRAL_CWD
}
