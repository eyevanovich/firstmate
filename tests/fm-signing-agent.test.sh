#!/usr/bin/env bash
# Behavior tests for direct SSH signing and the optional explicit-agent bridge.
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

generate_test_key() {
  local key=$1
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required for signing-agent tests"
  mkdir -p "$(dirname "$key")"
  ssh-keygen -q -t ed25519 -N '' -f "$key"
}

start_test_agent() {
  command -v ssh-agent >/dev/null 2>&1 || fail "ssh-agent is required for signing-agent tests"
  eval "$(ssh-agent -s)" >/dev/null
  AGENT_SOCKET=$SSH_AUTH_SOCK
  AGENT_PID_VALUE=$SSH_AGENT_PID
}

load_test_key() {
  local key=$1
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
  git -C "$repo" config user.signingkey "$key"
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config commit.gpgsign true
  git init -q --bare "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
}

assert_signed_commit() {
  local repo=$1 commit
  commit=$(git -C "$repo" cat-file commit HEAD)
  printf '%s\n' "$commit" | grep -q '^gpgsig ' || fail "commit is unsigned"
}

test_preflight_bridges_explicit_agent_into_isolated_commit() {
  local dir home repo gate key wrapper configured_key isolated
  dir="$TMP/agent-success"
  home="$dir/home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$dir/signing-key"
  mkdir -p "$home/config"
  generate_test_key "$key"
  start_test_agent
  load_test_key "$key"
  printf '%s\n' "$AGENT_SOCKET" > "$home/config/signing-agent"
  make_repo "$repo" "$key" "$gate"

  FM_HOME="$home" "$HELPER" preflight "$repo" \
    || fail "signing preflight should succeed with the explicitly configured agent"
  wrapper=$(git --git-dir="$gate" config --get gpg.ssh.program)
  [ "$wrapper" = "$HELPER" ] || fail "no-mistakes gate did not record the trusted signing wrapper"
  configured_key=$(git --git-dir="$gate" config --get user.signingkey)
  [ "$configured_key" = "$key.pub" ] || fail "explicit-agent gate did not record the companion public key"
  [ -z "$(git -C "$repo" status --porcelain)" ] || fail "preflight dirtied the source worktree"
  [ -z "$(find "$repo" -maxdepth 1 -name '.fm-signing-preflight.*' -print -quit)" ] \
    || fail "preflight left its scratch repository behind"

  isolated="$dir/isolated"
  git init -q "$isolated"
  git -C "$isolated" config user.name 'Isolated Signing Test'
  git -C "$isolated" config user.email 'isolated-signing-test@localhost'
  git -C "$isolated" config user.signingkey "$configured_key"
  git -C "$isolated" config gpg.format ssh
  git -C "$isolated" config commit.gpgsign true
  git -C "$isolated" config gpg.ssh.program "$wrapper"
  printf '%s\n' signed > "$isolated/file"
  git -C "$isolated" add file
  env -u SSH_AUTH_SOCK FM_HOME="$home" git -C "$isolated" commit -q -m signed \
    || fail "isolated commit could not reach the explicitly configured signing agent"
  assert_signed_commit "$isolated"
  pass "signing preflight preserves the explicitly configured agent bridge"
}

test_preflight_signs_directly_with_effective_private_key() {
  local dir home user_home repo gate key hostile_program isolated configured_key configured_program
  dir="$TMP/direct-success"
  home="$dir/firstmate-home"
  user_home="$dir/user-home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$user_home/.ssh/id_ed25519_git_signing"
  mkdir -p "$home/config"
  generate_test_key "$key"
  configured_key=$(printf '%b%s' '\176' '/.ssh/id_ed25519_git_signing')
  make_repo "$repo" "$configured_key" "$gate"
  hostile_program="$dir/Secretive-signing-wrapper"
  printf '%s\n' '#!/bin/sh' 'exit 97' > "$hostile_program"
  chmod +x "$hostile_program"
  printf '[gpg "ssh"]\n\tprogram = %s\n' "$hostile_program" > "$dir/hostile.gitconfig"

  HOME="$user_home" GIT_CONFIG_GLOBAL="$dir/hostile.gitconfig" \
    FM_SIGNING_SSH_KEYGEN_EXEC="$hostile_program" \
    SSH_AUTH_SOCK='/tmp/Secretive-agent-does-not-exist.sock' \
    FM_HOME="$home" "$HELPER" preflight "$repo" \
    || fail "private-key preflight should sign directly without a configured agent"
  configured_program=$(git --git-dir="$gate" config --get gpg.ssh.program 2>/dev/null || true)
  [ "$configured_program" != "$hostile_program" ] || fail "direct signing retained an inherited signing wrapper"
  [ "$configured_program" = "$(command -v ssh-keygen)" ] || fail "direct signing did not pin native ssh-keygen"
  configured_key=$(git --git-dir="$gate" config --get user.signingkey)
  [ "$configured_key" = "$key" ] || fail "direct-signing gate did not record the private key"
  [ ! -e "$home/config/signing-agent" ] || fail "direct signing created signing-agent config"

  isolated="$dir/isolated"
  git init -q "$isolated"
  git -C "$isolated" config user.name 'Direct Signing Test'
  git -C "$isolated" config user.email 'direct-signing-test@localhost'
  git -C "$isolated" config user.signingkey "$configured_key"
  git -C "$isolated" config gpg.format ssh
  git -C "$isolated" config commit.gpgsign true
  git -C "$isolated" config gpg.ssh.program "$configured_program"
  printf '%s\n' signed > "$isolated/file"
  git -C "$isolated" add file
  env -u SSH_AUTH_SOCK GIT_CONFIG_GLOBAL="$dir/hostile.gitconfig" \
    git -C "$isolated" commit -q -m signed \
    || fail "private key could not sign directly without SSH_AUTH_SOCK"
  assert_signed_commit "$isolated"
  pass "effective private-key path signs directly without Secretive or SSH_AUTH_SOCK"
}

test_explicit_agent_mismatch_uses_companion_public_key() {
  local dir home repo gate key out rc
  dir="$TMP/agent-mismatch"
  home="$dir/home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$dir/other-signing-key"
  mkdir -p "$home/config"
  generate_test_key "$key"
  printf '%s\n' "$AGENT_SOCKET" > "$home/config/signing-agent"
  make_repo "$repo" "$key" "$gate"

  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "explicit agent mismatch"
  assert_contains "$out" "does not hold the configured Git signing key" \
    "explicit agent mismatch was not actionable"
  assert_not_contains "$out" "grep:" "private-key path triggered the old grep option diagnostic"
  assert_not_contains "$out" "unrecognized option" "private-key path was parsed as public-key text"
  pass "private-key paths resolve companion public identity before explicit-agent matching"
}

test_preflight_refuses_unusable_signing_configuration() {
  local dir home repo gate key out rc
  dir="$TMP/refusals"
  home="$dir/home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$TMP/agent-success/signing-key"
  mkdir -p "$home/config"
  make_repo "$repo" "$key.pub" "$gate"

  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "public key without explicit agent"
  assert_contains "$out" "direct SSH signing requires user.signingkey to name a private key" \
    "public-key direct-signing refusal is not actionable"

  printf '%s\n' '/tmp/missing-signing-agent.sock' > "$home/config/signing-agent"
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "unavailable explicit signing agent"
  assert_contains "$out" "configured signing agent socket is unavailable" \
    "unavailable explicit agent was not diagnosed"

  rm -f "$home/config/signing-agent"
  git -C "$repo" config commit.gpgsign false
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "disabled configured signing"
  assert_contains "$out" "unsigned fallback requires explicit captain approval" \
    "disabled signing did not retain captain authority"
  pass "signing preflight refuses unusable or implicitly disabled signing"
}

test_preflight_rejects_unsupported_literal_key() {
  local dir home repo gate key ca_key prefixed_key resolved_prefixed_key lookalike_key parser_dir real_ssh_keygen literal raw certificate named_literal out rc
  dir="$TMP/literal-key"
  home="$dir/home"
  repo="$dir/repo"
  gate="$dir/gate.git"
  key="$dir/signing-key"
  mkdir -p "$home/config"
  generate_test_key "$key"
  literal="key::$(cat "$key.pub")"
  make_repo "$repo" "$literal" "$gate"

  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "literal SSH signing key"
  assert_contains "$out" "literal SSH user.signingkey values are unsupported" \
    "literal SSH key refusal is not actionable"

  raw=$(cat "$key.pub")
  git -C "$repo" config user.signingkey "$raw"
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "raw literal SSH signing key"
  assert_contains "$out" "literal SSH user.signingkey values are unsupported" \
    "raw literal SSH key refusal is not actionable"

  ca_key="$dir/certificate-authority"
  generate_test_key "$ca_key"
  ssh-keygen -q -s "$ca_key" -I signing-test -n signing "$key.pub"
  certificate=$(cat "$key-cert.pub")
  git -C "$repo" config user.signingkey "$certificate"
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "raw SSH certificate signing key"
  assert_contains "$out" "literal SSH user.signingkey values are unsupported" \
    "raw SSH certificate refusal is not actionable"

  parser_dir="$dir/parser-bin"
  real_ssh_keygen=$(command -v ssh-keygen)
  mkdir -p "$parser_dir"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$*" = "-E sha256 -lf -" ]; then' \
    '  IFS= read -r candidate' \
    '  case "$candidate" in' \
    '    "sk-ssh-ed25519-cert-v01@openssh.com synthetic-certificate-data"|"ssh-xmss@openssh.com synthetic-xmss-data") exit 0 ;;' \
    '    *) exit 1 ;;' \
    '  esac' \
    'fi' \
    "exec '$real_ssh_keygen' \"\$@\"" > "$parser_dir/ssh-keygen"
  chmod +x "$parser_dir/ssh-keygen"
  for named_literal in \
    'sk-ssh-ed25519-cert-v01@openssh.com synthetic-certificate-data' \
    'ssh-xmss@openssh.com synthetic-xmss-data'; do
    git -C "$repo" config user.signingkey "$named_literal"
    out=$(PATH="$parser_dir:$PATH" FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
    rc=$?
    expect_code 1 "$rc" "parser-recognized raw SSH signing key"
    assert_contains "$out" "literal SSH user.signingkey values are unsupported" \
      "parser-recognized raw SSH key refusal is not actionable"
  done

  lookalike_key="$repo/ssh-xmss@openssh.com signing key"
  generate_test_key "$lookalike_key"
  git -C "$repo" config user.signingkey 'ssh-xmss@openssh.com signing key'
  (cd "$TMP" && PATH="$parser_dir:$PATH" FM_HOME="$home" "$HELPER" preflight "$repo") \
    || fail "parser-rejected SSH algorithm lookalike path should succeed"

  prefixed_key="$repo/ssh-signing-key"
  resolved_prefixed_key="$(cd "$repo" && pwd -P)/ssh-signing-key"
  generate_test_key "$prefixed_key"
  git -C "$repo" config user.signingkey ssh-signing-key
  (cd "$TMP" && FM_HOME="$home" "$HELPER" preflight "$repo") \
    || fail "repository-relative signing-key path should ignore the caller directory"
  [ "$(git --git-dir="$gate" config --get user.signingkey)" = "$resolved_prefixed_key" ] \
    || fail "gate did not persist the repository-relative signing-key path consistently"
  pass "unsupported literal SSH signing-key forms are rejected deliberately"
}

test_unsigned_repo_without_signing_config_is_refused() {
  local dir home repo out rc
  dir="$TMP/unsigned-noop"
  home="$dir/home"
  repo="$dir/repo"
  mkdir -p "$home/config" "$repo"
  git init -q "$repo"
  git -C "$repo" config commit.gpgsign false
  out=$(FM_HOME="$home" "$HELPER" preflight "$repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "unsigned repo without signing config"
  assert_contains "$out" "unsigned fallback requires explicit captain approval" \
    "unsigned repo did not retain captain authority"
  pass "repos without proven signing refuse unsigned fallback"
}

test_preflight_bridges_explicit_agent_into_isolated_commit
test_preflight_signs_directly_with_effective_private_key
test_explicit_agent_mismatch_uses_companion_public_key
test_preflight_refuses_unusable_signing_configuration
test_preflight_rejects_unsupported_literal_key
test_unsigned_repo_without_signing_config_is_refused
