#!/usr/bin/env bash
# Counterfactual tests for bin/fm-review-diff.sh review-head precedence and
# provider identity. A fresh provider ref must defeat a stale reachable
# pr_head=, while offline metadata and local-branch fallbacks remain bounded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

set_origin_identity() {
  local case_dir=$1 host=$2 project=$3 url
  url="https://$host/$project"
  git -C "$case_dir/project" remote set-url origin "$url"
  git -C "$case_dir/project" config --unset-all "url.$case_dir/origin.git.insteadOf" 2>/dev/null || true
  git -C "$case_dir/project" config --add "url.$case_dir/origin.git.insteadOf" "$url"
}

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  set_origin_identity "$case_dir" github.com example/repo
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_review_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"
  STALE_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q -b review-head-tmp
  printf 'review-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on review"
  REVIEW_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" checkout -q fm/task-x1
}

push_review_head() {
  local case_dir=$1 provider=$2
  case "$provider" in
    github) git -C "$case_dir/wt" push -q origin "review-head-tmp:refs/pull/9/head" ;;
    gitlab) git -C "$case_dir/wt" push -q origin "review-head-tmp:refs/merge-requests/9/head" ;;
    *) fail "unknown review provider fixture" ;;
  esac
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_FORGE_HOSTS_FILE="$case_dir/forge-hosts" \
    "$REVIEW_DIFF" "$@"
}

assert_review_diff() {
  local out=$1 label=$2
  assert_contains "$out" '+review-fixed' "$label: diff should use the current review head"
  assert_not_contains "$out" 'stale-local' "$label: stale reachable metadata must not win"
}

test_fresh_github_head_defeats_stale_recorded_head() {
  local case_dir out private_head fetch_head
  case_dir=$(make_case github-fresh)
  stale_and_review_commits "$case_dir"
  push_review_head "$case_dir" github
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$STALE_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr") \
    || fail "fresh GitHub review diff failed: $(cat "$case_dir/stderr")"
  assert_review_diff "$out" github-fresh
  private_head=$(git -C "$case_dir/wt" rev-parse refs/fm-review/github/9/head)
  fetch_head=$(git -C "$case_dir/wt" rev-parse FETCH_HEAD)
  [ "$private_head" = "$REVIEW_SHA" ] || fail "GitHub review head was not isolated in the private ref"
  [ "$fetch_head" != "$private_head" ] || fail "base fetch clobbered the review comparison through FETCH_HEAD"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: review head unavailable' \
    "github-fresh: successful live fetch should not warn"
  pass "fresh GitHub review heads defeat stale reachable recorded heads"
}

test_fresh_gitlab_head_defeats_stale_recorded_head() {
  local case_dir out
  case_dir=$(make_case gitlab-fresh)
  set_origin_identity "$case_dir" gitlab.com example/repo
  stale_and_review_commits "$case_dir"
  push_review_head "$case_dir" gitlab
  write_task_meta "$case_dir" \
    "pr=https://gitlab.com/example/repo/-/merge_requests/9" \
    "pr_head=$STALE_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr") \
    || fail "fresh GitLab review diff failed: $(cat "$case_dir/stderr")"
  assert_review_diff "$out" gitlab-fresh
  [ "$(git -C "$case_dir/wt" rev-parse refs/fm-review/gitlab/9/head)" = "$REVIEW_SHA" ] \
    || fail "GitLab review head was not isolated in the private ref"
  pass "fresh GitLab review heads defeat stale reachable recorded heads"
}

test_trusted_self_hosted_gitlab_head() {
  local case_dir out
  case_dir=$(make_case gitlab-self-hosted)
  set_origin_identity "$case_dir" gitlab.example.test group/subgroup/repo
  printf 'gitlab gitlab.example.test\n' > "$case_dir/forge-hosts"
  stale_and_review_commits "$case_dir"
  push_review_head "$case_dir" gitlab
  write_task_meta "$case_dir" \
    "pr=https://gitlab.example.test/group/subgroup/repo/-/merge_requests/9" \
    "pr_head=$STALE_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr") \
    || fail "trusted self-hosted GitLab review diff failed: $(cat "$case_dir/stderr")"
  assert_review_diff "$out" gitlab-self-hosted
  pass "trusted self-hosted GitLab identity can fetch the current review head"
}

test_remote_unavailability_falls_back_to_recorded_head() {
  local case_dir out
  case_dir=$(make_case recorded-fallback)
  stale_and_review_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$REVIEW_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr") \
    || fail "reachable recorded-head fallback failed: $(cat "$case_dir/stderr")"
  assert_contains "$out" '+review-fixed' "recorded fallback should use the reachable reviewed commit"
  assert_not_contains "$out" 'stale-local' "recorded fallback should not use the local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: review head unavailable' \
    "reachable recorded fallback should not warn about the local branch"
  pass "remote unavailability falls back to a reachable recorded review head"
}

test_invalid_and_multiline_recorded_heads_are_refused() {
  local case_dir rc
  case_dir=$(make_case invalid-recorded)
  stale_and_review_commits "$case_dir"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    'pr_head=deadbeef'
  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/out" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid recorded SHA was accepted"
  assert_contains "$(cat "$case_dir/stderr")" 'invalid review metadata' \
    "invalid recorded SHA should fail metadata validation"

  case_dir=$(make_case multiline-recorded)
  stale_and_review_commits "$case_dir"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$STALE_SHA" \
    "pr_head=$REVIEW_SHA"
  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/out" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "multiline recorded SHA metadata was accepted"
  assert_contains "$(cat "$case_dir/stderr")" 'invalid review metadata' \
    "multiline SHA metadata should fail validation"
  pass "invalid and multiline recorded review heads are refused"
}

test_no_review_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-review)
  stale_and_review_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr") \
    || fail "local review fallback failed: $(cat "$case_dir/stderr")"
  assert_contains "$out" '+stale-local' "no-review diff should use the local branch"
  assert_not_contains "$out" '+review-fixed' "no-review diff must not discover an unrelated review head"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: review head unavailable' \
    "no-review diff should not warn"
  pass "tasks without a recorded review retain the local branch diff"
}

test_unusable_review_heads_warn_and_use_local_branch() {
  local case_dir out
  case_dir=$(make_case local-fallback)
  stale_and_review_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    'pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr") \
    || fail "local branch warning fallback failed: $(cat "$case_dir/stderr")"
  assert_contains "$out" '+stale-local' "unusable review heads should fall back to local"
  assert_contains "$(cat "$case_dir/stderr")" 'warning: review head unavailable' \
    "local branch fallback must warn"
  pass "the local branch is a warned final fallback when neither review head is usable"
}

test_remote_identity_mismatch_refuses_recorded_fallback() {
  local case_dir rc
  case_dir=$(make_case identity-mismatch)
  set_origin_identity "$case_dir" github.com example/other-repo
  stale_and_review_commits "$case_dir"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$REVIEW_SHA"

  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/out" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "review identity mismatch fell back to recorded metadata"
  assert_contains "$(cat "$case_dir/stderr")" 'does not match the trusted origin' \
    "identity mismatch should be an explicit refusal"
  [ ! -s "$case_dir/out" ] || fail "identity mismatch produced a review diff"
  pass "remote review identity mismatches refuse rather than using recorded metadata"
}

test_fresh_github_head_defeats_stale_recorded_head
test_fresh_gitlab_head_defeats_stale_recorded_head
test_trusted_self_hosted_gitlab_head
test_remote_unavailability_falls_back_to_recorded_head
test_invalid_and_multiline_recorded_heads_are_refused
test_no_review_uses_local_branch
test_unusable_review_heads_warn_and_use_local_branch
test_remote_identity_mismatch_refuses_recorded_fallback
