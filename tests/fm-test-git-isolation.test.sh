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

# shellcheck source=tests/lib.sh disable=SC1091
. "$REPO_ROOT/tests/lib.sh"

[ "$GIT_CONFIG_GLOBAL" = "$ROOT/tests/fixture.gitconfig" ] \
  || fail "tests/lib.sh did not replace the hostile host Git config"

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
