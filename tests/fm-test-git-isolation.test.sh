#!/usr/bin/env bash
# Regression coverage for deterministic fixture Git configuration.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-git-isolation.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

HOST_CONFIG="$TMP_ROOT/host.gitconfig"
cat > "$HOST_CONFIG" <<EOF
[user]
	name = Host User
	email = host@example.invalid
	signingKey = $TMP_ROOT/unavailable-signing-key.pub
[init]
	defaultBranch = hostile-default
[gpg]
	format = ssh
[commit]
	gpgSign = true
EOF
export GIT_CONFIG_GLOBAL="$HOST_CONFIG"
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=true
export GIT_CONFIG_KEY_1=gpg.format
export GIT_CONFIG_VALUE_1=ssh
export GIT_CONFIG_KEY_2=user.signingkey
export GIT_CONFIG_VALUE_2="$TMP_ROOT/unavailable-command-signing-key.pub"
export GIT_CONFIG_KEY_8=commit.gpgsign
export GIT_CONFIG_VALUE_8=true
export GIT_CONFIG_PARAMETERS="'commit.gpgsign=true'"

# shellcheck source=tests/lib.sh disable=SC1091
. "$REPO_ROOT/tests/lib.sh"

[ "$GIT_CONFIG_GLOBAL" = "$ROOT/tests/fixture.gitconfig" ] \
  || fail "tests/lib.sh did not replace the hostile host Git config"
[ "${GIT_CONFIG_COUNT+x}${GIT_CONFIG_PARAMETERS+x}" = "" ] \
  || fail "tests/lib.sh retained command-scope Git configuration"
[ "${GIT_CONFIG_KEY_0+x}${GIT_CONFIG_VALUE_0+x}${GIT_CONFIG_KEY_8+x}${GIT_CONFIG_VALUE_8+x}" = "" ] \
  || fail "tests/lib.sh retained indexed command-scope Git configuration"

FIXTURE="$TMP_ROOT/fixture"
fm_git_init_commit "$FIXTURE" \
  || fail "fixture commit inherited the hostile host signer"
[ "$(git -C "$FIXTURE" branch --show-current)" = main ] \
  || fail "fixture repository did not use the deterministic main branch"
if git -C "$FIXTURE" cat-file commit HEAD | grep -q '^gpgsig '; then
  fail "fixture commit was unexpectedly signed"
fi
[ "$(git -C "$FIXTURE" config --bool --get commit.gpgsign)" = false ] \
  || fail "fixture Git config did not disable host signing"

git -C "$FIXTURE" config commit.gpgsign true
[ "$(git -C "$FIXTURE" config --bool --get commit.gpgsign)" = true ] \
  || fail "local production-style signing could not override the fixture baseline"

pass "fixture Git config blocks hostile host signing while preserving explicit local signing"
