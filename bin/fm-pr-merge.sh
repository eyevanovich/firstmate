#!/usr/bin/env bash
# Merge a task's pull or merge request after recording pr= and any available
# pr_head= through bin/fm-pr-check.sh, so teardown can verify landed work after
# squash merges. GitHub delegates to gh-axi. GitLab delegates to the narrow
# forge adapter, which verifies pipeline readiness and pins the reviewed head.
#
# Merge method defaults to squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# GitLab accepts only merge-method and source-branch deletion flags.
# Usage: fm-pr-merge.sh <task-id> <pr-or-mr-url> [-- <merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
FORGE=$FM_PR_FORGE
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if [ "$FORGE" = github ]; then
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
  exit $?
fi

[ -n "$WT" ] && [ -d "$WT" ] \
  || { echo "error: task worktree is unavailable" >&2; exit 1; }
method=
delete_branch=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) method=squash; shift ;;
    --merge) method=merge; shift ;;
    --rebase) method=rebase; shift ;;
    --method)
      [ "$#" -ge 2 ] || { echo "error: --method requires a value" >&2; exit 2; }
      method=$2
      shift 2
      ;;
    --method=*) method=${1#--method=}; shift ;;
    --delete-branch|--remove-source-branch) delete_branch=1; shift ;;
    *) echo "error: unsupported GitLab merge argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$method" ] || method=squash
case "$method" in merge|squash|rebase) ;; *) echo "error: invalid merge method" >&2; exit 2 ;; esac
gitlab_args=(--method "$method")
[ "$delete_branch" -eq 0 ] || gitlab_args+=(--delete-branch)
"$SCRIPT_DIR/fm-forge.sh" mr-merge "$WT" "$URL" "${gitlab_args[@]}"
