#!/usr/bin/env bash
# GitLab integration tests for review metadata, authenticated merge monitoring,
# and the guarded merge path. The canonical GitHub poll remains unchanged;
# GitLab uses a hash-registered custom check backed by fm-forge.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP=$(fm_test_tmproot fm-gitlab-review-tests)
export GIT_CONFIG_GLOBAL=/dev/null
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
REPO="$TMP/repo"
FAKEBIN=$(fm_fakebin "$TMP")
LOG="$TMP/glab.log"
MERGED="$TMP/merged"
URL='https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5'
TARGET_BRANCH=release
ID=gitlab-x1

mkdir -p "$STATE" "$HOME_DIR/config"
printf '%s\n' manual > "$HOME_DIR/config/backlog-backend"
fm_git_init_commit "$REPO"
git -C "$REPO" remote add origin git@gitlab.com:kisscut-museum/kisscut-platform.git
git -C "$REPO" checkout -q -b fm/gitlab-x1
DEFAULT_HEAD=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" commit -q --allow-empty -m 'task commit'
fm_write_meta "$STATE/$ID.meta" \
  "window=fm-$ID" \
  "worktree=$REPO" \
  "project=$REPO" \
  "kind=ship" \
  "mode=direct-PR"

cat > "$FAKEBIN/glab" <<'SH'
#!/usr/bin/env bash
set -u
for credential in GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN GLAB_ENABLE_CI_AUTOLOGIN CI_JOB_TOKEN; do
  if [ "${!credential+x}" = x ]; then
    printf 'inherited=%s args=%s\n' "$credential" "$*" >> "$FM_FAKE_GLAB_LOG"
    exit 97
  fi
done
printf 'token=%s args=%s\n' "${GITLAB_TOKEN-unset}" "$*" >> "$FM_FAKE_GLAB_LOG"
if [ "${1:-} ${2:-}" = "auth status" ]; then
  [ "${3:-} ${4:-}" = "--hostname gitlab.com" ]
  exit $?
fi
if [ "${1:-}" = api ]; then
  endpoint=${2:-}
  case "$endpoint" in
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5)
      if [ -e "$FM_FAKE_MERGED" ]; then state=merged; else state=opened; fi
      printf '{"iid":5,"project_id":314,"source_project_id":314,"target_project_id":314,"title":"Ship fix","state":"%s","web_url":"https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5","source_branch":"fm/gitlab-x1","target_branch":"%s","draft":false,"merge_status":"can_be_merged","detailed_merge_status":"mergeable","sha":"%s","merge_commit_sha":null,"head_pipeline":{"id":9,"status":"success","sha":"%s","web_url":"https://gitlab.com/p/9"}}\n' "$state" "$FM_FAKE_TARGET" "$FM_FAKE_HEAD" "$FM_FAKE_HEAD"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/pipelines/9/jobs\?*)
      printf '%s\n' '[{"id":4,"name":"test","stage":"test","status":"success","allow_failure":false,"web_url":"https://gitlab.com/j/4"}]'
      ;;
    projects/kisscut-museum%2Fkisscut-platform)
      printf '%s\n' '{"id":314,"default_branch":"main","builds_access_level":"enabled"}'
      ;;
    *)
      printf 'unexpected endpoint: %s\n' "$endpoint" >&2
      exit 1
      ;;
  esac
  exit 0
fi
if [ "${1:-} ${2:-}" = "mr merge" ]; then
  : > "$FM_FAKE_MERGED"
  exit 0
fi
printf 'unexpected glab call: %s\n' "$*" >&2
exit 1
SH
chmod +x "$FAKEBIN/glab"

REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_FAKE_REPO" ] \
  && [ "${3:-}" = fetch ] && [ "${4:-}" = --quiet ] && [ "${5:-}" = origin ]; then
  "$FM_REAL_GIT" -C "$FM_FAKE_REPO" update-ref refs/remotes/origin/main "$FM_FAKE_DEFAULT_HEAD"
  exit $?
fi
exec "$FM_REAL_GIT" "$@"
SH
chmod +x "$FAKEBIN/git"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi must not be used for GitLab" >&2
exit 99
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
echo "gh must not be used for GitLab" >&2
exit 99
SH
chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/gh"
fm_fake_exit0 "$FAKEBIN" treehouse tmux
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

run_with_env() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_GLAB_LOG="$LOG" \
    FM_FAKE_MERGED="$MERGED" FM_FAKE_HEAD="${FM_TEST_HEAD:-$HEAD_SHA}" \
    FM_FAKE_TARGET="$TARGET_BRANCH" FM_FAKE_REPO="$REPO" FM_REAL_GIT="$REAL_GIT" \
    FM_FAKE_DEFAULT_HEAD="$DEFAULT_HEAD" GITLAB_TOKEN=TEST_AMBIENT_TOKEN \
    GITLAB_ACCESS_TOKEN=TEST_ACCESS_TOKEN OAUTH_TOKEN=TEST_OAUTH_TOKEN \
    GLAB_ENABLE_CI_AUTOLOGIN=true CI_JOB_TOKEN=TEST_CI_TOKEN PATH="$FAKEBIN:$PATH" "$@"
}

test_check_records_head_and_registers_custom_poll() {
  local out mode
  : > "$LOG"
  rm -f "$MERGED"
  out=$(run_with_env "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" --target "$TARGET_BRANCH" 2>/dev/null) \
    || fail "GitLab review check should arm"
  [ "$out" = "armed: state/$ID.check.sh" ] || fail "unexpected arm output: $out"
  assert_grep "pr=$URL" "$STATE/$ID.meta" "GitLab MR URL was not recorded"
  assert_grep "pr_head=$HEAD_SHA" "$STATE/$ID.meta" \
    "GitLab reviewed head was not recorded"
  assert_grep "pr_target=$TARGET_BRANCH" "$STATE/$ID.meta" \
    "GitLab non-default target was not recorded"
  assert_present "$STATE/$ID.check.sh" "GitLab custom poll was not published"
  assert_present "$STATE/$ID.check-trust" "GitLab custom poll was not authenticated"
  assert_absent "$STATE/$ID.pr-poll" "GitLab should not publish the GitHub poll sidecar"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$STATE/$ID.check.sh"); else mode=$(stat -c %a "$STATE/$ID.check.sh"); fi
  [ "$mode" = 700 ] || fail "GitLab custom poll must be mode 0700"
  out=$(run_with_env "$STATE/$ID.check.sh") || fail "open GitLab poll should not fail"
  [ -z "$out" ] || fail "open GitLab poll should be silent"
  : > "$MERGED"
  out=$(run_with_env "$STATE/$ID.check.sh") || fail "merged GitLab poll should not fail"
  [ "$out" = merged ] || fail "merged GitLab poll should emit exactly merged"
  pass "GitLab review metadata and authenticated merge poll are recorded"
}

test_guarded_merge_uses_narrow_adapter() {
  local out changed rc
  : > "$LOG"
  rm -f "$MERGED"
  changed=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  out=$(FM_TEST_HEAD="$changed" run_with_env "$ROOT/bin/fm-pr-merge.sh" "$ID" "$URL" 2>&1)
  rc=$?
  expect_code 1 "$rc" "changed GitLab head before merge"
  assert_contains "$out" "does not match the reviewed SHA" "changed reviewed head refusal"
  assert_grep "pr_head=$HEAD_SHA" "$STATE/$ID.meta" "reviewed head was overwritten"
  assert_no_grep "pr_head=$changed" "$STATE/$ID.meta" "changed head was adopted as reviewed"

  out=$(run_with_env "$ROOT/bin/fm-pr-merge.sh" "$ID" "$URL" 2>/dev/null) \
    || fail "guarded GitLab merge should succeed"
  assert_grep "mr merge 5 --repo kisscut-museum/kisscut-platform --yes --auto-merge=false --sha $HEAD_SHA --squash" \
    "$LOG" "guarded GitLab merge did not apply the default squash method"
  [ "$(printf '%s\n' "$out" | tail -n 1 | jq -r '.mr.state')" = merged ] \
    || fail "guarded merge did not verify merged state"
  assert_no_grep 'gh-axi' "$LOG" "GitLab merge invoked GitHub tooling"
  assert_grep 'token=unset' "$LOG" "GitLab lifecycle inherited an ambient token"
  pass "the guarded merge path delegates GitLab to the narrow adapter"
}

test_open_gitlab_review_refuses_tree_only_cleanup() {
  local out rc
  rm -f "$MERGED"
  out=$(run_with_env "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1)
  rc=$?
  expect_code 1 "$rc" "open GitLab review cleanup"
  assert_contains "$out" "REFUSED" "open GitLab review cleanup refusal"
  assert_present "$STATE/$ID.meta" "open GitLab review cleanup removed task metadata"
  pass "recorded GitLab reviews require canonical merge proof for cleanup"
}

test_explicit_gitlab_merge_method_is_preserved() {
  local out
  : > "$LOG"
  rm -f "$MERGED"
  out=$(run_with_env "$ROOT/bin/fm-pr-merge.sh" "$ID" "$URL" -- --method=merge 2>/dev/null) \
    || fail "explicit GitLab merge method should succeed"
  assert_grep "mr merge 5 --repo kisscut-museum/kisscut-platform --yes --auto-merge=false --sha $HEAD_SHA" \
    "$LOG" "explicit GitLab merge did not pin project and SHA"
  assert_no_grep '--squash' "$LOG" "explicit merge method was overridden by squash"
  [ "$(printf '%s\n' "$out" | tail -n 1 | jq -r '.mr.state')" = merged ] \
    || fail "explicit GitLab merge did not verify merged state"
  pass "an explicit GitLab merge method is not overridden"
}

test_merged_gitlab_work_is_safe_to_clean() {
  local out
  : > "$MERGED"
  out=$(run_with_env "$ROOT/bin/fm-teardown.sh" "$ID" 2>/dev/null) \
    || fail "merged GitLab work should pass cleanup proof"
  assert_absent "$STATE/$ID.meta" "merged GitLab task metadata was not cleaned"
  assert_absent "$STATE/$ID.check.sh" "merged GitLab poll was not cleaned"
  assert_absent "$STATE/$ID.check-trust" "merged GitLab poll trust was not cleaned"
  assert_contains "$out" "Backlog: $ID just finished" "cleanup did not emit backlog reminder"
  pass "merged GitLab work is proven landed before cleanup"
}

test_check_records_head_and_registers_custom_poll
test_open_gitlab_review_refuses_tree_only_cleanup
test_guarded_merge_uses_narrow_adapter
test_explicit_gitlab_merge_method_is_preserved
test_merged_gitlab_work_is_safe_to_clean
