#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This source-safe shell library and cross-language CLI are the single owner of
# current construction, current parsing, and narrow legacy transcript parsing.
#
# Current wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# The leading U+2063 plus "FIRSTMATE_OP: " prefix is permanent compatibility.
# Bodies are opaque untrusted text; kind is derived only from the outer envelope.
# Historical forms below are classifier inputs only and are never produced.
#
# CLI:
#   fm-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current input on stdin, body stdout
#
# Successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief'

# Compatibility names retained for source callers while all current production
# goes through the typed envelope above.
# shellcheck disable=SC2034
FM_INJECT_MARK=$FM_OPERATIONAL_MARK
# shellcheck disable=SC2034
FM_FROMFIRST_LABEL='FIRSTMATE_OP: v1 from-firstmate'
# shellcheck disable=SC2034
FM_FROMFIRST_SEPARATOR=$FM_OPERATIONAL_MARK
# shellcheck disable=SC2034
FM_FROMFIRST_MARK="${FM_OPERATIONAL_HEADER_PREFIX}from-firstmate: "

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" ${1-} "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_encode() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  fm_operational_input_encode "${1-}" "${2-}" "${3-}"
}

fm_operational_input_kind() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$FM_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  fm_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  fm_operational_input_kind "$message" current_kind || return 1
  parsed_body=${message#"${FM_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
  printf -v "$result_var" '%s' "$parsed_body"
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016
FM_LEGACY_SESSIONSTART='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
FM_LEGACY_PI_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_PI_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.'
FM_LEGACY_OPENCODE_WATCHER_PREFIX=$'WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh, handle the reported wake, and continue normal supervision.\n\n'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_OPERATIONAL_MARK}Supervisor escalate ("
FM_LEGACY_AWAY_SEPARATOR=' event(s)): '
FM_LEGACY_FROMFIRST_LABEL='[fm-from-firstmate]'
FM_LEGACY_FROMFIRST_MARK="${FM_LEGACY_FROMFIRST_LABEL}${FM_OPERATIONAL_MARK}"

fm_legacy_operational_input_kind() {  # <legacy-message> <result-var>
  local message=${1-} result_var=${2-} remainder count body
  [ -n "$result_var" ] || return 2

  if [ "$message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi

  case "$message" in
    "$FM_LEGACY_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-firstmate
      return 0
      ;;
    "$FM_LEGACY_PI_WATCHER_PREFIX"*"$FM_LEGACY_PI_WATCHER_SUFFIX")
      remainder=${message#"$FM_LEGACY_PI_WATCHER_PREFIX"}
      body=${remainder%"$FM_LEGACY_PI_WATCHER_SUFFIX"}
      [ -n "$body" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_OPENCODE_WATCHER_PREFIX"?*)
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
    "$FM_LEGACY_AWAY_PREFIX"*"$FM_LEGACY_AWAY_SEPARATOR"?*)
      remainder=${message#"$FM_LEGACY_AWAY_PREFIX"}
      count=${remainder%%"$FM_LEGACY_AWAY_SEPARATOR"*}
      case "$count" in ''|*[!0-9]*) return 1 ;; esac
      body=${remainder#"${count}${FM_LEGACY_AWAY_SEPARATOR}"}
      [ -n "$body" ] || return 1
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
  esac
  return 1
}

fm_legacy_operational_input_body() {  # <legacy-message> <result-var>
  local message=${1-} result_var=${2-} kind parsed_body
  [ -n "$result_var" ] || return 2
  fm_legacy_operational_input_kind "$message" kind || return 1
  case "$kind" in
    from-firstmate) parsed_body=${message#"$FM_LEGACY_FROMFIRST_MARK"} ;;
    away-supervisor) parsed_body=${message#"$FM_OPERATIONAL_MARK"} ;;
    *) parsed_body=$message ;;
  esac
  printf -v "$result_var" '%s' "$parsed_body"
}

fm_operational_input_classify() {  # <current-or-legacy-message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind ||
     fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_message_from_firstmate() {  # <message>
  local kind
  fm_operational_input_classify "${1-}" kind && [ "$kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var>
  local message=${1-} result_var=${2-} kind body transformed
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" kind && [ "$kind" = from-firstmate ]; then
    transformed=$message
  elif fm_legacy_operational_input_kind "$message" kind && [ "$kind" = from-firstmate ]; then
    body=${message#"$FM_LEGACY_FROMFIRST_MARK"}
    fm_operational_input_encode from-firstmate "$body" transformed || return 2
  else
    fm_operational_input_encode from-firstmate "$message" transformed || return 2
  fi
  printf -v "$result_var" '%s' "$transformed"
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin

Current kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output
  case "$command" in
    -h|--help|help)
      [ "$#" -eq 1 ] || return 2
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_encode "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
