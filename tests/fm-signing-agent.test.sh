#!/usr/bin/env bash
# Behavior tests for the explicit SSH signing-agent bridge used by no-mistakes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-signing-agent)
HELPER="$ROOT/bin/fm-signing-agent.sh"
export GIT_CONFIG_GLOBAL=/dev/null
AGENT_SOCKET=
AGENT_PID_VALUE=

cleanup() {
  if [ -n "$AGENT_PID_VALUE" ] && [ -n "$AGENT_SOCKET" ]; then
    SSH_AGENT_PID="$AGENT_PID_VALUE" SSH_AUTH_SOCK="$AGENT_SOCKET" ssh-agent -k >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_test_agent() {
  local key=$1
  command -v ssh-agent >/dev/null 2>&1 || fail "ssh-agent is required for signing-agent tests"
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required for signing-agent tests"
  eval "$(ssh-agent -s)" >/dev/null
  AGENT_SOCKET=$SSH_AUTH_SOCK
  AGENT_PID_VALUE=$SSH_AGENT_PID
  ssh-keygen -q -t ed25519 -N '' -f "$key"
  SSH_AUTH_SOCK="$AGENT_SOCKET" ssh-add "$key" >/dev/null 2>&1 \
    || fail "could not load the test signing key"
}

make_repo() {
  local repo=$1 key=$2 gate=$3
  git init -q "$repo"
  git -C "$repo" config user.name 'Signing Test'
  git -C "$repo" config user.email 'signing-test@localhost'
  git -C "$repo" config commit.gpgsign false
  printf '%s\n' initial > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -q -m initial
  git -C "$repo" config user.signingkey "$key.pub"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config commit.gpgsign true
  git init -q --bare "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
}

test_preflight_bridges_agent_into_isolated_commit() {
  local dir home repo gate key wrapper isolated commit
  dir="$TMP/success"
  home="$dir/home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$dir/signing-key"
  mkdir -p "$home/config"
  start_test_agent "$key"
  printf '%s\n' "$AGENT_SOCKET" > "$home/config/signing-agent"
  make_repo "$repo" "$key" "$gate"

  FM_HOME="$home" "$HELPER" preflight "$repo" \
    || fail "signing preflight should succeed with the configured agent"
  wrapper=$(git --git-dir="$gate" config --get gpg.ssh.program)
  [ "$wrapper" = "$HELPER" ] || fail "no-mistakes gate did not record the trusted signing wrapper"
  [ -z "$(git -C "$repo" status --porcelain)" ] || fail "preflight dirtied the source worktree"
  [ -z "$(find "$repo" -maxdepth 1 -name '.fm-signing-preflight.*' -print -quit)" ] \
    || fail "preflight left its scratch repository behind"

  isolated="$dir/isolated"
  git init -q "$isolated"
  git -C "$isolated" config user.name 'Isolated Signing Test'
  git -C "$isolated" config user.email 'isolated-signing-test@localhost'
  git -C "$isolated" config user.signingkey "$key.pub"
  git -C "$isolated" config gpg.format ssh
  git -C "$isolated" config commit.gpgsign true
  git -C "$isolated" config gpg.ssh.program "$wrapper"
  printf '%s\n' signed > "$isolated/file"
  git -C "$isolated" add file
  env -u SSH_AUTH_SOCK FM_HOME="$home" git -C "$isolated" commit -q -m signed \
    || fail "isolated commit could not reach the configured signing agent"
  commit=$(git -C "$isolated" cat-file commit HEAD)
  printf '%s\n' "$commit" | grep -q '^gpgsig ' || fail "isolated commit is unsigned"
  pass "signing preflight bridges the configured identity into isolated signed commits"
}

test_preflight_refuses_missing_or_disabled_signing() {
  local dir home repo gate key out rc
  dir="$TMP/refusals"
  home="$dir/home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$TMP/success/signing-key"
  mkdir -p "$home/config"
  printf '%s\n' "$AGENT_SOCKET" > "$home/config/signing-agent"
  make_repo "$repo" "$key" "$gate"

  rm -f "$home/config/signing-agent"
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing signing-agent config"
  assert_contains "$out" "commit signing requires" "missing config refusal is not actionable"

  printf '%s\n' "$AGENT_SOCKET" > "$home/config/signing-agent"
  git -C "$repo" config commit.gpgsign false
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "disabled configured signing"
  assert_contains "$out" "unsigned fallback requires explicit captain approval" \
    "disabled signing did not retain captain authority"
  pass "signing preflight refuses unavailable or implicitly disabled signing"
}

test_unsigned_repo_without_signing_config_is_unchanged() {
  local dir home repo out
  dir="$TMP/unsigned-noop"
  home="$dir/home"
  repo="$dir/repo"
  mkdir -p "$home/config" "$repo"
  git init -q "$repo"
  git -C "$repo" config commit.gpgsign false
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1) \
    || fail "unsigned repo without a signing policy should remain supported"
  [ -z "$out" ] || fail "unsigned no-op preflight should be silent: $out"
  pass "repos without a signing policy remain a silent no-op"
}

test_preflight_bridges_agent_into_isolated_commit
test_preflight_refuses_missing_or_disabled_signing
test_unsigned_repo_without_signing_config_is_unchanged
