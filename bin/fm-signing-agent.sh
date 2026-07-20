#!/usr/bin/env bash
# Prove SSH commit signing for isolated no-mistakes worktrees.
#
# Usage:
#   fm-signing-agent.sh preflight <repo>
#     When commit signing is enabled, create a signed scratch commit with
#     SSH_AUTH_SOCK removed. A private-key user.signingkey signs directly when
#     config/signing-agent is absent. When that config intentionally selects an
#     agent, verify it holds the configured identity and configure the repo's
#     local no-mistakes gate to use this script as gpg.ssh.program. Signing must
#     be enabled and proven; only the captain may approve an unsigned fallback.
#
#   fm-signing-agent.sh <ssh-keygen arguments...>
#     Git-facing wrapper mode for an explicitly configured signing agent. Read
#     config/signing-agent, set its exact socket, and exec ssh-keygen. The config
#     contains one absolute Unix socket path.
#
# FM_HOME selects the active firstmate home's config/. FM_CONFIG_OVERRIDE and
# FM_SIGNING_AGENT_CONFIG are test/operator path overrides. The optional config
# file is local, gitignored, inherited by secondmate homes, and never has a key.
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

signing_agent_configured() {
  [ -e "$SIGNING_AGENT_CONFIG" ] || [ -L "$SIGNING_AGENT_CONFIG" ]
}

ssh_keygen_program() {
  local ssh_keygen
  ssh_keygen=${FM_SIGNING_SSH_KEYGEN_EXEC:-$(command -v ssh-keygen 2>/dev/null || true)}
  [ -n "$ssh_keygen" ] || fail "ssh-keygen is required for SSH commit signing"
  printf '%s\n' "$ssh_keygen"
}

ssh_keygen_exec() {
  local socket ssh_keygen
  socket=$(signing_agent_socket)
  ssh_keygen=$(ssh_keygen_program)
  SSH_AUTH_SOCK="$socket" exec "$ssh_keygen" "$@"
}

signing_required() {
  local repo=$1 effective
  effective=$(git -C "$repo" config --bool --get commit.gpgsign 2>/dev/null || true)
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

signing_public_key() {
  local key=$1 public
  case "$key" in
    key::*|ssh-*|ecdsa-*|sk-*)
      fail "literal SSH user.signingkey values are unsupported; configure a private-key path or an explicit signing agent with a public-key path"
      ;;
    *.pub)
      public=$key
      ;;
    *)
      public=$key.pub
      ;;
  esac
  [ -f "$key" ] || fail "configured SSH signing key is unavailable: $key"
  [ -f "$public" ] \
    || fail "configured SSH signing key requires a companion public key: $public"
  printf '%s\n' "$public"
}

public_key_fingerprint() {
  local public=$1 ssh_keygen fingerprint
  ssh_keygen=$(ssh_keygen_program)
  fingerprint=$("$ssh_keygen" -E sha256 -lf "$public" 2>/dev/null | awk 'NR == 1 { print $2 }') \
    || fail "configured SSH signing public key is invalid: $public"
  case "$fingerprint" in
    SHA256:*) ;;
    *) fail "configured SSH signing public key is invalid: $public" ;;
  esac
  printf '%s\n' "$fingerprint"
}

signing_key_in_agent() {
  local socket=$1 public=$2 expected keys fingerprints ssh_keygen
  command -v ssh-add >/dev/null 2>&1 || fail "ssh-add is required to inspect the configured signing agent"
  ssh_keygen=$(ssh_keygen_program)
  expected=$(public_key_fingerprint "$public")
  keys=$(SSH_AUTH_SOCK="$socket" ssh-add -L 2>/dev/null) \
    || fail "configured signing agent did not return any public keys"
  fingerprints=$(printf '%s\n' "$keys" | "$ssh_keygen" -E sha256 -lf - 2>/dev/null) \
    || fail "configured signing agent returned invalid public keys"
  printf '%s\n' "$fingerprints" | awk -v expected="$expected" \
    '$2 == expected { found = 1 } END { exit(found ? 0 : 1) }' \
    || fail "configured signing agent does not hold the configured Git signing key"
}

signed_commit_smoke() {
  local repo=$1 format=$2 key=$3 signing_path=$4 program scratch commit
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
    case "$signing_path" in
      agent) program=$SELF ;;
      direct) program=$(ssh_keygen_program) ;;
    esac
    git -C "$scratch" config gpg.ssh.program "$program"
  fi
  printf '%s\n' preflight > "$scratch/probe"
  git -C "$scratch" add probe
  if [ "$format" = ssh ]; then
    if ! env -u SSH_AUTH_SOCK git -C "$scratch" commit -q -m 'signing preflight'; then
      case "$signing_path" in
        agent) fail "configured signing agent cannot create a signed isolated commit" ;;
        direct) fail "configured SSH private key cannot create a signed isolated commit without an agent" ;;
      esac
    fi
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

configure_gate_signing() {
  local repo=$1 program=$2 key=$3 gate bare
  gate=$(git -C "$repo" remote get-url no-mistakes 2>/dev/null) \
    || fail "no-mistakes is not initialized for $repo; run no-mistakes init first"
  case "$gate" in
    /*) ;;
    *) fail "no-mistakes gate remote must be an absolute local path" ;;
  esac
  [ -d "$gate" ] && [ ! -L "$gate" ] || fail "no-mistakes gate repository is unavailable"
  bare=$(git --git-dir="$gate" rev-parse --is-bare-repository 2>/dev/null || true)
  [ "$bare" = true ] || fail "no-mistakes gate remote is not a bare Git repository"
  git --git-dir="$gate" config gpg.ssh.program "$program" \
    || fail "cannot configure the no-mistakes gate SSH signing program"
  git --git-dir="$gate" config user.signingkey "$key" \
    || fail "cannot configure the no-mistakes gate SSH signing key"
}

preflight() {
  local repo=${1:-} format key public socket
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
    public=$(signing_public_key "$key")
    public_key_fingerprint "$public" >/dev/null
    if signing_agent_configured; then
      socket=$(signing_agent_socket)
      signing_key_in_agent "$socket" "$public"
      signed_commit_smoke "$repo" "$format" "$public" agent
      configure_gate_signing "$repo" "$SELF" "$public"
      return 0
    fi
    case "$key" in
      *.pub)
        fail "direct SSH signing requires user.signingkey to name a private key; configure config/signing-agent to use a public key"
        ;;
    esac
    signed_commit_smoke "$repo" "$format" "$key" direct
    configure_gate_signing "$repo" "$(ssh_keygen_program)" "$key"
    return 0
  fi

  signed_commit_smoke "$repo" "$format" "$key" direct
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
