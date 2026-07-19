#!/usr/bin/env bash
# Make an explicitly configured SSH signing agent available to Git and to
# isolated no-mistakes worktrees without relying on the daemon's ambient socket.
#
# Usage:
#   fm-signing-agent.sh preflight <repo>
#     When commit signing is enabled, verify the configured identity and agent,
#     create a signed scratch commit with SSH_AUTH_SOCK removed, then configure
#     the repo's local no-mistakes gate to use this script as gpg.ssh.program.
#     Signing must be enabled and proven. Missing or disabled signing is refused;
#     only the captain may approve an unsigned fallback outside this helper.
#
#   fm-signing-agent.sh <ssh-keygen arguments...>
#     Git-facing wrapper mode. Read config/signing-agent, set its exact socket,
#     and exec ssh-keygen. The config contains one absolute Unix socket path.
#
# FM_HOME selects the active firstmate home's config/. FM_CONFIG_OVERRIDE and
# FM_SIGNING_AGENT_CONFIG are test/operator path overrides. The config file is
# local, gitignored, inherited by secondmate homes, and never contains a key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SIGNING_AGENT_CONFIG="${FM_SIGNING_AGENT_CONFIG:-$CONFIG/signing-agent}"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

signing_agent_socket() {
  local socket extra
  [ -f "$SIGNING_AGENT_CONFIG" ] && [ ! -L "$SIGNING_AGENT_CONFIG" ] \
    || fail "commit signing requires $SIGNING_AGENT_CONFIG with one absolute SSH agent socket path"
  socket=
  IFS= read -r socket < "$SIGNING_AGENT_CONFIG" || [ -n "$socket" ] \
    || fail "cannot read signing agent config: $SIGNING_AGENT_CONFIG"
  extra=$(awk 'NR > 1 && length($0) > 0 { print; exit }' "$SIGNING_AGENT_CONFIG")
  [ -n "$socket" ] && [ -z "$extra" ] \
    || fail "signing agent config must contain exactly one non-empty line: $SIGNING_AGENT_CONFIG"
  case "$socket" in
    /*) ;;
    *) fail "signing agent socket path must be absolute" ;;
  esac
  [ -S "$socket" ] || fail "configured signing agent socket is unavailable"
  [ -O "$socket" ] || fail "configured signing agent socket is not owned by the current user"
  printf '%s\n' "$socket"
}

ssh_keygen_exec() {
  local socket ssh_keygen
  socket=$(signing_agent_socket)
  ssh_keygen=${FM_SIGNING_SSH_KEYGEN_EXEC:-$(command -v ssh-keygen 2>/dev/null || true)}
  [ -n "$ssh_keygen" ] || fail "ssh-keygen is required for SSH commit signing"
  SSH_AUTH_SOCK="$socket" exec "$ssh_keygen" "$@"
}

signing_required() {
  local repo=$1 effective global
  effective=$(git -C "$repo" config --bool --get commit.gpgsign 2>/dev/null || true)
  global=$(git config --global --bool --get commit.gpgsign 2>/dev/null || true)
  case "$effective" in
    true)
      return 0
      ;;
    false)
      fail "commit signing is disabled for $repo; unsigned fallback requires explicit captain approval"
      ;;
    '')
      fail "commit signing is not enabled for $repo; unsigned fallback requires explicit captain approval"
      ;;
    *)
      fail "cannot determine whether commit signing is required for $repo"
      ;;
  esac
}

signing_key_in_agent() {
  local socket=$1 key=$2 expected keys
  command -v ssh-add >/dev/null 2>&1 || fail "ssh-add is required to inspect the configured signing agent"
  expected=$(awk 'NF >= 2 { print $1 " " $2; exit }' "$key")
  [ -n "$expected" ] || fail "configured SSH signing public key is invalid"
  keys=$(SSH_AUTH_SOCK="$socket" ssh-add -L 2>/dev/null) \
    || fail "configured signing agent did not return any public keys"
  printf '%s\n' "$keys" | awk 'NF >= 2 { print $1 " " $2 }' | grep -Fx "$expected" >/dev/null \
    || fail "configured signing agent does not hold the configured Git signing key"
}

signed_commit_smoke() {
  local repo=$1 format=$2 key=$3 scratch commit
  scratch=$(mktemp -d "$repo/.fm-signing-preflight.XXXXXX" 2>/dev/null) \
    || fail "cannot create signing preflight directory inside $repo"
  trap 'rm -rf -- "$scratch"' EXIT
  git init -q "$scratch"
  git -C "$scratch" config user.name 'Firstmate signing preflight'
  git -C "$scratch" config user.email 'signing-preflight@localhost'
  git -C "$scratch" config commit.gpgsign true
  git -C "$scratch" config gpg.format "$format"
  git -C "$scratch" config user.signingkey "$key"
  if [ "$format" = ssh ]; then
    git -C "$scratch" config gpg.ssh.program "$SELF"
  fi
  printf '%s\n' preflight > "$scratch/probe"
  git -C "$scratch" add probe
  if [ "$format" = ssh ]; then
    env -u SSH_AUTH_SOCK git -C "$scratch" commit -q -m 'signing preflight' \
      || fail "configured signing agent cannot create a signed isolated commit"
  else
    git -C "$scratch" commit -q -m 'signing preflight' \
      || fail "configured signing identity cannot create a signed isolated commit"
  fi
  commit=$(git -C "$scratch" cat-file commit HEAD)
  printf '%s\n' "$commit" | grep -q '^gpgsig ' \
    || fail "signing preflight commit did not contain a signature"
  rm -rf -- "$scratch"
  trap - EXIT
}

configure_gate_wrapper() {
  local repo=$1 gate bare
  gate=$(git -C "$repo" remote get-url no-mistakes 2>/dev/null) \
    || fail "no-mistakes is not initialized for $repo; run no-mistakes init first"
  case "$gate" in
    /*) ;;
    *) fail "no-mistakes gate remote must be an absolute local path" ;;
  esac
  [ -d "$gate" ] && [ ! -L "$gate" ] || fail "no-mistakes gate repository is unavailable"
  bare=$(git --git-dir="$gate" rev-parse --is-bare-repository 2>/dev/null || true)
  [ "$bare" = true ] || fail "no-mistakes gate remote is not a bare Git repository"
  git --git-dir="$gate" config gpg.ssh.program "$SELF" \
    || fail "cannot configure the no-mistakes gate signing wrapper"
}

preflight() {
  local repo=${1:-} format key socket
  [ -n "$repo" ] || fail "usage: fm-signing-agent.sh preflight <repo>"
  repo=$(cd "$repo" 2>/dev/null && pwd -P) || fail "repository path is unavailable"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "not a Git worktree: $repo"
  signing_required "$repo" || return 0

  format=$(git -C "$repo" config --get gpg.format 2>/dev/null || true)
  [ -n "$format" ] || format=openpgp
  key=$(git -C "$repo" config --path --get user.signingkey 2>/dev/null || true)
  [ -n "$key" ] || fail "commit signing is enabled but user.signingkey is not configured"

  if [ "$format" = ssh ]; then
    [ -f "$key" ] || fail "configured SSH signing public key is unavailable"
    socket=$(signing_agent_socket)
    signing_key_in_agent "$socket" "$key"
    signed_commit_smoke "$repo" "$format" "$key"
    configure_gate_wrapper "$repo"
    return 0
  fi

  signed_commit_smoke "$repo" "$format" "$key"
}

case "${1:-}" in
  preflight)
    shift
    [ "$#" -eq 1 ] || fail "usage: fm-signing-agent.sh preflight <repo>"
    preflight "$1"
    ;;
  *)
    ssh_keygen_exec "$@"
    ;;
esac
