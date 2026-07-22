#!/usr/bin/env bash
# Shared forge identity and authenticated GitLab transport.
#
# The registered clone's origin remote selects the host and project, while the
# provider is identified independently: github.com and gitlab.com are built in,
# and self-hosted GitLab requires an exact local registration in
# config/forge-hosts. Unsupported or ambiguous hosts fail before authentication.
# User-supplied issue or merge-request content never selects a host or project.
# Call fm_forge_repo_resolve <repo> before reading FM_FORGE_* globals.
# GitLab calls always use the trusted origin host and remove ambient personal and
# CI token variables so only glab's stored host credential can authenticate.
# shellcheck disable=SC2034 # Globals are consumed by scripts that source this library.

FM_FORGE_KIND=
FM_FORGE_HOST=
FM_FORGE_PROJECT=
FM_FORGE_REMOTE=
FM_FORGE_ISSUE_IID=
FM_FORGE_ISSUE_URL=
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

fm_forge_hosts_file() {
  local root config
  if [ -n "${FM_FORGE_HOSTS_FILE:-}" ]; then
    printf '%s\n' "$FM_FORGE_HOSTS_FILE"
    return 0
  fi
  root=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  config=${FM_CONFIG_OVERRIDE:-$root/config}
  printf '%s/forge-hosts\n' "$config"
}

fm_forge_registered_gitlab_host() {
  local host=$1 file line provider configured_host extra matched=0
  file=$(fm_forge_hosts_file) || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    provider=
    configured_host=
    extra=
    read -r provider configured_host extra <<< "$line"
    [ "$provider" = gitlab ] && [ -n "$configured_host" ] && [ -z "$extra" ] || return 1
    fm_forge_host_valid "$configured_host" || return 1
    configured_host=$(printf '%s' "$configured_host" | tr '[:upper:]' '[:lower:]')
    [ "$configured_host" != github.com ] && [ "$configured_host" != gitlab.com ] || return 1
    [ "$configured_host" != "$host" ] || matched=1
  done < "$file"
  [ "$matched" -eq 1 ]
}

fm_forge_provider_identify() {
  local host=$1 host_name
  host_name=${host%%:*}
  case "$host_name" in
    github.com)
      [ "$host" = github.com ] || return 1
      FM_FORGE_KIND=github
      ;;
    gitlab.com)
      [ "$host" = gitlab.com ] || return 1
      FM_FORGE_KIND=gitlab
      ;;
    *)
      fm_forge_registered_gitlab_host "$host" || return 1
      FM_FORGE_KIND=gitlab
      ;;
  esac
}

fm_forge_remote_parse() {
  local raw=${1-} rest authority host project
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
  fm_forge_provider_identify "$host" || return 1
  FM_FORGE_REMOTE=$raw
  FM_FORGE_HOST=$host
  FM_FORGE_PROJECT=$project
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

fm_forge_gitlab_glab() {
  local host=$1
  shift
  command -v glab >/dev/null 2>&1 || return 127
  env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
    -u GLAB_ENABLE_CI_AUTOLOGIN -u CI_JOB_TOKEN \
    GLAB_NO_PROMPT=1 GLAB_CHECK_UPDATE=false NO_COLOR=1 GITLAB_HOST="$host" \
    glab "$@"
}

fm_forge_gitlab_auth() {
  local host=$1
  fm_forge_gitlab_glab "$host" auth status --hostname "$host" >/dev/null 2>&1
}

fm_forge_gitlab_api() {
  local host=$1 endpoint=$2
  shift 2
  fm_forge_gitlab_glab "$host" api "$endpoint" --hostname "$host" "$@"
}

fm_forge_gitlab_resource_url_parse_parts() {
  local raw=${1-} resource=${2-} rest host path project iid marker
  FM_FORGE_RESOURCE_IID=
  FM_FORGE_RESOURCE_URL=
  FM_FORGE_URL_HOST=
  FM_FORGE_URL_PROJECT=
  case "$resource" in issues|work_items|merge_requests) ;; *) return 1 ;; esac
  marker="/-/$resource/"
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
  FM_FORGE_RESOURCE_IID=$iid
  FM_FORGE_URL_HOST=$host
  FM_FORGE_URL_PROJECT=$project
  FM_FORGE_RESOURCE_URL="https://$host/$project/-/$resource/$iid"
  [ "$raw" = "$FM_FORGE_RESOURCE_URL" ]
}

fm_forge_gitlab_issue_url_parse_parts() {
  local raw=${1-} resource
  FM_FORGE_ISSUE_IID=
  FM_FORGE_ISSUE_URL=
  case "$raw" in
    */-/issues/*) resource=issues ;;
    */-/work_items/*) resource=work_items ;;
    *) return 1 ;;
  esac
  fm_forge_gitlab_resource_url_parse_parts "$raw" "$resource" || return 1
  FM_FORGE_ISSUE_IID=$FM_FORGE_RESOURCE_IID
  FM_FORGE_ISSUE_URL=$FM_FORGE_RESOURCE_URL
}

fm_forge_gitlab_issue_url_parse() {
  local repo=$1 raw=${2-}
  fm_forge_repo_resolve "$repo" || return 1
  [ "$FM_FORGE_KIND" = gitlab ] || return 1
  fm_forge_gitlab_issue_url_parse_parts "$raw" || return 1
  [ "$FM_FORGE_URL_HOST" = "$FM_FORGE_HOST" ] \
    && [ "$FM_FORGE_URL_PROJECT" = "$FM_FORGE_PROJECT" ]
}

fm_forge_gitlab_mr_url_parse_parts() {
  local raw=${1-}
  FM_FORGE_MR_IID=
  FM_FORGE_MR_URL=
  fm_forge_gitlab_resource_url_parse_parts "$raw" merge_requests || return 1
  FM_FORGE_MR_IID=$FM_FORGE_RESOURCE_IID
  FM_FORGE_MR_URL=$FM_FORGE_RESOURCE_URL
}

fm_forge_gitlab_mr_url_parse() {
  local repo=$1 raw=${2-}
  fm_forge_repo_resolve "$repo" || return 1
  [ "$FM_FORGE_KIND" = gitlab ] || return 1
  fm_forge_gitlab_mr_url_parse_parts "$raw" || return 1
  [ "$FM_FORGE_URL_HOST" = "$FM_FORGE_HOST" ] \
    && [ "$FM_FORGE_URL_PROJECT" = "$FM_FORGE_PROJECT" ]
}
