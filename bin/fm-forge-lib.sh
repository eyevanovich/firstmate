#!/usr/bin/env bash
# Shared forge identity and authenticated GitLab transport.
#
# The registered clone's origin remote is the only trust root.
# User-supplied issue or merge-request content never selects a host or project.
# Call fm_forge_repo_resolve <repo> before reading FM_FORGE_* globals.
# GitLab API calls always pass the trusted host through glab's --hostname flag.
# Ambient token variables are removed so only glab's stored host credential can
# authenticate; changing a worktree remote cannot redirect an inherited token.
# shellcheck disable=SC2034 # Globals are consumed by scripts that source this library.

FM_FORGE_KIND=
FM_FORGE_HOST=
FM_FORGE_PROJECT=
FM_FORGE_REMOTE=
FM_FORGE_MR_IID=
FM_FORGE_MR_URL=
FM_FORGE_URL_HOST=
FM_FORGE_URL_PROJECT=

fm_forge_host_valid() {
  local host=${1-} name port
  [ -n "$host" ] || return 1
  case "$host" in
    *[!A-Za-z0-9.:-]*|*..*|.*|*.) return 1 ;;
  esac
  name=$host
  port=
  if [[ "$host" == *:* ]]; then
    name=${host%:*}
    port=${host##*:}
    [ "$name" != "$host" ] || return 1
    case "$port" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
  fi
  [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
}

fm_forge_project_valid() {
  local project=${1-} segment rest
  [ -n "$project" ] && [ "${#project}" -le 512 ] || return 1
  case "$project" in
    /*|*/|*//*|*'?'*|*'#'*) return 1 ;;
  esac
  rest=$project
  while :; do
    segment=${rest%%/*}
    [ -n "$segment" ] && [ "$segment" != . ] && [ "$segment" != .. ] || return 1
    [ "${#segment}" -le 255 ] || return 1
    [[ "$segment" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    [ "$rest" = "$segment" ] && break
    rest=${rest#*/}
  done
}

fm_forge_remote_parse() {
  local raw=${1-} rest authority host project host_name
  FM_FORGE_KIND=
  FM_FORGE_HOST=
  FM_FORGE_PROJECT=
  FM_FORGE_REMOTE=
  [ -n "$raw" ] || return 1

  case "$raw" in
    https://*|ssh://*|git+ssh://*)
      rest=${raw#*://}
      [ "$rest" != "$raw" ] || return 1
      authority=${rest%%/*}
      [ "$authority" != "$rest" ] || return 1
      host=${authority##*@}
      project=${rest#*/}
      ;;
    *@*:*)
      authority=${raw%%:*}
      host=${authority##*@}
      project=${raw#*:}
      ;;
    *) return 1 ;;
  esac

  project=${project%/}
  project=${project%.git}
  fm_forge_host_valid "$host" || return 1
  fm_forge_project_valid "$project" || return 1

  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  host_name=${host%%:*}
  FM_FORGE_REMOTE=$raw
  FM_FORGE_HOST=$host
  FM_FORGE_PROJECT=$project
  if [ "$host_name" = github.com ]; then
    FM_FORGE_KIND=github
  else
    FM_FORGE_KIND=gitlab
  fi
}

fm_forge_repo_resolve() {
  local repo=${1-} remote
  FM_FORGE_KIND=
  FM_FORGE_HOST=
  FM_FORGE_PROJECT=
  FM_FORGE_REMOTE=
  [ -d "$repo" ] || return 1
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
  remote=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  fm_forge_remote_parse "$remote"
}

fm_forge_url_encode() {
  command -v jq >/dev/null 2>&1 || return 1
  jq -rn --arg value "$1" '$value | @uri'
}

fm_forge_gitlab_auth() {
  local host=$1
  command -v glab >/dev/null 2>&1 || return 127
  env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
    GLAB_NO_PROMPT=1 GLAB_CHECK_UPDATE=false NO_COLOR=1 \
    glab auth status --hostname "$host" >/dev/null 2>&1
}

fm_forge_gitlab_api() {
  local host=$1 endpoint=$2
  shift 2
  command -v glab >/dev/null 2>&1 || return 127
  env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
    GLAB_NO_PROMPT=1 GLAB_CHECK_UPDATE=false NO_COLOR=1 \
    glab api "$endpoint" --hostname "$host" "$@"
}

fm_forge_gitlab_mr_url_parse_parts() {
  local raw=${1-} rest host path project iid marker='/-/merge_requests/'
  FM_FORGE_MR_IID=
  FM_FORGE_MR_URL=
  FM_FORGE_URL_HOST=
  FM_FORGE_URL_PROJECT=
  case "$raw" in
    https://*) ;;
    *) return 1 ;;
  esac
  rest=${raw#https://}
  host=${rest%%/*}
  [ "$host" != "$rest" ] || return 1
  path=${rest#*/}
  case "$path" in
    *"$marker"*) ;;
    *) return 1 ;;
  esac
  project=${path%%"$marker"*}
  iid=${path#*"$marker"}
  fm_forge_host_valid "$host" || return 1
  fm_forge_project_valid "$project" || return 1
  case "$iid" in
    ''|0|0[0-9]*|*[!0-9]*) return 1 ;;
  esac
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  FM_FORGE_MR_IID=$iid
  FM_FORGE_URL_HOST=$host
  FM_FORGE_URL_PROJECT=$project
  FM_FORGE_MR_URL="https://$host/$project/-/merge_requests/$iid"
  [ "$raw" = "$FM_FORGE_MR_URL" ]
}

fm_forge_gitlab_mr_url_parse() {
  local repo=$1 raw=${2-}
  fm_forge_repo_resolve "$repo" || return 1
  [ "$FM_FORGE_KIND" = gitlab ] || return 1
  fm_forge_gitlab_mr_url_parse_parts "$raw" || return 1
  [ "$FM_FORGE_URL_HOST" = "$FM_FORGE_HOST" ] \
    && [ "$FM_FORGE_URL_PROJECT" = "$FM_FORGE_PROJECT" ]
}
