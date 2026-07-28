#!/usr/bin/env bash
# Canonical typed operational-input protocol, compatibility, and producer matrix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

TMP_ROOT=$(fm_test_tmproot fm-operational-input)
trap fm_test_cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

body_cli() {
  printf '%s' "$1" | "$OWNER" body 2>/dev/null
}

expect_unclassified() {
  local label=$1 message=$2 parsed
  ! fm_operational_input_classify "$message" parsed \
    || fail "$label unexpectedly classified as $parsed"
  [ -z "$(classify_cli "$message" || true)" ] \
    || fail "$label unexpectedly classified by CLI"
}

test_current_kind_and_body_matrix() {
  local prefix_hex kind body encoded parsed recovered
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "operational prefix changed from U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief; do
    body="CURRENT_BODY_FOR_${kind}"$'\n''second line: colon: value'
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind"
    [ "$parsed" = "$kind" ] || fail "current $kind became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] || fail "CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" recovered || fail "could not recover $kind body"
    [ "$recovered" = "$body" ] || fail "$kind body changed in shell round trip"
    [ "$(body_cli "$encoded")" = "$body" ] || fail "$kind body changed in CLI round trip"
  done
  pass "operational input: every current kind preserves its exact opaque body"
}

test_from_firstmate_current_and_legacy_idempotence() {
  local current twice legacy migrated parsed body
  fm_message_mark_from_firstmate "inspect the report" current
  fm_operational_input_kind "$current" parsed || fail "current from-firstmate did not parse"
  [ "$parsed" = from-firstmate ] || fail "current from-firstmate became $parsed"
  fm_message_mark_from_firstmate "$current" twice
  [ "$twice" = "$current" ] || fail "current from-firstmate was double-wrapped"

  legacy="${FM_LEGACY_FROMFIRST_MARK}inspect the old transcript"
  [ "$(classify_cli "$legacy")" = from-firstmate ] || fail "legacy from-firstmate was lost"
  ! fm_operational_input_kind "$legacy" parsed || fail "legacy from-firstmate passed current parser"
  fm_message_mark_from_firstmate "$legacy" migrated
  fm_operational_input_kind "$migrated" parsed || fail "legacy from-firstmate did not migrate"
  fm_operational_input_body "$migrated" body || fail "migrated body could not be read"
  [ "$parsed" = from-firstmate ] && [ "$body" = "inspect the old transcript" ] \
    || fail "legacy from-firstmate migration changed kind or body"
  pass "operational input: from-firstmate production is current, idempotent, and legacy-compatible"
}

test_narrow_legacy_matrix() {
  local pi_watcher opencode_watcher turnend away fromfirst fixture expected message parsed
  pi_watcher="${FM_LEGACY_PI_WATCHER_PREFIX}signal: legacy${FM_LEGACY_PI_WATCHER_SUFFIX}"
  opencode_watcher="${FM_LEGACY_OPENCODE_WATCHER_PREFIX}watcher: FAILED legacy"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}2${FM_LEGACY_AWAY_SEPARATOR}done: one | blocked: two"
  fromfirst="${FM_LEGACY_FROMFIRST_MARK}legacy request"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$pi_watcher" \
    "watcher|$opencode_watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away" \
    "from-firstmate|$fromfirst"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected leaked into current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected was not recognized"
    [ "$parsed" = "$expected" ] || fail "legacy $expected became $parsed"
    [ "$(classify_cli "$message")" = "$expected" ] \
      || fail "CLI lost legacy $expected"
  done
  pass "operational input: only identified historical forms remain compatible"
}

test_near_misses_remain_genuine() {
  local mark=$FM_OPERATIONAL_MARK
  expect_unclassified "ASCII current label" "FIRSTMATE_OP: v1 watcher: body"
  expect_unclassified "quoted current envelope" "Captain quote: ${FM_OPERATIONAL_HEADER_PREFIX}watcher: body"
  expect_unclassified "unknown version" "${FM_OPERATIONAL_PREFIX}v2 watcher: body"
  expect_unclassified "unknown kind" "${FM_OPERATIONAL_HEADER_PREFIX}future-kind: body"
  expect_unclassified "empty body" "${FM_OPERATIONAL_HEADER_PREFIX}watcher: "
  expect_unclassified "missing body separator" "${FM_OPERATIONAL_HEADER_PREFIX}watcher:body"
  expect_unclassified "bare marker" "$mark"
  expect_unclassified "arbitrary marked captain text" "${mark}please review this"
  expect_unclassified "altered session-start prose" "${FM_LEGACY_SESSIONSTART} Please explain."
  expect_unclassified "incomplete Pi watcher" "${FM_LEGACY_PI_WATCHER_PREFIX}signal: legacy"
  expect_unclassified "empty OpenCode watcher" "$FM_LEGACY_OPENCODE_WATCHER_PREFIX"
  expect_unclassified "empty turn-end" "$FM_LEGACY_TURNEND_PREFIX"
  expect_unclassified "away nonnumeric count" "${FM_LEGACY_AWAY_PREFIX}two${FM_LEGACY_AWAY_SEPARATOR}body"
  expect_unclassified "away empty body" "${FM_LEGACY_AWAY_PREFIX}2${FM_LEGACY_AWAY_SEPARATOR}"
  expect_unclassified "visible legacy label" "${FM_LEGACY_FROMFIRST_LABEL}legacy request"
  expect_unclassified "reversed legacy marker" "${mark}${FM_LEGACY_FROMFIRST_LABEL}legacy request"
  pass "operational input: arbitrary, quoted, malformed, and altered near misses remain genuine"
}

test_nested_x_and_mixed_bodies_cannot_change_outer_kind() {
  local nested_public current legacy encoded kind body line count=0
  current="${FM_OPERATIONAL_HEADER_PREFIX}watcher: nested current"
  legacy="${FM_LEGACY_FROMFIRST_MARK}nested legacy"
  nested_public="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: v1 away-supervisor: public X text"$'\n'"$legacy"$'\n'"$current"
  fm_operational_input_encode launch-brief "$nested_public" encoded
  fm_operational_input_kind "$encoded" kind || fail "nested X launch did not parse"
  fm_operational_input_body "$encoded" body || fail "nested X launch body was unreadable"
  [ "$kind" = launch-brief ] || fail "nested body changed outer kind to $kind"
  [ "$body" = "$nested_public" ] || fail "nested public X body changed"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $count in
      0) [ "$(classify_cli "$line")" = watcher ] || fail "mixed current record lost" ;;
      1) [ "$(classify_cli "$line")" = from-firstmate ] || fail "mixed legacy record lost" ;;
    esac
    count=$((count + 1))
  done <<EOF
$current
$legacy
EOF
  [ "$count" -eq 2 ] || fail "mixed current/legacy record count changed"
  pass "operational input: nested public X text and mixed history preserve trusted outer classification"
}

run_js_adapter() { # <root> <kind> <body>
  FM_TEST_ROOT=$1 FM_TEST_KIND=$2 FM_TEST_BODY=$3 \
    HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const helper = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await helper.encodeFirstmateOperationalInput(
  process.env.FM_TEST_ROOT,
  process.env.FM_TEST_KIND,
  process.env.FM_TEST_BODY,
));
JS
}

expect_js_adapter_rejects() { # <label> <root>
  local label=$1 fixture_root=$2 rc=0
  run_js_adapter "$fixture_root" watcher body >"$TMP_ROOT/js.out" 2>"$TMP_ROOT/js.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label unsafe JS encoder was accepted"
}

test_cross_language_adapter_and_file_safety() {
  local fixture encoded parsed candidate
  fixture="$TMP_ROOT/adapter"
  mkdir -p "$fixture/bin"
  cp "$OWNER" "$fixture/bin/fm-operational-input.sh"
  chmod 755 "$fixture/bin/fm-operational-input.sh"
  encoded=$(run_js_adapter "$fixture" watcher CROSS_LANGUAGE_BODY) \
    || fail "OpenCode adapter could not invoke canonical owner"
  fm_operational_input_kind "$encoded" parsed || fail "OpenCode adapter emitted invalid envelope"
  [ "$parsed" = watcher ] || fail "OpenCode adapter changed kind to $parsed"

  rm "$fixture/bin/fm-operational-input.sh"
  ln -s "$OWNER" "$fixture/bin/fm-operational-input.sh"
  expect_js_adapter_rejects "symlink" "$fixture"

  rm "$fixture/bin/fm-operational-input.sh"
  candidate="$TMP_ROOT/hardlink-owner"
  cp "$OWNER" "$candidate"
  chmod 755 "$candidate"
  ln "$candidate" "$fixture/bin/fm-operational-input.sh"
  expect_js_adapter_rejects "hard link" "$fixture"

  rm "$fixture/bin/fm-operational-input.sh"
  cp "$OWNER" "$fixture/bin/fm-operational-input.sh"
  chmod 644 "$fixture/bin/fm-operational-input.sh"
  expect_js_adapter_rejects "non-executable file" "$fixture"

  rm "$fixture/bin/fm-operational-input.sh"
  mkdir "$fixture/bin/fm-operational-input.sh"
  expect_js_adapter_rejects "directory" "$fixture"

  rmdir "$fixture/bin/fm-operational-input.sh"
  mkfifo "$fixture/bin/fm-operational-input.sh"
  expect_js_adapter_rejects "FIFO" "$fixture"

  rm "$fixture/bin/fm-operational-input.sh"
  ln -s /dev/null "$fixture/bin/fm-operational-input.sh"
  expect_js_adapter_rejects "device link" "$fixture"
  pass "operational input: cross-language adapter uses only an executable single-link regular owner"
}

test_pi_typescript_adapter_uses_owner_when_bun_available() {
  local runner encoded parsed legacy unsafe rc=0
  command -v bun >/dev/null 2>&1 || {
    printf 'skip - operational input: bun unavailable for Pi adapter runtime check\n'
    return 0
  }
  runner="$TMP_ROOT/pi-adapter-runner.ts"
  cat > "$runner" <<EOF
import {
  encodeFirstmateOperationalInput,
  classifyFirstmateOperationalText,
  classifyFirstmateCurrentOperationalText,
} from "$ROOT/.pi/extensions/lib/fm-operational-input.ts";
const mode = process.argv[2];
const value = process.argv[3] ?? "";
if (mode === "encode") process.stdout.write(encodeFirstmateOperationalInput("watcher", value));
if (mode === "classify") process.stdout.write(classifyFirstmateOperationalText(value) ?? "");
if (mode === "current") process.stdout.write(classifyFirstmateCurrentOperationalText(value) ?? "");
EOF
  encoded=$(FM_OPERATIONAL_INPUT_SCRIPT="$OWNER" bun "$runner" encode PI_ADAPTER_BODY) \
    || fail "Pi TypeScript adapter could not encode through owner"
  fm_operational_input_kind "$encoded" parsed || fail "Pi adapter emitted invalid envelope"
  [ "$parsed" = watcher ] || fail "Pi adapter changed watcher to $parsed"
  [ "$(FM_OPERATIONAL_INPUT_SCRIPT="$OWNER" bun "$runner" current "$encoded")" = watcher ] \
    || fail "Pi current-only classifier retained a trailing newline or wrong kind"
  legacy="${FM_LEGACY_FROMFIRST_MARK}old request"
  [ "$(FM_OPERATIONAL_INPUT_SCRIPT="$OWNER" bun "$runner" classify "$legacy")" = from-firstmate ] \
    || fail "Pi compatibility classifier lost legacy input"

  unsafe="$TMP_ROOT/pi-owner-link"
  ln -s "$OWNER" "$unsafe"
  FM_OPERATIONAL_INPUT_SCRIPT="$unsafe" bun "$runner" encode body \
    >"$TMP_ROOT/pi.out" 2>"$TMP_ROOT/pi.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "Pi adapter accepted a symlinked owner"
  pass "operational input: Pi TypeScript adapter encodes and classifies through a safe owner"
}

test_current_producer_inventory_is_atomic() {
  local file content
  for file in \
    bin/fm-sessionstart-nudge.sh \
    bin/fm-supervise-daemon.sh \
    bin/fm-turnend-guard-grok.sh \
    bin/fm-send.sh \
    bin/fm-spawn.sh \
    .pi/extensions/fm-primary-pi-watch.ts \
    .pi/extensions/fm-primary-turnend-guard.ts \
    .opencode/plugins/fm-primary-watch-arm.js \
    .opencode/plugins/fm-primary-turnend-guard.js
  do
    content=$(cat "$ROOT/$file")
    case "$file" in
      bin/fm-send.sh) assert_contains "$content" 'fm_message_mark_from_firstmate' "$file bypassed owner" ;;
      bin/fm-spawn.sh) assert_contains "$content" '__OPINPUT__ encode launch-brief' "$file bypassed owner" ;;
      .pi/*|.opencode/*) assert_contains "$content" 'encodeFirstmateOperationalInput' "$file bypassed adapter" ;;
      *) assert_contains "$content" 'fm_operational_input_encode' "$file bypassed owner" ;;
    esac
    case "$file" in
      .pi/*|.opencode/*)
        assert_not_contains "$content" 'FIRSTMATE_OP:' "$file manually assembled protocol prefix"
        assert_not_contains "$content" '\\u2063' "$file manually assembled invisible marker"
        ;;
    esac
  done
  content=$(cat "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js")
  assert_contains "$content" 'fm-sessionstart-nudge.sh' "OpenCode session start bypassed encoded wrapper"
  content=$(cat "$ROOT/.claude/settings.json")
  assert_contains "$content" 'fm-sessionstart-nudge.sh' "Claude session start bypassed encoded wrapper"
  content=$(cat "$ROOT/.grok/hooks/fm-primary-sessionstart-nudge.json")
  assert_contains "$content" 'fm-sessionstart-nudge.sh' "Grok session start bypassed encoded wrapper"
  content=$(cat "$ROOT/.codex/hooks.json")
  assert_contains "$content" 'fm-sessionstart-nudge.sh' "Codex session start bypassed encoded wrapper"
  pass "operational input: every current synthetic user-role producer routes through the owner"
}

test_invalid_current_encodings_are_rejected() {
  local output parsed
  output=$(printf body | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy kind was accepted as current"
  [ -z "$output" ] || fail "invalid kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty body was accepted"
  [ -z "$output" ] || fail "empty body printed protocol data"
  ! fm_operational_input_kind "${FM_OPERATIONAL_HEADER_PREFIX}watcher: " parsed \
    || fail "empty current body parsed"
  pass "operational input: invalid current construction and empty bodies are rejected"
}

test_current_kind_and_body_matrix
test_from_firstmate_current_and_legacy_idempotence
test_narrow_legacy_matrix
test_near_misses_remain_genuine
test_nested_x_and_mixed_bodies_cannot_change_outer_kind
test_cross_language_adapter_and_file_safety
test_pi_typescript_adapter_uses_owner_when_bun_available
test_current_producer_inventory_is_atomic
test_invalid_current_encodings_are_rejected
