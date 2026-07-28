#!/usr/bin/env bash
# Contract tests for removing the retired repository issue tracker while
# preserving Firstmate's own hooks and private fleet queue.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

legacy_name=$(printf 'be%s' 'ads')
legacy_cli=$(printf '%s%s' b d)
archive="$ROOT/docs/completed-issue-history.md"

assert_legacy_hooks_removed() {
  local file

  for file in "$ROOT/.claude/settings.json" "$ROOT/.codex/hooks.json"; do
    jq -e --arg cli "$legacy_cli" \
      '[.. | objects | .command? // empty | select(startswith($cli + " "))] | length == 0' \
      "$file" >/dev/null || fail "$(basename "$file") still invokes the retired issue tracker"
  done

  jq -e '
    (.hooks | has("PostCompact") | not) and
    (.hooks | has("PreCompact") | not) and
    (.hooks | has("UserPromptSubmit") | not) and
    (.hooks.SessionStart | length == 1)
  ' "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "Codex hook configuration retained retired lifecycle events"

  jq -e '.hooks.SessionStart | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude hook configuration retained an extra session-start hook"

  grep -qxF 'hooks = true' "$ROOT/.codex/config.toml" \
    || fail "Codex native hooks were disabled while removing the retired integration"

  pass "retired issue-tracker hooks are absent and Firstmate hooks remain enabled"
}

assert_tracked_workflows_are_clean() {
  local pattern unexpected

  pattern="(^|[^[:alnum:]_])${legacy_name}([^[:alnum:]_]|$)|(^|[^[:alnum:]_.-])${legacy_cli}([^[:alnum:]_.-]|$)|\\.${legacy_name}"
  unexpected=$(git -C "$ROOT" grep -I -n -i -E "$pattern" -- . \
    ':(exclude)docs/completed-issue-history.md' \
    ':(exclude)tests/fm-issue-tracker-retirement.test.sh' || true)

  [ -z "$unexpected" ] || fail "tracked workflow still references the retired issue tracker: $unexpected"

  if grep -qi "$legacy_name" "$ROOT/.gitignore"; then
    fail ".gitignore still hides retired issue-tracker state"
  fi

  pass "tracked contributor and agent workflows contain no retired references"
}

assert_history_and_replacement_guidance() {
  local entry_count

  [ -f "$archive" ] || fail "completed issue history export is missing"
  entry_count=$(grep -Ec '^## firstmate-[^ ]+ - ' "$archive")
  [ "$entry_count" -eq 9 ] || fail "completed issue history should contain 9 records, found $entry_count"

  grep -qF "GitHub Issues is the repository's public issue tracker." "$ROOT/CONTRIBUTING.md" \
    || fail "CONTRIBUTING.md does not name GitHub Issues as the public tracker"
  grep -qF 'This private queue is distinct from the repository' "$ROOT/AGENTS.md" \
    || fail "AGENTS.md no longer distinguishes the private queue from public issues"
  grep -qF 'tasks-axi' "$ROOT/AGENTS.md" \
    || fail "private Firstmate queue guidance was removed"

  pass "completed history is preserved and GitHub Issues owns future tracking"
}

assert_legacy_hooks_removed
assert_tracked_workflows_are_clean
assert_history_and_replacement_guidance
