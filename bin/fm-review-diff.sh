#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= for an open review, the compare side is the
# freshly fetched provider review head. A reachable recorded pr_head= is an
# offline fallback only, and the local branch is the final warned fallback.
# Review refs live under refs/fm-review/ so later base fetches cannot clobber the
# comparison tip through FETCH_HEAD.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

fetch_review_head() {
  local pr_url=$1 provider host project number origin review_ref private_ref resolved
  fm_pr_url_parse "$pr_url" || return 2
  provider=$FM_PR_FORGE
  host=$FM_PR_HOST
  project=$FM_PR_PROJECT
  number=$FM_PR_NUMBER
  origin=$(git -C "$WT" config --get remote.origin.url 2>/dev/null) || return 1
  fm_forge_remote_parse "$origin" || return 2
  [ "$FM_FORGE_KIND" = "$provider" ] \
    && [ "$FM_FORGE_HOST" = "$host" ] \
    && [ "$FM_FORGE_PROJECT" = "$project" ] || return 2
  case "$provider" in
    github) review_ref="refs/pull/$number/head" ;;
    gitlab) review_ref="refs/merge-requests/$number/head" ;;
    *) return 2 ;;
  esac
  private_ref="refs/fm-review/$provider/$number/head"
  git -C "$WT" fetch --quiet origin "+$review_ref:$private_ref" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "$private_ref^{commit}" 2>/dev/null) || return 1
  fm_pr_head_valid "$resolved" || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 resolved fetch_status
  if resolved=$(fetch_review_head "$pr_url"); then
    printf '%s' "$resolved"
    return 0
  else
    fetch_status=$?
  fi
  [ "$fetch_status" -ne 2 ] || return 2
  if fm_pr_head_valid "$recorded_head" \
    && resolved=$(git -C "$WT" rev-parse --verify "$recorded_head^{commit}" 2>/dev/null) \
    && fm_pr_head_valid "$resolved"; then
    printf '%s' "$resolved"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if ! fm_pr_metadata_identity_parse "$META"; then
    echo "error: invalid review metadata for task $ID" >&2
    exit 1
  fi
  PR_URL=$FM_PR_META_URL
  PR_HEAD_RECORDED=$FM_PR_META_HEAD
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    resolve_status=$?
    if [ "$resolve_status" -eq 2 ]; then
      echo "error: review URL does not match the trusted origin for task $ID" >&2
      exit 1
    fi
    echo "warning: review head unavailable; diff may lag the open review (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
