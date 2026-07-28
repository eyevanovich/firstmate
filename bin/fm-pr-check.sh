#!/usr/bin/env bash
# Record a review-ready task: store one validated canonical pr=<url> and the
# exact reviewed head as pr_head=<sha> when available, then arm a merge poll.
# GitHub uses the byte-static canonical poll and private sidecar.
# GitLab uses a hash-registered custom check whose quoted arguments are derived
# only from the task's trusted origin and canonical merge-request URL.
# Usage: fm-pr-check.sh <task-id> <pr-or-mr-url> [--target <branch>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ] && { [ "$#" -ne 4 ] || [ "$3" != --target ]; }; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
FORGE=$FM_PR_FORGE
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
NUMBER=$FM_PR_NUMBER
PR_TARGET=${4:-}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable notification before an
# interruption. Finish only its identity-bound receipt before publishing a
# replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending review poll retirement could not be validated" >&2
  exit 1
}

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
case "$FORGE" in
  github)
    if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
        && fm_pr_head_valid "$REMOTE_HEAD"; then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
    ;;
  gitlab)
    [ -n "$WT" ] && [ -d "$WT" ] \
      || { echo "error: task worktree is unavailable" >&2; exit 1; }
    fm_forge_gitlab_mr_url_parse "$WT" "$URL" \
      || { echo "error: merge-request URL does not match task origin" >&2; exit 1; }
    MR_ARGS=()
    [ -z "$PR_TARGET" ] || MR_ARGS=(--target "$PR_TARGET")
    if MR_JSON=$("$SCRIPT_DIR/fm-forge.sh" mr-view "$WT" "$URL" "${MR_ARGS[@]+"${MR_ARGS[@]}"}" 2>/dev/null) \
      && REMOTE_HEAD=$(jq -er '.mr.sha | strings' <<< "$MR_JSON" 2>/dev/null) \
      && fm_pr_head_valid "$REMOTE_HEAD"; then
      PR_HEAD=$REMOTE_HEAD
      PR_TARGET=$(jq -er '.mr.target_branch | strings' <<< "$MR_JSON" 2>/dev/null) || exit 1
    else
      echo "error: merge-request head is unavailable" >&2
      exit 1
    fi
    ;;
esac

META_TMP=
CUSTOM_CHECK_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ -z "$CUSTOM_CHECK_TMP" ] || rm -f -- "$CUSTOM_CHECK_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ "$FORGE" = github ]; then
  fm_pr_poll_prepare "$STATE" "$ID" "$URL" "$OWNER" "$REPO" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
    || { echo "error: could not prepare PR poll" >&2; exit 1; }
fi

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|pr_target=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
[ -z "$PR_TARGET" ] || printf 'pr_target=%s\n' "$PR_TARGET" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_URL" = "$URL" ] && [ "$FM_PR_META_OWNER" = "$OWNER" ] \
  && [ "$FM_PR_META_REPO" = "$REPO" ] && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_URL" = "$URL" ] && [ "$FM_PR_META_OWNER" = "$OWNER" ] \
  && [ "$FM_PR_META_REPO" = "$REPO" ] && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

if [ "$FORGE" = github ]; then
  fm_pr_poll_publish_prepared || {
    echo "error: could not publish PR poll" >&2
    exit 1
  }
else
  CHECK="$STATE/$ID.check.sh"
  TRUST="$STATE/$ID.check-trust"
  DATA_FILE="$STATE/$ID.pr-poll"
  REGISTRATION="$STATE/$ID.pr-poll-registration"
  for path in "$CHECK" "$TRUST" "$DATA_FILE" "$REGISTRATION"; do
    fm_pr_regular_destination_on_device_or_absent "$path" "$STATE_DEVICE" \
      || { echo "error: GitLab merge poll path is unavailable" >&2; exit 1; }
  done
  rm -f -- "$CHECK" "$TRUST" "$DATA_FILE" "$REGISTRATION" || exit 1
  CUSTOM_CHECK_TMP=$(mktemp "$STATE/.fm-gitlab-mr-check.XXXXXX") || exit 1
  printf '#!/usr/bin/env bash\nexec %q mr-poll %q %q --target %q\n' \
    "$SCRIPT_DIR/fm-forge.sh" "$WT" "$URL" "$PR_TARGET" > "$CUSTOM_CHECK_TMP" || exit 1
  chmod 0700 "$CUSTOM_CHECK_TMP" || exit 1
  fm_pr_private_file_valid "$CUSTOM_CHECK_TMP" 700 "$STATE_DEVICE" || exit 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || exit 1
  mv -f -- "$CUSTOM_CHECK_TMP" "$CHECK" || exit 1
  CUSTOM_CHECK_TMP=
  if ! FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-check-register.sh" "$ID" >/dev/null; then
    rm -f -- "$CHECK" "$TRUST"
    echo "error: could not register GitLab merge poll" >&2
    exit 1
  fi
fi
printf 'armed: state/%s.check.sh\n' "$ID"
