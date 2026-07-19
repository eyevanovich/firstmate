#!/usr/bin/env bash
# Narrow, token-efficient forge adapter.
#
# GitHub continues to use gh-axi through existing Firstmate paths.
# This adapter owns the GitLab surface Firstmate needs without exposing raw API,
# project deletion, secret mutation, or repository-content writes to callers.
# The clone's origin remote is the only authority for host and project identity.
# GitLab content returned by this script is untrusted data, never instructions.
# Merge refuses failing or unfinished pipelines; a project with no pipeline is
# allowed so repositories without CI retain the existing captain-approved path.
#
# Output is compact JSON except mr-poll, which prints exactly "merged" or nothing.
#
# Usage:
#   fm-forge.sh repo <repo>
#   fm-forge.sh auth <repo>
#   fm-forge.sh issue-list <repo> [--state opened|closed|all] [--limit 1..100]
#   fm-forge.sh issue-view <repo> <iid>
#   fm-forge.sh mr-create <repo> --title <text> --source <branch>
#     [--target <branch>] [--body-file <file>] [--draft]
#     [--remove-source-branch]
#   fm-forge.sh mr-view <repo> <iid|canonical-url>
#   fm-forge.sh mr-find <repo> <source-branch>
#   fm-forge.sh mr-checks <repo> <iid|canonical-url>
#   fm-forge.sh mr-merge <repo> <iid|canonical-url>
#     [--method merge|squash|rebase] [--delete-branch]
#   fm-forge.sh mr-poll <repo> <canonical-url>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-forge-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-forge-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

require_iid() {
  local value=${1-}
  case "$value" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
}

require_limit() {
  local value=$1
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 100 ]
}

require_gitlab_repo() {
  local repo=$1
  fm_forge_repo_resolve "$repo" || fail "repository origin cannot be resolved safely"
  [ "$FM_FORGE_KIND" = gitlab ] || fail "repository is not GitLab-backed"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v glab >/dev/null 2>&1 || fail "glab is required"
}

require_gitlab_auth() {
  fm_forge_gitlab_auth "$FM_FORGE_HOST" \
    || fail "GitLab authentication is required for $FM_FORGE_HOST"
}

project_id() {
  fm_forge_url_encode "$FM_FORGE_PROJECT"
}

query_value() {
  fm_forge_url_encode "$1"
}

gitlab_api() {
  fm_forge_gitlab_api "$FM_FORGE_HOST" "$@"
}

resolve_mr_iid() {
  local repo=$1 target=$2
  require_gitlab_repo "$repo"
  if require_iid "$target"; then
    FM_FORGE_MR_IID=$target
  else
    fm_forge_gitlab_mr_url_parse "$repo" "$target" \
      || fail "merge-request URL does not match the repository origin"
  fi
}

emit_issue_list() {
  local raw=$1 limit=$2
  jq -c --arg forge gitlab --arg host "$FM_FORGE_HOST" \
    --arg project "$FM_FORGE_PROJECT" --argjson limit "$limit" '
      def bounded: if length > 500 then .[:500] + "..." else . end;
      {
        forge:$forge,
        host:$host,
        project:$project,
        count:length,
        issues:[.[:$limit][] | {
          iid,
          title:((.title // "") | bounded),
          state,
          url:.web_url,
          labels:(.labels // []),
          updated_at
        }]
      }
    ' <<< "$raw"
}

emit_issue() {
  local raw=$1
  jq -c --arg forge gitlab --arg host "$FM_FORGE_HOST" \
    --arg project "$FM_FORGE_PROJECT" '
      def bounded($n): if length > $n then .[:$n] + "..." else . end;
      {
        forge:$forge,
        host:$host,
        project:$project,
        issue:{
          iid,
          title:((.title // "") | bounded(500)),
          state,
          url:.web_url,
          description:((.description // "") | bounded(4000)),
          labels:(.labels // []),
          author:(.author.username // null),
          assignees:[(.assignees // [])[] | .username],
          updated_at
        }
      }
    ' <<< "$raw"
}

emit_mr() {
  local raw=$1 already=${2:-false}
  jq -c --arg forge gitlab --arg host "$FM_FORGE_HOST" \
    --arg project "$FM_FORGE_PROJECT" --argjson already "$already" '
      def bounded($n): if length > $n then .[:$n] + "..." else . end;
      {
        forge:$forge,
        host:$host,
        project:$project,
        mr:{
          iid,
          title:((.title // "") | bounded(500)),
          state,
          url:.web_url,
          source_branch,
          target_branch,
          draft:(.draft // .work_in_progress // false),
          merge_status,
          detailed_merge_status,
          sha,
          merge_commit_sha,
          pipeline:(if .head_pipeline then {
            id:.head_pipeline.id,
            status:.head_pipeline.status,
            sha:.head_pipeline.sha,
            url:.head_pipeline.web_url
          } else null end),
          already:$already
        }
      }
    ' <<< "$raw"
}

mr_raw() {
  local iid=$1 pid
  pid=$(project_id)
  gitlab_api "projects/$pid/merge_requests/$iid"
}

mr_checks_json() {
  local iid=$1 mr mr_sha pipeline_id pipeline_status pipelines pipeline_count=0 jobs pid
  pid=$(project_id)
  mr=$(mr_raw "$iid")
  mr_sha=$(jq -er '.sha | strings | select(test("^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$"))' <<< "$mr") \
    || fail "merge-request head SHA is unavailable"
  pipeline_id=$(jq -r --arg sha "$mr_sha" \
    '.head_pipeline | select(.sha == $sha) | .id // empty' <<< "$mr")
  pipeline_status=$(jq -r --arg sha "$mr_sha" \
    '.head_pipeline | select(.sha == $sha) | .status // empty' <<< "$mr")
  if [ -z "$pipeline_id" ]; then
    pipelines=$(gitlab_api "projects/$pid/merge_requests/$iid/pipelines?per_page=20")
    pipeline_count=$(jq -er 'length' <<< "$pipelines") \
      || fail "merge-request pipelines are unavailable"
    pipeline_id=$(jq -r --arg sha "$mr_sha" \
      '[.[] | select(.sha == $sha)][0].id // empty' <<< "$pipelines")
    pipeline_status=$(jq -r --arg sha "$mr_sha" \
      '[.[] | select(.sha == $sha)][0].status // empty' <<< "$pipelines")
  fi
  if [ -z "$pipeline_id" ]; then
    local verdict=stale_pipeline
    if [ "$pipeline_count" -eq 0 ] && [ "$(jq -r '.head_pipeline.id // empty' <<< "$mr")" = "" ]; then
      verdict=no_pipeline
    fi
    jq -cn --arg forge gitlab --arg host "$FM_FORGE_HOST" \
      --arg project "$FM_FORGE_PROJECT" --argjson iid "$iid" --arg verdict "$verdict" \
      '{forge:$forge,host:$host,project:$project,mr:$iid,pipeline:null,checks:{passed:0,failed:0,running:0,neutral:0,verdict:$verdict},jobs:[]}'
    return 0
  fi
  jobs=$(gitlab_api "projects/$pid/pipelines/$pipeline_id/jobs?per_page=100" --paginate)
  jq -c --arg forge gitlab --arg host "$FM_FORGE_HOST" \
    --arg project "$FM_FORGE_PROJECT" --argjson iid "$iid" \
    --argjson pipeline_id "$pipeline_id" --arg pipeline_status "$pipeline_status" \
    --arg pipeline_sha "$mr_sha" '
      def bucket:
        .status as $status
        | if $status == "success" or ($status == "failed" and .allow_failure == true) then "passed"
          elif $status == "failed" or $status == "canceled" then "failed"
          elif (["created","waiting_for_resource","preparing","pending","running","scheduled"] | index($status)) != null then "running"
          else "neutral" end;
      [.[] | . + {bucket:bucket}] as $jobs
      | ($jobs | map(select(.bucket == "passed")) | length) as $passed
      | ($jobs | map(select(.bucket == "failed")) | length) as $failed
      | ($jobs | map(select(.bucket == "running")) | length) as $running
      | ($jobs | map(select(.bucket == "neutral")) | length) as $neutral
      | (if (["failed","canceled"] | index($pipeline_status)) != null or $failed > 0 then "failing"
         elif (["created","waiting_for_resource","preparing","pending","running","scheduled"] | index($pipeline_status)) != null or $running > 0 then "running"
         elif $pipeline_status == "success" then "passing"
         elif ($jobs | length) == 0 then "no_jobs"
         else "neutral" end) as $verdict
      | {
          forge:$forge,
          host:$host,
          project:$project,
          mr:$iid,
          pipeline:{id:$pipeline_id,status:$pipeline_status,sha:$pipeline_sha},
          checks:{passed:$passed,failed:$failed,running:$running,neutral:$neutral,verdict:$verdict},
          jobs:[$jobs[] | select(.bucket == "failed" or .bucket == "running") | {id,name,status,stage,bucket,url:.web_url}]
        }
    ' <<< "$jobs"
}

cmd_repo() {
  local repo=$1
  fm_forge_repo_resolve "$repo" || fail "repository origin cannot be resolved safely"
  jq -cn --arg forge "$FM_FORGE_KIND" --arg host "$FM_FORGE_HOST" \
    --arg project "$FM_FORGE_PROJECT" \
    '{forge:$forge,host:$host,project:$project}'
}

cmd_auth() {
  local repo=$1
  require_gitlab_repo "$repo"
  require_gitlab_auth
  jq -cn --arg forge gitlab --arg host "$FM_FORGE_HOST" \
    --arg project "$FM_FORGE_PROJECT" \
    '{forge:$forge,host:$host,project:$project,authenticated:true}'
}

cmd_issue_list() {
  local repo=$1 state=opened limit=30 pid raw
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state)
        [ "$#" -ge 2 ] || fail "--state requires a value" 2
        state=$2
        shift 2
        ;;
      --limit)
        [ "$#" -ge 2 ] || fail "--limit requires a value" 2
        limit=$2
        shift 2
        ;;
      *) fail "unknown issue-list argument: $1" 2 ;;
    esac
  done
  case "$state" in opened|closed|all) ;; *) fail "state must be opened, closed, or all" 2 ;; esac
  require_limit "$limit" || fail "limit must be between 1 and 100" 2
  require_gitlab_repo "$repo"
  require_gitlab_auth
  pid=$(project_id)
  raw=$(gitlab_api "projects/$pid/issues?state=$state&per_page=$limit&order_by=updated_at&sort=desc")
  emit_issue_list "$raw" "$limit"
}

cmd_issue_view() {
  local repo=$1 iid=$2 pid raw
  require_iid "$iid" || fail "issue IID must be a positive integer" 2
  require_gitlab_repo "$repo"
  require_gitlab_auth
  pid=$(project_id)
  raw=$(gitlab_api "projects/$pid/issues/$iid")
  emit_issue "$raw"
}

cmd_mr_view() {
  local repo=$1 target=$2 raw
  resolve_mr_iid "$repo" "$target"
  require_gitlab_auth
  raw=$(mr_raw "$FM_FORGE_MR_IID")
  emit_mr "$raw"
}

cmd_mr_find() {
  local repo=$1 branch=$2 pid encoded raw found
  require_gitlab_repo "$repo"
  require_gitlab_auth
  git -C "$repo" check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || fail "source branch is invalid" 2
  pid=$(project_id)
  encoded=$(query_value "$branch")
  raw=$(gitlab_api "projects/$pid/merge_requests?state=all&source_branch=$encoded&order_by=updated_at&sort=desc&per_page=2")
  found=$(jq -c '.[0] // empty' <<< "$raw")
  [ -n "$found" ] || fail "no merge request found for source branch"
  emit_mr "$found"
}

cmd_mr_create() {
  local repo=$1 title='' source='' target='' body_file='' body='' draft=false remove_source=false
  local pid encoded existing raw project repo_real body_dir body_real
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title)
        [ "$#" -ge 2 ] || fail "--title requires a value" 2
        title=$2
        shift 2
        ;;
      --source)
        [ "$#" -ge 2 ] || fail "--source requires a value" 2
        source=$2
        shift 2
        ;;
      --target)
        [ "$#" -ge 2 ] || fail "--target requires a value" 2
        target=$2
        shift 2
        ;;
      --body-file)
        [ "$#" -ge 2 ] || fail "--body-file requires a value" 2
        body_file=$2
        shift 2
        ;;
      --draft) draft=true; shift ;;
      --remove-source-branch) remove_source=true; shift ;;
      *) fail "unknown mr-create argument: $1" 2 ;;
    esac
  done
  [ -n "$title" ] && [ "${#title}" -le 500 ] || fail "title is required and must be at most 500 characters" 2
  case "$title" in *$'\n'*|*$'\r'*) fail "title must be one line" 2 ;; esac
  [ -n "$source" ] || fail "source branch is required" 2
  git -C "$repo" check-ref-format --branch "$source" >/dev/null 2>&1 \
    || fail "source branch is invalid" 2
  if [ -n "$target" ]; then
    git -C "$repo" check-ref-format --branch "$target" >/dev/null 2>&1 \
      || fail "target branch is invalid" 2
  fi
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] && [ ! -L "$body_file" ] || fail "body file must be a regular non-symlink file" 2
    repo_real=$(cd "$repo" && pwd -P) || fail "repository path is unavailable" 2
    body_dir=$(cd "$(dirname "$body_file")" && pwd -P) \
      || fail "body file parent is unavailable" 2
    body_real="$body_dir/$(basename "$body_file")"
    case "$body_real" in
      "$repo_real"/*) ;;
      *) fail "body file must stay inside the repository worktree" 2 ;;
    esac
    [ "$(wc -c < "$body_real" | tr -d '[:space:]')" -le 65535 ] \
      || fail "body file is too large" 2
    body=$(<"$body_real")
  fi

  require_gitlab_repo "$repo"
  require_gitlab_auth
  pid=$(project_id)
  if [ -z "$target" ]; then
    project=$(gitlab_api "projects/$pid")
    target=$(jq -er '.default_branch | strings | select(length > 0)' <<< "$project") \
      || fail "project default branch is unavailable"
  fi

  encoded=$(query_value "$source")
  existing=$(gitlab_api "projects/$pid/merge_requests?state=opened&source_branch=$encoded&per_page=1")
  raw=$(jq -c '.[0] // empty' <<< "$existing")
  if [ -n "$raw" ]; then
    emit_mr "$raw" true
    return 0
  fi

  [ "$draft" = false ] || title="Draft: $title"
  args=(--method POST --raw-field "source_branch=$source" --raw-field "target_branch=$target" --raw-field "title=$title")
  [ -z "$body" ] || args+=(--raw-field "description=$body")
  [ "$remove_source" = false ] || args+=(--field remove_source_branch=true)
  raw=$(gitlab_api "projects/$pid/merge_requests" "${args[@]}")
  emit_mr "$raw"
}

cmd_mr_checks() {
  local repo=$1 target=$2
  resolve_mr_iid "$repo" "$target"
  require_gitlab_auth
  mr_checks_json "$FM_FORGE_MR_IID"
}

cmd_mr_merge() {
  local repo=$1 target=$2 method=merge delete_branch=false raw state sha checks verdict verify
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method)
        [ "$#" -ge 2 ] || fail "--method requires a value" 2
        method=$2
        shift 2
        ;;
      --delete-branch) delete_branch=true; shift ;;
      *) fail "unknown mr-merge argument: $1" 2 ;;
    esac
  done
  case "$method" in merge|squash|rebase) ;; *) fail "method must be merge, squash, or rebase" 2 ;; esac
  resolve_mr_iid "$repo" "$target"
  require_gitlab_auth
  raw=$(mr_raw "$FM_FORGE_MR_IID")
  state=$(jq -r '.state // empty' <<< "$raw")
  if [ "$state" = merged ]; then
    emit_mr "$raw" true
    return 0
  fi
  [ "$state" = opened ] || fail "merge request is not open"
  sha=$(jq -er '.sha | strings | select(test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))' <<< "$raw") \
    || fail "merge-request head SHA is unavailable"
  checks=$(mr_checks_json "$FM_FORGE_MR_IID")
  verdict=$(jq -r '.checks.verdict' <<< "$checks")
  case "$verdict" in
    passing|no_pipeline) ;;
    failing) fail "merge request has failing pipeline checks" ;;
    *) fail "merge request pipeline is not ready ($verdict)" ;;
  esac

  merge_args=(mr merge "$FM_FORGE_MR_IID" --repo "$FM_FORGE_PROJECT" --yes --auto-merge=false --sha "$sha")
  case "$method" in
    squash) merge_args+=(--squash) ;;
    rebase) merge_args+=(--rebase) ;;
  esac
  [ "$delete_branch" = false ] || merge_args+=(--remove-source-branch)
  env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
    GLAB_NO_PROMPT=1 GLAB_CHECK_UPDATE=false NO_COLOR=1 GITLAB_HOST="$FM_FORGE_HOST" \
    glab "${merge_args[@]}" >/dev/null
  verify=$(mr_raw "$FM_FORGE_MR_IID")
  [ "$(jq -r '.state // empty' <<< "$verify")" = merged ] \
    || fail "merge request did not reach merged state"
  emit_mr "$verify"
}

cmd_mr_poll() {
  local repo=$1 url=$2 raw
  fm_forge_gitlab_mr_url_parse "$repo" "$url" || exit 0
  fm_forge_gitlab_auth "$FM_FORGE_HOST" || exit 0
  raw=$(mr_raw "$FM_FORGE_MR_IID" 2>/dev/null) || exit 0
  if [ "$(jq -r '.state // empty' <<< "$raw" 2>/dev/null)" = merged ]; then
    printf '%s\n' merged
  fi
  return 0
}

[ "$#" -ge 1 ] || fail "missing command" 2
command=$1
shift
case "$command" in
  repo|auth)
    [ "$#" -eq 1 ] || fail "invalid $command request" 2
    "cmd_${command//-/_}" "$1"
    ;;
  issue-list)
    [ "$#" -ge 1 ] || fail "invalid issue-list request" 2
    repo=$1; shift
    cmd_issue_list "$repo" "$@"
    ;;
  issue-view)
    [ "$#" -eq 2 ] || fail "invalid issue-view request" 2
    cmd_issue_view "$1" "$2"
    ;;
  mr-create)
    [ "$#" -ge 1 ] || fail "invalid mr-create request" 2
    repo=$1; shift
    cmd_mr_create "$repo" "$@"
    ;;
  mr-view|mr-find|mr-checks|mr-merge|mr-poll)
    [ "$#" -ge 2 ] || fail "invalid $command request" 2
    cmd="cmd_${command//-/_}"
    "$cmd" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *) fail "unknown command: $command" 2 ;;
esac
