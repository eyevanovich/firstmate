#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for GitHub and GitLab review
# polling. Callers must validate task IDs and raw review URLs before constructing
# task paths or performing any side effect.
#
# A validated exact merged result is retired only after its durable wake is
# appended. The private receipt binds the provider identity and every current
# poll artifact, including an artifact's exact absence, so interrupted cleanup
# can resume without executing state-file bytes or removing a replacement poll.
# shellcheck disable=SC2034 # Parsed forge globals are consumed by sourcing scripts.

FM_PR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-forge-lib.sh disable=SC1091
. "$FM_PR_LIB_DIR/fm-forge-lib.sh"
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$FM_PR_LIB_DIR/fm-check-lib.sh"

FM_PR_URL=
FM_PR_FORGE=
FM_PR_HOST=
FM_PR_PROJECT=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=
FM_PR_DATA_URL=
FM_PR_DATA_OWNER=
FM_PR_DATA_REPO=
FM_PR_DATA_NUMBER=
FM_PR_META_FORGE=
FM_PR_META_URL=
FM_PR_META_HOST=
FM_PR_META_PROJECT=
FM_PR_META_OWNER=
FM_PR_META_REPO=
FM_PR_META_NUMBER=
FM_PR_REG_ID=
FM_PR_REG_URL=
FM_PR_REG_OWNER=
FM_PR_REG_REPO=
FM_PR_REG_NUMBER=
FM_PR_REG_DATA_HASH=
FM_PR_REG_TEMPLATE_HASH=
FM_PR_REG_DATA_IDENTITY=
FM_PR_REG_CHECK_IDENTITY=
FM_PR_POLL_DATA_TMP=
FM_PR_POLL_CHECK_TMP=
FM_PR_POLL_REG_TMP=
FM_PR_POLL_DATA_DEST=
FM_PR_POLL_CHECK_DEST=
FM_PR_POLL_REG_DEST=
FM_PR_POLL_EXPECT_ID=
FM_PR_POLL_EXPECT_URL=
FM_PR_POLL_EXPECT_OWNER=
FM_PR_POLL_EXPECT_REPO=
FM_PR_POLL_EXPECT_NUMBER=
FM_PR_POLL_EXPECT_DATA_HASH=
FM_PR_POLL_EXPECT_TEMPLATE_HASH=
FM_PR_POLL_EXPECT_DATA_IDENTITY=
FM_PR_POLL_EXPECT_CHECK_IDENTITY=
FM_PR_POLL_TEMPLATE=
FM_PR_POLL_STATE_DEVICE=
FM_PR_POLL_SNAPSHOT_ID=
FM_PR_POLL_SNAPSHOT_PROVIDER=
FM_PR_POLL_SNAPSHOT_URL=
FM_PR_POLL_SNAPSHOT_HOST=
FM_PR_POLL_SNAPSHOT_PROJECT=
FM_PR_POLL_SNAPSHOT_NUMBER=
FM_PR_POLL_SNAPSHOT_CHECK_MODE=
FM_PR_POLL_SNAPSHOT_CHECK_HASH=
FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
FM_PR_POLL_SNAPSHOT_DATA_PRESENCE=
FM_PR_POLL_SNAPSHOT_DATA_HASH=
FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=
FM_PR_POLL_SNAPSHOT_REG_PRESENCE=
FM_PR_POLL_SNAPSHOT_REG_HASH=
FM_PR_POLL_SNAPSHOT_REG_IDENTITY=
FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE=
FM_PR_POLL_SNAPSHOT_TRUST_HASH=
FM_PR_POLL_SNAPSHOT_TRUST_IDENTITY=
FM_PR_RETIRE_ID=
FM_PR_RETIRE_PROVIDER=
FM_PR_RETIRE_URL=
FM_PR_RETIRE_HOST=
FM_PR_RETIRE_PROJECT=
FM_PR_RETIRE_NUMBER=
FM_PR_RETIRE_CHECK_MODE=
FM_PR_RETIRE_CHECK_HASH=
FM_PR_RETIRE_CHECK_IDENTITY=
FM_PR_RETIRE_DATA_PRESENCE=
FM_PR_RETIRE_DATA_HASH=
FM_PR_RETIRE_DATA_IDENTITY=
FM_PR_RETIRE_REG_PRESENCE=
FM_PR_RETIRE_REG_HASH=
FM_PR_RETIRE_REG_IDENTITY=
FM_PR_RETIRE_TRUST_PRESENCE=
FM_PR_RETIRE_TRUST_HASH=
FM_PR_RETIRE_TRUST_IDENTITY=
FM_PR_RETIRE_RECEIPT_HASH=
FM_PR_RETIRE_RECEIPT_IDENTITY=
FM_PR_POLL_RETIREMENT_REJECTED=

fm_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_pr_task_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id"
}

fm_task_id_creation_valid() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

fm_pr_url_parse() {
  local raw=${1-} pattern
  local LC_ALL=C
  FM_PR_URL=
  FM_PR_FORGE=
  FM_PR_HOST=
  FM_PR_PROJECT=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    FM_PR_URL=$raw
    FM_PR_FORGE=github
    FM_PR_HOST=github.com
    FM_PR_PROJECT="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    FM_PR_OWNER=${BASH_REMATCH[1]}
    FM_PR_REPO=${BASH_REMATCH[2]}
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  fm_forge_gitlab_mr_url_parse_parts "$raw" || return 1
  FM_PR_URL=$FM_FORGE_MR_URL
  FM_PR_FORGE=gitlab
  FM_PR_HOST=$FM_FORGE_URL_HOST
  FM_PR_PROJECT=$FM_FORGE_URL_PROJECT
  FM_PR_OWNER=${FM_PR_PROJECT%/*}
  FM_PR_REPO=${FM_PR_PROJECT##*/}
  FM_PR_NUMBER=$FM_FORGE_MR_IID
}

fm_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

fm_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

fm_pr_file_identity() {
  local device inode
  device=$(fm_pr_file_device "$1") || return 1
  inode=$(fm_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

fm_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ]
}

fm_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(fm_pr_file_link_count "$path")" = 1 ]
  fi
}

fm_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  fm_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(fm_pr_file_device "$path")" = "$device" ]
}

fm_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 head_count=0 target_count=0 seen_pr=0 post_pr_invalid=0
  FM_PR_META_FORGE=
  FM_PR_META_URL=
  FM_PR_META_HOST=
  FM_PR_META_PROJECT=
  FM_PR_META_OWNER=
  FM_PR_META_REPO=
  FM_PR_META_NUMBER=
  FM_PR_META_HEAD=
  FM_PR_META_TARGET=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if fm_pr_url_parse "$value"; then
          FM_PR_META_FORGE=$FM_PR_FORGE
          FM_PR_META_URL=$FM_PR_URL
          FM_PR_META_HOST=$FM_PR_HOST
          FM_PR_META_PROJECT=$FM_PR_PROJECT
          FM_PR_META_OWNER=$FM_PR_OWNER
          FM_PR_META_REPO=$FM_PR_REPO
          FM_PR_META_NUMBER=$FM_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        head_count=$((head_count + 1))
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          fm_pr_head_valid "$value" || post_pr_invalid=1
          FM_PR_META_HEAD=$value
        fi
        ;;
      pr_target=*)
        target_count=$((target_count + 1))
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_target=}
          git check-ref-format --branch "$value" >/dev/null 2>&1 || post_pr_invalid=1
          FM_PR_META_TARGET=$value
        fi
        ;;
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$head_count" -le 1 ] || return 1
  [ "$target_count" -le 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$FM_PR_META_URL" ]
}

fm_pr_poll_data_parse() {
  local file=$1 url owner repo number
  FM_PR_DATA_URL=
  FM_PR_DATA_OWNER=
  FM_PR_DATA_REPO=
  FM_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r owner <&8 || { exec 8<&-; return 1; }
  IFS= read -r repo <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_FORGE" = github ] || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  FM_PR_DATA_URL=$FM_PR_URL
  FM_PR_DATA_OWNER=$FM_PR_OWNER
  FM_PR_DATA_REPO=$FM_PR_REPO
  FM_PR_DATA_NUMBER=$FM_PR_NUMBER
}

fm_pr_poll_registration_parse() {
  local file=$1 version id url owner repo number data_hash template_hash data_identity check_identity
  FM_PR_REG_ID=
  FM_PR_REG_URL=
  FM_PR_REG_OWNER=
  FM_PR_REG_REPO=
  FM_PR_REG_NUMBER=
  FM_PR_REG_DATA_HASH=
  FM_PR_REG_TEMPLATE_HASH=
  FM_PR_REG_DATA_IDENTITY=
  FM_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r owner <&7 || { exec 7<&-; return 1; }
  IFS= read -r repo <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = fm-pr-poll-registration-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_FORGE" = github ] || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_REG_ID=$id
  FM_PR_REG_URL=$FM_PR_URL
  FM_PR_REG_OWNER=$FM_PR_OWNER
  FM_PR_REG_REPO=$FM_PR_REPO
  FM_PR_REG_NUMBER=$FM_PR_NUMBER
  FM_PR_REG_DATA_HASH=$data_hash
  FM_PR_REG_TEMPLATE_HASH=$template_hash
  FM_PR_REG_DATA_IDENTITY=$data_identity
  FM_PR_REG_CHECK_IDENTITY=$check_identity
}

fm_pr_poll_cleanup() {
  [ -z "$FM_PR_POLL_DATA_TMP" ] || rm -f -- "$FM_PR_POLL_DATA_TMP"
  [ -z "$FM_PR_POLL_CHECK_TMP" ] || rm -f -- "$FM_PR_POLL_CHECK_TMP"
  [ -z "$FM_PR_POLL_REG_TMP" ] || rm -f -- "$FM_PR_POLL_REG_TMP"
  FM_PR_POLL_DATA_TMP=
  FM_PR_POLL_CHECK_TMP=
  FM_PR_POLL_REG_TMP=
}

fm_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_REG_DEST" ] || [ -L "$FM_PR_POLL_REG_DEST" ]; then
    rm -f -- "$FM_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$FM_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$FM_PR_POLL_CHECK_DEST" ] && [ ! -L "$FM_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_REG_DEST" ] && [ ! -L "$FM_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_DATA_DEST" ] && [ ! -L "$FM_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

fm_pr_poll_prepare() {
  local state=$1 id=$2 url=$3 owner=$4 repo=$5 number=$6 template=$7
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_FORGE" = github ] || return 1
  [ "$owner" = "$FM_PR_OWNER" ] || return 1
  [ "$repo" = "$FM_PR_REPO" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  FM_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  FM_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  FM_PR_POLL_EXPECT_ID=$id
  FM_PR_POLL_EXPECT_URL=$url
  FM_PR_POLL_EXPECT_OWNER=$owner
  FM_PR_POLL_EXPECT_REPO=$repo
  FM_PR_POLL_EXPECT_NUMBER=$number
  FM_PR_POLL_TEMPLATE=$template
  FM_PR_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_PR_POLL_STATE_DEVICE" ] || return 1
  FM_PR_POLL_DATA_TMP=$(mktemp "$state/.fm-pr-poll-data.XXXXXX") || return 1
  FM_PR_POLL_CHECK_TMP=$(mktemp "$state/.fm-pr-poll-check.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }
  FM_PR_POLL_REG_TMP=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n' "$url" "$owner" "$repo" "$number" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_OWNER" != "$owner" ] \
    || [ "$FM_PR_DATA_REPO" != "$repo" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$FM_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_CHECK_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_CHECK_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$FM_PR_POLL_CHECK_TMP"; then
    fm_pr_poll_cleanup
    return 1
  fi
  FM_PR_POLL_EXPECT_DATA_HASH=$(fm_pr_sha256 "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_TEMPLATE_HASH=$(fm_pr_sha256 "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_DATA_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_CHECK_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v1 "$id" "$url" "$owner" "$repo" "$number" \
      "$FM_PR_POLL_EXPECT_DATA_HASH" "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$FM_PR_POLL_EXPECT_DATA_IDENTITY" "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$FM_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_REG_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_REG_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_TMP" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    fm_pr_poll_cleanup
    return 1
  fi
}

fm_pr_poll_publish_prepared() {
  [ -n "$FM_PR_POLL_DATA_TMP" ] && [ -n "$FM_PR_POLL_CHECK_TMP" ] \
    && [ -n "$FM_PR_POLL_REG_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_DATA_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_REG_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_PR_POLL_DATA_TMP" "$FM_PR_POLL_DATA_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_DATA_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || [ "$(fm_pr_file_identity "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(fm_pr_sha256 "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_DEST" \
    || [ "$FM_PR_DATA_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_DATA_OWNER" != "$FM_PR_POLL_EXPECT_OWNER" ] \
    || [ "$FM_PR_DATA_REPO" != "$FM_PR_POLL_EXPECT_REPO" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$FM_PR_POLL_REG_TMP" "$FM_PR_POLL_REG_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_REG_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_REG_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_DEST" \
    || [ "$FM_PR_REG_ID" != "$FM_PR_POLL_EXPECT_ID" ] \
    || [ "$FM_PR_REG_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_REG_OWNER" != "$FM_PR_POLL_EXPECT_OWNER" ] \
    || [ "$FM_PR_REG_REPO" != "$FM_PR_POLL_EXPECT_REPO" ] \
    || [ "$FM_PR_REG_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_PR_POLL_CHECK_TMP" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_CHECK_TMP=
  if ! fm_pr_poll_artifacts_valid "${FM_PR_POLL_CHECK_DEST%/*}" "$FM_PR_POLL_EXPECT_ID" "$FM_PR_POLL_TEMPLATE"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
}

fm_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash data_identity check_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  template_hash=$(fm_pr_sha256 "$check") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_OWNER" = "$FM_PR_DATA_OWNER" ] || return 1
  [ "$FM_PR_REG_REPO" = "$FM_PR_DATA_REPO" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_OWNER" = "$FM_PR_DATA_OWNER" ] || return 1
  [ "$FM_PR_META_REPO" = "$FM_PR_DATA_REPO" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ]
}

fm_pr_poll_snapshot_reset() {
  FM_PR_POLL_SNAPSHOT_ID=
  FM_PR_POLL_SNAPSHOT_PROVIDER=
  FM_PR_POLL_SNAPSHOT_URL=
  FM_PR_POLL_SNAPSHOT_HOST=
  FM_PR_POLL_SNAPSHOT_PROJECT=
  FM_PR_POLL_SNAPSHOT_NUMBER=
  FM_PR_POLL_SNAPSHOT_CHECK_MODE=
  FM_PR_POLL_SNAPSHOT_CHECK_HASH=
  FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
  FM_PR_POLL_SNAPSHOT_DATA_PRESENCE=
  FM_PR_POLL_SNAPSHOT_DATA_HASH=
  FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=
  FM_PR_POLL_SNAPSHOT_REG_PRESENCE=
  FM_PR_POLL_SNAPSHOT_REG_HASH=
  FM_PR_POLL_SNAPSHOT_REG_IDENTITY=
  FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE=
  FM_PR_POLL_SNAPSHOT_TRUST_HASH=
  FM_PR_POLL_SNAPSHOT_TRUST_IDENTITY=
}

fm_pr_gitlab_poll_artifacts_valid() {
  local state=$1 id=$2 state_device meta check trust data registration
  local line worktree='' worktree_count=0
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  meta="$state/$id.meta"
  check="$state/$id.check.sh"
  trust="$state/$id.check-trust"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_FORGE" = gitlab ] && [ -n "$FM_PR_META_TARGET" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree=*)
        worktree_count=$((worktree_count + 1))
        [ "$worktree_count" -eq 1 ] && worktree=${line#worktree=}
        ;;
    esac
  done < "$meta"
  [ "$worktree_count" -eq 1 ] && [ -d "$worktree" ] || return 1
  fm_forge_gitlab_mr_url_parse "$worktree" "$FM_PR_META_URL" || return 1
  [ "$FM_FORGE_HOST" = "$FM_PR_META_HOST" ] \
    && [ "$FM_FORGE_PROJECT" = "$FM_PR_META_PROJECT" ] || return 1
  fm_custom_check_registered "$state" "$id" || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  [ ! -e "$data" ] && [ ! -L "$data" ] || return 1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || return 1
  cmp -s <(printf '#!/usr/bin/env bash\nexec %q mr-poll %q %q --target %q\n' \
    "$FM_PR_LIB_DIR/fm-forge.sh" "$worktree" "$FM_PR_META_URL" "$FM_PR_META_TARGET") "$check"
}

fm_pr_poll_snapshot_capture() {
  local state=$1 id=$2 template=$3 check data registration trust state_device
  fm_pr_poll_snapshot_reset
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  trust="$state/$id.check-trust"
  if fm_pr_poll_artifacts_valid "$state" "$id" "$template"; then
    [ ! -e "$trust" ] && [ ! -L "$trust" ] || return 1
    fm_pr_url_parse "$FM_PR_DATA_URL" || return 1
    [ "$FM_PR_FORGE" = github ] || return 1
    FM_PR_POLL_SNAPSHOT_PROVIDER=github
    FM_PR_POLL_SNAPSHOT_CHECK_MODE=600
    FM_PR_POLL_SNAPSHOT_DATA_PRESENCE=present
    FM_PR_POLL_SNAPSHOT_REG_PRESENCE=present
    FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE=absent
    FM_PR_POLL_SNAPSHOT_TRUST_HASH=-
    FM_PR_POLL_SNAPSHOT_TRUST_IDENTITY=-
  elif fm_pr_gitlab_poll_artifacts_valid "$state" "$id"; then
    FM_PR_POLL_SNAPSHOT_PROVIDER=gitlab
    FM_PR_POLL_SNAPSHOT_CHECK_MODE=700
    FM_PR_POLL_SNAPSHOT_DATA_PRESENCE=absent
    FM_PR_POLL_SNAPSHOT_DATA_HASH=-
    FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=-
    FM_PR_POLL_SNAPSHOT_REG_PRESENCE=absent
    FM_PR_POLL_SNAPSHOT_REG_HASH=-
    FM_PR_POLL_SNAPSHOT_REG_IDENTITY=-
    FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE=present
  else
    return 1
  fi
  FM_PR_POLL_SNAPSHOT_ID=$id
  FM_PR_POLL_SNAPSHOT_URL=$FM_PR_META_URL
  FM_PR_POLL_SNAPSHOT_HOST=$FM_PR_META_HOST
  FM_PR_POLL_SNAPSHOT_PROJECT=$FM_PR_META_PROJECT
  FM_PR_POLL_SNAPSHOT_NUMBER=$FM_PR_META_NUMBER
  FM_PR_POLL_SNAPSHOT_CHECK_HASH=$(fm_pr_sha256 "$check") || return 1
  FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=$(fm_pr_file_identity "$check") || return 1
  if [ "$FM_PR_POLL_SNAPSHOT_DATA_PRESENCE" = present ]; then
    FM_PR_POLL_SNAPSHOT_DATA_HASH=$(fm_pr_sha256 "$data") || return 1
    FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=$(fm_pr_file_identity "$data") || return 1
  fi
  if [ "$FM_PR_POLL_SNAPSHOT_REG_PRESENCE" = present ]; then
    FM_PR_POLL_SNAPSHOT_REG_HASH=$(fm_pr_sha256 "$registration") || return 1
    FM_PR_POLL_SNAPSHOT_REG_IDENTITY=$(fm_pr_file_identity "$registration") || return 1
  fi
  if [ "$FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE" = present ]; then
    FM_PR_POLL_SNAPSHOT_TRUST_HASH=$(fm_pr_sha256 "$trust") || return 1
    FM_PR_POLL_SNAPSHOT_TRUST_IDENTITY=$(fm_pr_file_identity "$trust") || return 1
  fi
}

fm_pr_poll_snapshot_fingerprint() {
  printf '%s\n' \
    "$FM_PR_POLL_SNAPSHOT_ID" \
    "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
    "$FM_PR_POLL_SNAPSHOT_URL" \
    "$FM_PR_POLL_SNAPSHOT_HOST" \
    "$FM_PR_POLL_SNAPSHOT_PROJECT" \
    "$FM_PR_POLL_SNAPSHOT_NUMBER" \
    "$FM_PR_POLL_SNAPSHOT_CHECK_MODE" \
    "$FM_PR_POLL_SNAPSHOT_CHECK_HASH" \
    "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
    "$FM_PR_POLL_SNAPSHOT_DATA_PRESENCE" \
    "$FM_PR_POLL_SNAPSHOT_DATA_HASH" \
    "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
    "$FM_PR_POLL_SNAPSHOT_REG_PRESENCE" \
    "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
    "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" \
    "$FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE" \
    "$FM_PR_POLL_SNAPSHOT_TRUST_HASH" \
    "$FM_PR_POLL_SNAPSHOT_TRUST_IDENTITY"
}

fm_pr_poll_snapshot_matches() {
  local state=$1 id=$2 template=$3 expected current
  expected=$(fm_pr_poll_snapshot_fingerprint)
  [ -n "$FM_PR_POLL_SNAPSHOT_ID" ] && [ "$id" = "$FM_PR_POLL_SNAPSHOT_ID" ] || return 1
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" || return 1
  current=$(fm_pr_poll_snapshot_fingerprint)
  [ "$current" = "$expected" ]
}

fm_pr_poll_retirement_reset() {
  FM_PR_RETIRE_ID=
  FM_PR_RETIRE_PROVIDER=
  FM_PR_RETIRE_URL=
  FM_PR_RETIRE_HOST=
  FM_PR_RETIRE_PROJECT=
  FM_PR_RETIRE_NUMBER=
  FM_PR_RETIRE_CHECK_MODE=
  FM_PR_RETIRE_CHECK_HASH=
  FM_PR_RETIRE_CHECK_IDENTITY=
  FM_PR_RETIRE_DATA_PRESENCE=
  FM_PR_RETIRE_DATA_HASH=
  FM_PR_RETIRE_DATA_IDENTITY=
  FM_PR_RETIRE_REG_PRESENCE=
  FM_PR_RETIRE_REG_HASH=
  FM_PR_RETIRE_REG_IDENTITY=
  FM_PR_RETIRE_TRUST_PRESENCE=
  FM_PR_RETIRE_TRUST_HASH=
  FM_PR_RETIRE_TRUST_IDENTITY=
}

fm_pr_poll_retirement_tuple_valid() {
  local presence=$1 hash=$2 identity=$3
  case "$presence" in
    present)
      [[ "$hash" =~ ^[0-9a-f]{64}$ ]] \
        && [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]]
      ;;
    absent) [ "$hash" = - ] && [ "$identity" = - ] ;;
    *) return 1 ;;
  esac
}

fm_pr_poll_retirement_parse() {
  local file=$1 version id provider url host project number check_mode check_hash check_identity
  local data_presence data_hash data_identity reg_presence reg_hash reg_identity
  local trust_presence trust_hash trust_identity result _extra
  fm_pr_poll_retirement_reset
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r project <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_mode <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_presence <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_presence <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r trust_presence <&9 || { exec 9<&-; return 1; }
  IFS= read -r trust_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r trust_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-pr-poll-retirement-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_FORGE" ] \
    && [ "$host" = "$FM_PR_HOST" ] \
    && [ "$project" = "$FM_PR_PROJECT" ] \
    && [ "$number" = "$FM_PR_NUMBER" ] || return 1
  case "$provider:$check_mode:$data_presence:$reg_presence:$trust_presence" in
    github:600:present:present:absent|gitlab:700:absent:absent:present) ;;
    *) return 1 ;;
  esac
  [[ "$check_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  fm_pr_poll_retirement_tuple_valid "$data_presence" "$data_hash" "$data_identity" || return 1
  fm_pr_poll_retirement_tuple_valid "$reg_presence" "$reg_hash" "$reg_identity" || return 1
  fm_pr_poll_retirement_tuple_valid "$trust_presence" "$trust_hash" "$trust_identity" || return 1
  [ "$result" = merged ] || return 1
  FM_PR_RETIRE_ID=$id
  FM_PR_RETIRE_PROVIDER=$provider
  FM_PR_RETIRE_URL=$url
  FM_PR_RETIRE_HOST=$host
  FM_PR_RETIRE_PROJECT=$project
  FM_PR_RETIRE_NUMBER=$number
  FM_PR_RETIRE_CHECK_MODE=$check_mode
  FM_PR_RETIRE_CHECK_HASH=$check_hash
  FM_PR_RETIRE_CHECK_IDENTITY=$check_identity
  FM_PR_RETIRE_DATA_PRESENCE=$data_presence
  FM_PR_RETIRE_DATA_HASH=$data_hash
  FM_PR_RETIRE_DATA_IDENTITY=$data_identity
  FM_PR_RETIRE_REG_PRESENCE=$reg_presence
  FM_PR_RETIRE_REG_HASH=$reg_hash
  FM_PR_RETIRE_REG_IDENTITY=$reg_identity
  FM_PR_RETIRE_TRUST_PRESENCE=$trust_presence
  FM_PR_RETIRE_TRUST_HASH=$trust_hash
  FM_PR_RETIRE_TRUST_IDENTITY=$trust_identity
}

fm_pr_poll_retirement_fingerprint() {
  printf '%s\n' \
    "$FM_PR_RETIRE_ID" \
    "$FM_PR_RETIRE_PROVIDER" \
    "$FM_PR_RETIRE_URL" \
    "$FM_PR_RETIRE_HOST" \
    "$FM_PR_RETIRE_PROJECT" \
    "$FM_PR_RETIRE_NUMBER" \
    "$FM_PR_RETIRE_CHECK_MODE" \
    "$FM_PR_RETIRE_CHECK_HASH" \
    "$FM_PR_RETIRE_CHECK_IDENTITY" \
    "$FM_PR_RETIRE_DATA_PRESENCE" \
    "$FM_PR_RETIRE_DATA_HASH" \
    "$FM_PR_RETIRE_DATA_IDENTITY" \
    "$FM_PR_RETIRE_REG_PRESENCE" \
    "$FM_PR_RETIRE_REG_HASH" \
    "$FM_PR_RETIRE_REG_IDENTITY" \
    "$FM_PR_RETIRE_TRUST_PRESENCE" \
    "$FM_PR_RETIRE_TRUST_HASH" \
    "$FM_PR_RETIRE_TRUST_IDENTITY"
}

fm_pr_poll_retirement_receipt_valid() {
  local state=$1 id=$2 receipt state_device meta
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  meta="$state/$id.meta"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_FORGE" = "$FM_PR_RETIRE_PROVIDER" ] \
    && [ "$FM_PR_META_URL" = "$FM_PR_RETIRE_URL" ] \
    && [ "$FM_PR_META_HOST" = "$FM_PR_RETIRE_HOST" ] \
    && [ "$FM_PR_META_PROJECT" = "$FM_PR_RETIRE_PROJECT" ] \
    && [ "$FM_PR_META_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  FM_PR_RETIRE_RECEIPT_HASH=$(fm_pr_sha256 "$receipt") || return 1
  FM_PR_RETIRE_RECEIPT_IDENTITY=$(fm_pr_file_identity "$receipt") || return 1
}

fm_pr_poll_retirement_check_valid() {
  local state=$1 id=$2 state_device check
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  fm_pr_private_file_valid "$check" "$FM_PR_RETIRE_CHECK_MODE" "$state_device" || return 1
  [ "$(fm_pr_sha256 "$check")" = "$FM_PR_RETIRE_CHECK_HASH" ] \
    && [ "$(fm_pr_file_identity "$check")" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]
}

fm_pr_poll_retirement_data_valid() {
  local state=$1 id=$2 state_device data
  state_device=$(fm_pr_file_device "$state") || return 1
  data="$state/$id.pr-poll"
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  [ "$(fm_pr_sha256 "$data")" = "$FM_PR_RETIRE_DATA_HASH" ] \
    && [ "$(fm_pr_file_identity "$data")" = "$FM_PR_RETIRE_DATA_IDENTITY" ] \
    && fm_pr_poll_data_parse "$data" \
    && [ "$FM_PR_DATA_URL" = "$FM_PR_RETIRE_URL" ] \
    && [ "$FM_PR_DATA_NUMBER" = "$FM_PR_RETIRE_NUMBER" ]
}

fm_pr_poll_retirement_registration_valid() {
  local state=$1 id=$2 state_device registration
  state_device=$(fm_pr_file_device "$state") || return 1
  registration="$state/$id.pr-poll-registration"
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ "$(fm_pr_sha256 "$registration")" = "$FM_PR_RETIRE_REG_HASH" ] \
    && [ "$(fm_pr_file_identity "$registration")" = "$FM_PR_RETIRE_REG_IDENTITY" ] \
    && fm_pr_poll_registration_parse "$registration" \
    && [ "$FM_PR_REG_ID" = "$id" ] \
    && [ "$FM_PR_REG_URL" = "$FM_PR_RETIRE_URL" ] \
    && [ "$FM_PR_REG_NUMBER" = "$FM_PR_RETIRE_NUMBER" ]
}

fm_pr_poll_retirement_trust_valid() {
  local state=$1 id=$2 state_device trust
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  [ "$(fm_pr_sha256 "$trust")" = "$FM_PR_RETIRE_TRUST_HASH" ] \
    && [ "$(fm_pr_file_identity "$trust")" = "$FM_PR_RETIRE_TRUST_IDENTITY" ] \
    && fm_custom_check_trust_read "$state" "$id" \
    && [ "$FM_CUSTOM_CHECK_HASH" = "$FM_PR_RETIRE_CHECK_HASH" ]
}

fm_pr_poll_retirement_state_valid() {
  local state=$1 id=$2 role expected path present_seen=0
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
  for role in check registration data trust; do
    case "$role" in
      check)
        expected=present
        path="$state/$id.check.sh"
        ;;
      registration)
        expected=$FM_PR_RETIRE_REG_PRESENCE
        path="$state/$id.pr-poll-registration"
        ;;
      data)
        expected=$FM_PR_RETIRE_DATA_PRESENCE
        path="$state/$id.pr-poll"
        ;;
      trust)
        expected=$FM_PR_RETIRE_TRUST_PRESENCE
        path="$state/$id.check-trust"
        ;;
    esac
    if [ "$expected" = absent ]; then
      [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
      continue
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
      case "$role" in
        check) fm_pr_poll_retirement_check_valid "$state" "$id" || return 1 ;;
        registration) fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1 ;;
        data) fm_pr_poll_retirement_data_valid "$state" "$id" || return 1 ;;
        trust) fm_pr_poll_retirement_trust_valid "$state" "$id" || return 1 ;;
      esac
      present_seen=1
    else
      [ "$present_seen" -eq 0 ] || return 1
    fi
  done
}

fm_pr_poll_retirement_remove_exact() {
  local path=$1 mode=$2 state_device=$3 expected_identity=$4 expected_hash=$5
  fm_pr_private_file_valid "$path" "$mode" "$state_device" || return 1
  [ "$(fm_pr_file_identity "$path")" = "$expected_identity" ] || return 1
  [ "$(fm_pr_sha256 "$path")" = "$expected_hash" ] || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

fm_pr_poll_retirement_discard_obsolete() {
  local state=$1 id=$2 template=$3 receipt state_device receipt_hash receipt_identity
  local retired current
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  retired=$(fm_pr_poll_retirement_fingerprint)
  receipt_hash=$(fm_pr_sha256 "$receipt") || return 1
  receipt_identity=$(fm_pr_file_identity "$receipt") || return 1
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" || return 1
  current=$(fm_pr_poll_snapshot_fingerprint)
  [ "$current" != "$retired" ] || return 1
  fm_pr_poll_retirement_remove_exact "$receipt" 600 "$state_device" \
    "$receipt_identity" "$receipt_hash"
}

fm_pr_poll_retirement_publish() {
  local state=$1 id=$2 template=$3 result=$4 receipt state_device tmp
  [ "$result" = merged ] || return 1
  fm_pr_poll_snapshot_matches "$state" "$id" "$template" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-retirement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-retirement-v1 \
      "$FM_PR_POLL_SNAPSHOT_ID" \
      "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
      "$FM_PR_POLL_SNAPSHOT_URL" \
      "$FM_PR_POLL_SNAPSHOT_HOST" \
      "$FM_PR_POLL_SNAPSHOT_PROJECT" \
      "$FM_PR_POLL_SNAPSHOT_NUMBER" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_MODE" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_HASH" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_DATA_PRESENCE" \
      "$FM_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_REG_PRESENCE" \
      "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
      "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_TRUST_PRESENCE" \
      "$FM_PR_POLL_SNAPSHOT_TRUST_HASH" \
      "$FM_PR_POLL_SNAPSHOT_TRUST_IDENTITY" \
      merged > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_retirement_parse "$tmp" \
    || [ "$FM_PR_RETIRE_ID" != "$id" ] \
    || ! fm_pr_poll_snapshot_matches "$state" "$id" "$template" \
    || ! fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
}

fm_pr_poll_retirement_recover_one() {
  local state=$1 id=$2 template=$3 receipt state_device receipt_hash receipt_identity path
  fm_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-retirement"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if ! fm_pr_poll_retirement_state_valid "$state" "$id"; then
    fm_pr_poll_retirement_discard_obsolete "$state" "$id" "$template" && return 0
    return 1
  fi
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt_hash=$FM_PR_RETIRE_RECEIPT_HASH
  receipt_identity=$FM_PR_RETIRE_RECEIPT_IDENTITY
  path="$state/$id.check.sh"
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_pr_poll_retirement_remove_exact "$path" "$FM_PR_RETIRE_CHECK_MODE" "$state_device" \
      "$FM_PR_RETIRE_CHECK_IDENTITY" "$FM_PR_RETIRE_CHECK_HASH" || return 1
  fi
  path="$state/$id.pr-poll-registration"
  if [ "$FM_PR_RETIRE_REG_PRESENCE" = present ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
    fm_pr_poll_retirement_remove_exact "$path" 600 "$state_device" \
      "$FM_PR_RETIRE_REG_IDENTITY" "$FM_PR_RETIRE_REG_HASH" || return 1
  fi
  path="$state/$id.pr-poll"
  if [ "$FM_PR_RETIRE_DATA_PRESENCE" = present ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
    fm_pr_poll_retirement_remove_exact "$path" 600 "$state_device" \
      "$FM_PR_RETIRE_DATA_IDENTITY" "$FM_PR_RETIRE_DATA_HASH" || return 1
  fi
  path="$state/$id.check-trust"
  if [ "$FM_PR_RETIRE_TRUST_PRESENCE" = present ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
    fm_pr_poll_retirement_remove_exact "$path" 600 "$state_device" \
      "$FM_PR_RETIRE_TRUST_IDENTITY" "$FM_PR_RETIRE_TRUST_HASH" || return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" 600 "$state_device" \
    "$receipt_identity" "$receipt_hash" || return 1
  [ ! -e "$state/$id.check.sh" ] && [ ! -L "$state/$id.check.sh" ] \
    && [ ! -e "$state/$id.pr-poll-registration" ] && [ ! -L "$state/$id.pr-poll-registration" ] \
    && [ ! -e "$state/$id.pr-poll" ] && [ ! -L "$state/$id.pr-poll" ] \
    && [ ! -e "$state/$id.check-trust" ] && [ ! -L "$state/$id.check-trust" ] \
    && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

fm_pr_poll_retirement_recover_all() {
  local state=$1 template=$2 receipt id
  FM_PR_POLL_RETIREMENT_REJECTED=
  for receipt in "$state"/*.pr-poll-retirement; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-retirement)
    if ! fm_pr_task_id_valid "$id" \
      || ! fm_pr_poll_retirement_recover_one "$state" "$id" "$template"; then
      FM_PR_POLL_RETIREMENT_REJECTED="$FM_PR_POLL_RETIREMENT_REJECTED $receipt"
    fi
  done
  [ -z "$FM_PR_POLL_RETIREMENT_REJECTED" ]
}
