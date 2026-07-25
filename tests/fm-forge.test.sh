#!/usr/bin/env bash
# Behavior and security tests for the narrow forge adapter.
# The suite proves that origin is the only host/project authority, providers are
# explicit, unsupported hosts never reach credentials, API output is bounded and
# normalized before reaching an agent, failing checks block merges, and a
# successful merge is head-SHA pinned and verified.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-forge-tests)
ADAPTER="$ROOT/bin/fm-forge.sh"
REPO="$TMP/repo"
FAKEBIN=$(fm_fakebin "$TMP")
REAL_ICONV=$(command -v iconv)
LOG="$TMP/glab.log"
GH_LOG="$TMP/gh.log"
MERGED_MARKER="$TMP/merged"

fm_git_init_commit "$REPO"
git -C "$REPO" remote add origin git@gitlab.com:kisscut-museum/kisscut-platform.git
git -C "$REPO" checkout -q -b fm/fix

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
input=''
input_seen=false
json_headers=0
method=GET
args=("$@")
index=0
while [ "$index" -lt "${#args[@]}" ]; do
  case "${args[$index]}" in
    --method)
      index=$((index + 1))
      method=${args[$index]}
      ;;
    --input)
      index=$((index + 1))
      if [ "${args[$index]}" = - ]; then
        input=$(cat)
        input_seen=true
      fi
      ;;
    --header|-H)
      index=$((index + 1))
      [ "${args[$index]}" != 'Content-Type: application/json' ] || json_headers=$((json_headers + 1))
      ;;
  esac
  index=$((index + 1))
done
if [ "$input_seen" = true ]; then
  [ "$json_headers" -eq 1 ] || {
    printf 'HTTP 415: JSON input requires exactly one application/json content type\n' >&2
    exit 65
  }
  jq -e 'type == "object" and ([.. | select(. == null)] | length == 0)' \
    <<< "$input" >/dev/null || exit 64
  printf 'input=%s\n' "$input" >> "$FM_FAKE_GLAB_LOG"
fi

emit_mr_json() {
  local iid=$1 identity=${2:-exact} state=${3:-opened} response_kind=${4:-detail}
  local project_id=314 source_project_id=314 target_project_id=314
  local source_branch=fm/fix target_branch=${FM_FAKE_TARGET_BRANCH:-main} merge_sha=null pipeline pipeline_sha head_pipeline
  local author_id=42 author_username=mate
  local title=${FM_FAKE_MR_TITLE:-Ship fix} description=${FM_FAKE_MR_DESCRIPTION:-}
  local draft=${FM_FAKE_MR_DRAFT:-false} remove_source=${FM_FAKE_MR_REMOVE_SOURCE:-false}
  local force_remove=${FM_FAKE_MR_FORCE_REMOVE_SOURCE:-false}
  local should_remove=${FM_FAKE_MR_SHOULD_REMOVE_SOURCE:-$remove_source}
  local squash=${FM_FAKE_MR_SQUASH:-false}
  local squash_on_merge=${FM_FAKE_MR_SQUASH_ON_MERGE:-$squash}
  local head_sha=${FM_FAKE_MR_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  case "$identity" in
    exact) ;;
    fork) source_project_id=2718 ;;
    wrong_project) target_project_id=2718 ;;
    wrong_source) source_branch=fm/other ;;
    wrong_target) target_branch=release ;;
    *) return 1 ;;
  esac
  if [ "$state" = merged ]; then
    merge_sha='"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  fi
  if [ "${FM_FAKE_MR_AUTHOR:-self}" = other ]; then
    author_id=77
    author_username=rival
  fi
  pipeline=${FM_FAKE_PIPELINE_STATUS:-success}
  pipeline_sha=${FM_FAKE_PIPELINE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  if [ "${FM_FAKE_HEAD_PIPELINE:-current}" = none ]; then
    head_pipeline=null
  else
    head_pipeline=$(printf '{"id":9,"status":"%s","sha":"%s","web_url":"https://gitlab.com/p/9"}' \
      "$pipeline" "$pipeline_sha")
  fi
  local mr
  mr=$(jq -cn --argjson iid "$iid" --argjson project_id "$project_id" \
    --argjson source_project_id "$source_project_id" --argjson target_project_id "$target_project_id" \
    --arg title "$title" --arg state "$state" --arg source "$source_branch" --arg target "$target_branch" \
    --arg sha "$head_sha" --argjson merge_sha "$merge_sha" --arg description "$description" \
    --argjson draft "$draft" --argjson force_remove "$force_remove" \
    --argjson should_remove "$should_remove" --argjson squash "$squash" \
    --argjson squash_on_merge "$squash_on_merge" --argjson author_id "$author_id" \
    --arg author_username "$author_username" --argjson head_pipeline "$head_pipeline" '
      {iid:$iid,project_id:$project_id,source_project_id:$source_project_id,
       target_project_id:$target_project_id,title:$title,state:$state,
       web_url:("https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/" + ($iid|tostring)),
       source_branch:$source,target_branch:$target,draft:$draft,
       force_remove_source_branch:$force_remove,should_remove_source_branch:$should_remove,
       squash:$squash,squash_on_merge:$squash_on_merge,description:$description,
       merge_status:"can_be_merged",detailed_merge_status:"mergeable",sha:$sha,
       merge_commit_sha:$merge_sha,labels:["backend"],
       author:{id:$author_id,username:$author_username},assignees:[],head_pipeline:$head_pipeline}')
  [ "${FM_FAKE_MR_OMIT_SHOULD_REMOVE:-false}" != true ] \
    || mr=$(jq 'del(.should_remove_source_branch)' <<< "$mr")
  [ "$response_kind" != list ] || [ "${FM_FAKE_MR_LIST_OMIT_CREATE_OPTIONS:-false}" != true ] \
    || mr=$(jq 'del(.should_remove_source_branch,.squash,.squash_on_merge)' <<< "$mr")
  [ "${FM_FAKE_MR_OMIT_SQUASH_ON_MERGE:-false}" != true ] \
    || mr=$(jq 'del(.squash_on_merge)' <<< "$mr")
  [ "${FM_FAKE_MR_DESCRIPTION_FALSE:-false}" != true ] \
    || mr=$(jq '.description=false' <<< "$mr")
  printf '%s\n' "$mr"
}

case "${1:-} ${2:-}" in
  "auth status")
    [ "${FM_FAKE_AUTH_OK:-1}" = 1 ]
    exit $?
    ;;
  "api projects%2F"*)
    ;;
esac

if [ "${1:-}" = api ]; then
  endpoint=${2:-}
  case "$endpoint" in
    user)
      printf '%s\n' '{"id":42,"username":"mate","state":"active","locked":false}'
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues\?*)
      printf '%s\n' '[{"iid":7,"project_id":314,"title":"Fix cutter","state":"opened","web_url":"https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/7","labels":["bug"],"author":{"id":7,"username":"ivan"},"assignees":[{"id":42,"username":"mate"}],"updated_at":"2026-07-18T00:00:00Z","description":"not listed"}]'
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues/7)
      long=$(printf 'x%.0s' {1..4100})
      printf '[{"bad":true}]' >/dev/null
      printf '{"iid":7,"project_id":314,"title":"Fix cutter","state":"opened","web_url":"https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/7","description":"%s","labels":["bug"],"author":{"id":7,"username":"ivan"},"assignees":[{"id":42,"username":"mate"}],"updated_at":"2026-07-18T00:00:00Z"}\n' "$long"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests\?*)
      scenario=${FM_FAKE_MR_LIST_SCENARIO:-exact}
      if [[ "$endpoint" == *source_branch=missing* ]] || [ "$scenario" = none ]; then
        printf '%s\n' '[]'
      elif [ "$scenario" = ambiguous ]; then
        printf '[%s,%s]\n' "$(emit_mr_json 5 exact opened list)" "$(emit_mr_json 6 exact opened list)"
      else
        printf '[%s]\n' "$(emit_mr_json 5 "$scenario" opened list)"
      fi
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests)
      [ "$method" = POST ] || exit 62
      jq -e '
        (. | type) == "object"
        and ((keys - ["description","remove_source_branch","source_branch","squash","target_branch","title"]) | length) == 0
        and (.source_branch | type) == "string"
        and (.target_branch | type) == "string"
        and (.title | type) == "string"
        and (.description | type) == "string"
        and ((has("remove_source_branch") | not) or (.remove_source_branch | type) == "boolean")
        and ((has("squash") | not) or (.squash | type) == "boolean")
      ' <<< "$input" >/dev/null || exit 62
      emit_mr_json 5 "${FM_FAKE_CREATED_MR_IDENTITY:-exact}"
      printf '\n'
      ;;
    projects/kisscut-museum%2Fkisscut-platform/repository/branches/fm%2Ffix)
      printf '{"name":"fm/fix","commit":{"id":"%s"}}\n' \
        "${FM_FAKE_REMOTE_BRANCH_SHA:-$FM_FAKE_LOCAL_HEAD}"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5/pipelines\?*)
      pipeline_sha=${FM_FAKE_PIPELINE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
      if [ "${FM_FAKE_PIPELINE_LIST:-current}" = empty ]; then
        printf '%s\n' '[]'
      else
        printf '[{"id":9,"status":"%s","sha":"%s"}]\n' \
          "${FM_FAKE_PIPELINE_STATUS:-success}" "$pipeline_sha"
      fi
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5)
      if [ -e "$FM_FAKE_MERGED_MARKER" ]; then
        state=merged
      else
        state=${FM_FAKE_MR_STATE:-opened}
      fi
      emit_mr_json 5 "${FM_FAKE_MR_IDENTITY_SCENARIO:-exact}" "$state"
      printf '\n'
      ;;
    projects/kisscut-museum%2Fkisscut-platform/pipelines/9/jobs\?*)
      case "${FM_FAKE_PIPELINE_STATUS:-success}" in
        failed)
          printf '%s\n' '[{"id":1,"name":"test","stage":"test","status":"failed","allow_failure":false,"web_url":"https://gitlab.com/j/1"},{"id":2,"name":"lint","stage":"test","status":"failed","allow_failure":true,"web_url":"https://gitlab.com/j/2"}]'
          ;;
        running)
          printf '%s\n' '[{"id":3,"name":"test","stage":"test","status":"running","allow_failure":false,"web_url":"https://gitlab.com/j/3"}]'
          ;;
        *)
          printf '%s\n' '[{"id":4,"name":"test","stage":"test","status":"success","allow_failure":false,"web_url":"https://gitlab.com/j/4"},{"id":5,"name":"deploy","stage":"deploy","status":"manual","allow_failure":false,"web_url":"https://gitlab.com/j/5"}]'
          ;;
      esac
      ;;
    projects/kisscut-museum%2Fkisscut-platform)
      printf '{"id":314,"default_branch":"main","archived":false,"remove_source_branch_after_merge":%s,"builds_access_level":"%s"}\n' \
        "${FM_FAKE_PROJECT_REMOVE_SOURCE_DEFAULT:-false}" \
        "${FM_FAKE_BUILDS_ACCESS_LEVEL:-enabled}"
      ;;
    *)
      printf 'unexpected fake API endpoint: %s\n' "$endpoint" >&2
      exit 1
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = mr ] && [ "${2:-}" = merge ]; then
  : > "$FM_FAKE_MERGED_MARKER"
  exit 0
fi

printf 'unexpected fake glab call: %s\n' "$*" >&2
exit 1
SH
chmod +x "$FAKEBIN/glab"

cat > "$FAKEBIN/iconv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_REPLACE_BODY:-}" ]; then
  printf 'Replacement body\n' > "$FM_FAKE_REPLACE_BODY"
fi
if [ "${FM_FAKE_INTERRUPT_BODY:-0}" = 1 ]; then
  kill -TERM "$PPID"
  exit 143
fi
exec "$FM_FAKE_REAL_ICONV" "$@"
SH
chmod +x "$FAKEBIN/iconv"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
exit 1
SH
chmod +x "$FAKEBIN/gh"

run_adapter() {
  local -a args=("$@")
  local fake_mr_sha=${FM_FAKE_MR_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  local fake_local_head
  fake_local_head=$(git -C "$REPO" rev-parse HEAD)
  if [ "${1:-}" = mr-create ] && [ -z "${FM_FAKE_MR_SHA:-}" ]; then
    fake_mr_sha=$(git -C "$REPO" rev-parse HEAD)
  fi
  if [ "${1:-}" = mr-merge ] && [ "${FM_TEST_NO_DEFAULT_SHA:-0}" != 1 ]; then
    args+=(--sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
  fi
  PATH="$FAKEBIN:$PATH" FM_FAKE_GLAB_LOG="$LOG" FM_FAKE_GH_LOG="$GH_LOG" \
    FM_FAKE_MERGED_MARKER="$MERGED_MARKER" FM_FORGE_HOSTS_FILE="${FM_FORGE_HOSTS_FILE:-}" \
    FM_FAKE_MR_SHA="$fake_mr_sha" FM_FAKE_LOCAL_HEAD="$fake_local_head" \
    FM_FAKE_REAL_ICONV="$REAL_ICONV" \
    GITLAB_TOKEN=TEST_AMBIENT_TOKEN GITLAB_ACCESS_TOKEN=TEST_ACCESS_TOKEN \
    OAUTH_TOKEN=TEST_OAUTH_TOKEN GLAB_ENABLE_CI_AUTOLOGIN=true CI_JOB_TOKEN=TEST_CI_TOKEN \
    "$ADAPTER" "${args[@]}"
}

reset_case() {
  : > "$LOG"
  : > "$GH_LOG"
  rm -f "$MERGED_MARKER"
}

test_repo_identity_is_remote_derived() {
  local out
  reset_case
  out=$(run_adapter repo "$REPO") || fail "repo identity should resolve"
  [ "$(jq -r '.forge' <<< "$out")" = gitlab ] || fail "repo forge mismatch"
  [ "$(jq -r '.host' <<< "$out")" = gitlab.com ] || fail "repo host mismatch"
  [ "$(jq -r '.project' <<< "$out")" = kisscut-museum/kisscut-platform ] || fail "repo project mismatch"
  [ ! -s "$LOG" ] || fail "repo identity should not contact glab"
  pass "forge identity comes only from the origin remote"
}

test_auth_targets_trusted_host() {
  local out
  reset_case
  out=$(run_adapter auth "$REPO") || fail "auth should succeed"
  [ "$(jq -r '.authenticated' <<< "$out")" = true ] || fail "auth result mismatch"
  assert_grep 'auth status --hostname gitlab.com' "$LOG" "auth did not target trusted host"
  assert_grep 'token=unset' "$LOG" "auth inherited an ambient GitLab token"
  pass "GitLab authentication uses the trusted host and stored credential only"
}

test_public_github_is_identified_without_credentials() {
  local repo out
  reset_case
  repo="$TMP/github-repo"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin git@github.com:group/project.git
  out=$(run_adapter repo "$repo") || fail "public GitHub origin should resolve"
  [ "$(jq -r '.forge' <<< "$out")" = github ] || fail "public GitHub forge mismatch"
  [ "$(jq -r '.host' <<< "$out")" = github.com ] || fail "public GitHub host mismatch"
  [ ! -s "$LOG" ] || fail "GitHub identity contacted glab"
  [ ! -s "$GH_LOG" ] || fail "GitHub identity contacted gh"
  pass "public GitHub identity resolves without a credentialed call"
}

test_registered_self_hosted_gitlab_is_explicit() {
  local repo hosts out
  reset_case
  repo="$TMP/self-hosted-gitlab"
  hosts="$TMP/forge-hosts"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin git@gitlab.example.com:group/project.git

  out=$(run_adapter repo "$repo" 2>&1)
  expect_code 1 "$?" "unregistered self-hosted GitLab"
  assert_contains "$out" "cannot be resolved safely" "unregistered self-hosted GitLab refusal"
  [ ! -s "$LOG" ] || fail "unregistered self-hosted GitLab contacted glab"

  printf '%s\n' 'gitlab gitlab.example.com' > "$hosts"
  out=$(FM_FORGE_HOSTS_FILE="$hosts" run_adapter auth "$repo") \
    || fail "registered self-hosted GitLab auth should succeed"
  [ "$(jq -r '.host' <<< "$out")" = gitlab.example.com ] || fail "registered host mismatch"
  assert_grep 'auth status --hostname gitlab.example.com' "$LOG" \
    "registered self-hosted GitLab did not target its configured host"
  pass "self-hosted GitLab requires an exact trusted registration"
}

test_unsupported_and_ambiguous_hosts_never_reach_credentials() {
  local host repo out rc before_glab before_gh
  reset_case
  for host in bitbucket.org github.example.com unknown.example; do
    repo="$TMP/unsupported-${host//./-}"
    fm_git_init_commit "$repo"
    git -C "$repo" remote add origin "git@$host:group/project.git"
    before_glab=$(wc -l < "$LOG")
    before_gh=$(wc -l < "$GH_LOG")
    out=$(run_adapter auth "$repo" 2>&1)
    rc=$?
    expect_code 1 "$rc" "unsupported forge host $host"
    assert_contains "$out" "cannot be resolved safely" "unsupported host refusal for $host"
    [ "$(wc -l < "$LOG")" -eq "$before_glab" ] || fail "$host reached glab"
    [ "$(wc -l < "$GH_LOG")" -eq "$before_gh" ] || fail "$host reached gh"
  done
  pass "unsupported and GitHub Enterprise-ambiguous hosts fail before credentials"
}

test_issue_output_is_minimal_and_bounded() {
  local out description
  reset_case
  out=$(run_adapter issue-list "$REPO" --limit 1) || fail "issue list should succeed"
  [ "$(jq '.issues | length' <<< "$out")" -eq 1 ] || fail "issue list count mismatch"
  jq -e '.issues[0] | has("description") | not' <<< "$out" >/dev/null \
    || fail "issue list leaked the description"
  out=$(run_adapter issue-view "$REPO" 7) || fail "issue view should succeed"
  description=$(jq -r '.issue.description' <<< "$out")
  [ "${#description}" -eq 4003 ] || fail "issue body was not bounded to 4000 characters plus ellipsis"
  pass "issue output uses a minimal schema and bounded body"
}

test_mr_url_must_match_origin() {
  local out rc before
  reset_case
  before=$(wc -l < "$LOG")
  out=$(run_adapter mr-view "$REPO" 'https://attacker.example/kisscut-museum/kisscut-platform/-/merge_requests/5' 2>&1)
  rc=$?
  expect_code 1 "$rc" "foreign-host MR URL"
  assert_contains "$out" "does not match the repository origin" "foreign-host URL refusal"
  [ "$(wc -l < "$LOG")" -eq "$before" ] || fail "foreign-host URL reached glab"
  pass "merge-request URLs cannot override the origin host or project"
}

test_canonical_resource_urls_share_strict_validation() {
  local command url out rc
  reset_case
  run_adapter issue-view "$REPO" \
    'https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/7' >/dev/null \
    || fail "canonical work-item URL should resolve"
  run_adapter issue-view "$REPO" \
    'https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/7' >/dev/null \
    || fail "legacy canonical issue URL should resolve"
  run_adapter mr-view "$REPO" \
    'https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5' >/dev/null \
    || fail "canonical merge-request URL should resolve"

  while IFS='|' read -r command url; do
    reset_case
    out=$(run_adapter "$command" "$REPO" "$url" 2>&1)
    rc=$?
    expect_code 1 "$rc" "$command malformed canonical URL"
    [ ! -s "$LOG" ] || fail "$command malformed canonical URL reached credentials"
  done <<'CASES'
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/07
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/7?x=1
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/7#fragment
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/7/extra
issue-view|https://gitlab.com/kisscut-museum/other/-/work_items/7
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/7?x=1
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/7/extra
issue-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/7
mr-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/05
mr-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5#fragment
mr-view|https://gitlab.com/kisscut-museum/kisscut-platform/-/work_items/5
CASES
  pass "issue and merge-request URLs share strict canonical validation"
}

test_mr_body_file_cannot_read_outside_worktree() {
  local outside out rc before
  reset_case
  outside="$TMP/outside-body.md"
  printf 'do not upload me\n' > "$outside"
  before=$(wc -l < "$LOG")
  out=$(run_adapter mr-create "$REPO" --title 'Safe title' --source fm/fix --body-file "$outside" 2>&1)
  rc=$?
  expect_code 2 "$rc" "outside MR body file"
  assert_contains "$out" "must stay inside the repository worktree" "outside body file refusal"
  [ "$(wc -l < "$LOG")" -eq "$before" ] || fail "outside body file reached glab"
  pass "merge-request body files cannot exfiltrate files outside the worktree"
}

test_mr_find_requires_one_exact_project_and_branch_match() {
  local scenario out rc
  reset_case
  out=$(run_adapter mr-find "$REPO" fm/fix) || fail "exact merge-request lookup should succeed"
  [ "$(jq -r '.mr.iid' <<< "$out")" -eq 5 ] || fail "exact merge-request IID mismatch"
  assert_grep 'source_branch=fm%2Ffix&target_branch=main' "$LOG" \
    "merge-request lookup did not constrain both branches"

  for scenario in fork wrong_project wrong_target; do
    reset_case
    out=$(FM_FAKE_MR_LIST_SCENARIO="$scenario" run_adapter mr-find "$REPO" fm/fix 2>&1)
    rc=$?
    expect_code 1 "$rc" "$scenario merge-request lookup"
    assert_contains "$out" "identity does not match" "$scenario merge-request refusal"
  done

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=ambiguous run_adapter mr-find "$REPO" fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "ambiguous merge-request lookup"
  assert_contains "$out" "multiple merge requests match" "ambiguous merge-request refusal"
  pass "merge-request lookup requires one exact source project and branch pair"
}

test_mr_create_reuses_only_one_exact_match() {
  local scenario out rc
  reset_case
  out=$(run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/other 2>&1)
  rc=$?
  expect_code 1 "$rc" "merge-request creation for another local branch"
  assert_contains "$out" "does not match the checked-out task branch" \
    "merge-request source branch refusal"
  [ ! -s "$LOG" ] || fail "mismatched local source branch reached credentials"

  reset_case
  out=$(run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix) \
    || fail "exact open merge request should be reused"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] || fail "exact merge request was not reused"
  assert_grep 'merge_requests/5' "$LOG" "exact reuse did not read back the exact merge request"
  assert_no_grep '--method POST' "$LOG" "exact reuse created another merge request"

  reset_case
  out=$(FM_FAKE_PROJECT_REMOVE_SOURCE_DEFAULT=true FM_FAKE_MR_SHOULD_REMOVE_SOURCE=true \
    FM_FAKE_MR_SQUASH_ON_MERGE=true run_adapter mr-create "$REPO" \
      --title 'Ship fix' --source fm/fix) \
    || fail "omitted options should preserve effective project defaults"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "project-default merge request was not reused"
  assert_no_grep '--method POST' "$LOG" "project-default reuse created another merge request"

  reset_case
  out=$(FM_FAKE_MR_LIST_OMIT_CREATE_OPTIONS=true FM_FAKE_MR_SHOULD_REMOVE_SOURCE=true \
    FM_FAKE_MR_SQUASH_ON_MERGE=true run_adapter mr-create "$REPO" \
      --title 'Ship fix' --source fm/fix --remove-source-branch --squash) \
    || fail "exact read-back should tolerate a reduced list response"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "reduced-list merge request was not reused"
  assert_no_grep '--method POST' "$LOG" "reduced-list reuse created another merge request"

  reset_case
  out=$(FM_FAKE_MR_TITLE='Conflicting title' run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "conflicting merge-request retry metadata"
  assert_contains "$out" "does not match requested head and metadata" \
    "conflicting merge-request retry refusal"
  assert_contains "$out" "(title)" "field-only merge-request mismatch diagnostic"
  assert_not_contains "$out" "Conflicting title" "merge-request mismatch leaked response content"
  assert_no_grep '--method POST' "$LOG" "conflicting retry created another merge request"

  reset_case
  out=$(FM_FAKE_MR_FORCE_REMOVE_SOURCE=false FM_FAKE_MR_SHOULD_REMOVE_SOURCE=true \
    FM_FAKE_PROJECT_REMOVE_SOURCE_DEFAULT=false \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix \
      --remove-source-branch) \
    || fail "live-shape merge request should use the MR removal choice over the project default"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "live-shape merge request was not reused"
  assert_no_grep '--method POST' "$LOG" "live-shape reuse created another merge request"

  reset_case
  out=$(FM_FAKE_MR_FORCE_REMOVE_SOURCE=true FM_FAKE_MR_OMIT_SHOULD_REMOVE=true \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix \
      --remove-source-branch) \
    || fail "forced project deletion should prove effective source-branch removal"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "forced-deletion merge request was not reused"

  reset_case
  out=$(FM_FAKE_MR_FORCE_REMOVE_SOURCE=false FM_FAKE_MR_SHOULD_REMOVE_SOURCE=false \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix \
      --remove-source-branch 2>&1)
  rc=$?
  expect_code 1 "$rc" "conflicting merge-request remove-source intent"
  assert_contains "$out" "(should_remove_source_branch)" \
    "remove-source field-only mismatch diagnostic"
  assert_no_grep '--method POST' "$LOG" "conflicting remove-source retry created another merge request"

  reset_case
  out=$(FM_FAKE_MR_OMIT_SHOULD_REMOVE=true run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix --remove-source-branch 2>&1)
  rc=$?
  expect_code 1 "$rc" "unproven merge-request remove-source intent"
  assert_contains "$out" "(should_remove_source_branch)" \
    "missing remove-source intent diagnostic"
  assert_no_grep '--method POST' "$LOG" "unproven remove-source retry created another merge request"

  reset_case
  out=$(FM_FAKE_MR_OMIT_SQUASH_ON_MERGE=true FM_FAKE_MR_SQUASH=true \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix --squash) \
    || fail "legacy squash response should verify through the documented fallback"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "legacy-squash merge request was not reused"

  reset_case
  out=$(FM_FAKE_MR_SQUASH=false FM_FAKE_MR_SQUASH_ON_MERGE=false \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix --squash 2>&1)
  rc=$?
  expect_code 1 "$rc" "conflicting merge-request squash intent"
  assert_contains "$out" "(squash_on_merge)" "squash field-only mismatch diagnostic"
  assert_no_grep '--method POST' "$LOG" "conflicting squash retry created another merge request"

  reset_case
  out=$(FM_FAKE_MR_DESCRIPTION_FALSE=true run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "malformed empty merge-request description"
  assert_contains "$out" "(description)" "malformed description diagnostic"
  assert_no_grep '--method POST' "$LOG" "malformed description retry created another merge request"

  reset_case
  out=$(FM_FAKE_MR_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "stale merge-request retry head"
  assert_contains "$out" "does not match requested head and metadata" \
    "stale merge-request retry refusal"

  reset_case
  out=$(FM_FAKE_MR_AUTHOR=other run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "foreign-authored merge-request reuse"
  assert_contains "$out" "(author.id,author.username)" \
    "foreign-authored merge-request reuse refusal"
  assert_not_contains "$out" "mate" "authorship mismatch leaked authenticated username"
  assert_no_grep '--method POST' "$LOG" "foreign-authored candidate created another merge request"

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=none FM_FAKE_PROJECT_REMOVE_SOURCE_DEFAULT=true \
    FM_FAKE_MR_SHOULD_REMOVE_SOURCE=true FM_FAKE_MR_SQUASH_ON_MERGE=true \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix) \
    || fail "missing merge request should be created with project defaults preserved"
  [ "$(jq -r '.mr.already' <<< "$out")" = false ] || fail "new merge request reported reuse"
  assert_grep '--method POST --input - --header Content-Type: application/json' \
    "$LOG" "merge-request creation JSON media type"
  assert_grep 'input={"source_branch":"fm/fix","target_branch":"main","title":"Ship fix","description":""}' \
    "$LOG" "merge-request creation did not omit unrequested project-default options"

  reset_case
  printf 'Retry body\n\n' > "$REPO/mr-retry-body.md"
  out=$(FM_FAKE_MR_DESCRIPTION=$'Retry body\n\n' run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix --body-file "$REPO/mr-retry-body.md") \
    || fail "merge-request retry should preserve trailing body newlines"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "matching body retry was not reused"

  reset_case
  out=$(FM_FAKE_MR_DESCRIPTION='Retry body' run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix --body-file "$REPO/mr-retry-body.md" 2>&1)
  rc=$?
  expect_code 1 "$rc" "retry body trailing-newline mismatch"
  assert_contains "$out" "does not match requested head and metadata" \
    "retry body trailing-newline refusal"

  reset_case
  printf '\300\257' > "$REPO/mr-invalid-utf8.md"
  out=$(run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix \
    --body-file "$REPO/mr-invalid-utf8.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "malformed UTF-8 merge-request body"
  assert_contains "$out" "must contain valid UTF-8" "malformed UTF-8 body refusal"
  [ ! -s "$LOG" ] || fail "malformed UTF-8 body reached forge credentials"

  reset_case
  printf 'Interrupted body\n' > "$REPO/mr-interrupted-body.md"
  out=$(FM_FAKE_INTERRUPT_BODY=1 run_adapter mr-create "$REPO" \
    --title 'Ship fix' --source fm/fix --body-file "$REPO/mr-interrupted-body.md" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted body validation unexpectedly succeeded"
  if compgen -G "$REPO/.fm-forge-body.*" >/dev/null; then
    fail "interrupted body validation left a snapshot behind"
  fi

  reset_case
  printf 'Captured body\n\n' > "$REPO/mr-snapshot-body.md"
  out=$(FM_FAKE_MR_DESCRIPTION=$'Captured body\n\n' \
    FM_FAKE_REPLACE_BODY="$REPO/mr-snapshot-body.md" \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix \
      --body-file "$REPO/mr-snapshot-body.md") \
    || fail "merge-request retry should use the captured body snapshot"
  [ "$(jq -r '.mr.already' <<< "$out")" = true ] \
    || fail "captured body snapshot retry was not reused"

  reset_case
  printf 'Requested body\n\n' > "$REPO/mr-create-body.md"
  out=$(FM_FAKE_MR_LIST_SCENARIO=none FM_FAKE_MR_TITLE='Draft: Detailed fix' \
    FM_FAKE_MR_DESCRIPTION=$'Requested body\n\n' FM_FAKE_MR_DRAFT=true FM_FAKE_MR_REMOVE_SOURCE=true \
    FM_FAKE_MR_SQUASH=true FM_FAKE_MR_SQUASH_ON_MERGE=true \
    run_adapter mr-create "$REPO" --title 'Detailed fix' --source fm/fix \
      --body-file "$REPO/mr-create-body.md" --draft --remove-source-branch --squash) \
    || fail "requested merge-request metadata should verify after creation"
  [ "$(jq -r '.mr.already' <<< "$out")" = false ] \
    || fail "verified new merge request reported reuse"
  assert_grep '"description":"Requested body\n\n"' "$LOG" \
    "merge-request POST did not preserve trailing body newlines"
  assert_grep '"remove_source_branch":true,"squash":true' "$LOG" \
    "merge-request POST did not request source deletion and squash"

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=none \
    FM_FAKE_REMOTE_BRANCH_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "stale remote source branch head"
  assert_contains "$out" "does not match checked-out HEAD" "stale remote head refusal"
  assert_no_grep '--method POST' "$LOG" "stale remote head still created a merge request"

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=none FM_FAKE_MR_TITLE='Wrong read-back title' \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "created merge-request metadata mismatch"
  assert_contains "$out" "head and metadata verification mismatch" \
    "created merge-request metadata refusal"

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=none FM_FAKE_MR_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "created merge-request head mismatch"
  assert_contains "$out" "head and metadata verification mismatch" \
    "created merge-request head refusal"

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=none FM_FAKE_MR_AUTHOR=other \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "foreign-authored created merge request"
  assert_contains "$out" "(author.id,author.username)" \
    "foreign-authored created merge-request refusal"
  assert_not_contains "$out" "mate" "created authorship mismatch leaked authenticated username"

  reset_case
  out=$(FM_FAKE_MR_LIST_SCENARIO=none FM_FAKE_CREATED_MR_IDENTITY=fork \
    run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
  rc=$?
  expect_code 1 "$rc" "mismatched created merge request"
  assert_contains "$out" "created merge-request identity does not match" \
    "mismatched created merge-request refusal"

  for scenario in fork wrong_target ambiguous; do
    reset_case
    out=$(FM_FAKE_MR_LIST_SCENARIO="$scenario" \
      run_adapter mr-create "$REPO" --title 'Ship fix' --source fm/fix 2>&1)
    rc=$?
    expect_code 1 "$rc" "$scenario merge-request reuse"
    assert_no_grep '--method POST' "$LOG" "$scenario candidate still created a merge request"
  done
  pass "merge-request creation reuses only one exact trusted candidate"
}

test_lifecycle_rejects_mismatched_merge_request_identity() {
  local out rc
  reset_case
  out=$(FM_FAKE_MR_IDENTITY_SCENARIO=fork run_adapter mr-view "$REPO" 5 2>&1)
  rc=$?
  expect_code 1 "$rc" "fork merge-request view"
  assert_contains "$out" "identity does not match" "fork merge-request view refusal"

  reset_case
  out=$(FM_FAKE_MR_IDENTITY_SCENARIO=wrong_target run_adapter mr-checks "$REPO" 5 2>&1)
  rc=$?
  expect_code 1 "$rc" "wrong-target merge-request checks"
  assert_contains "$out" "identity does not match" "wrong-target checks refusal"

  reset_case
  out=$(FM_FAKE_MR_IDENTITY_SCENARIO=wrong_source run_adapter mr-merge "$REPO" 5 2>&1)
  rc=$?
  expect_code 1 "$rc" "wrong-source merge-request merge"
  assert_no_grep 'mr merge 5' "$LOG" "mismatched merge request invoked merge"

  reset_case
  : > "$MERGED_MARKER"
  out=$(FM_FAKE_MR_IDENTITY_SCENARIO=wrong_project \
    run_adapter mr-poll "$REPO" 'https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5') \
    || fail "mismatched merge-request poll should stay non-fatal"
  [ -z "$out" ] || fail "mismatched merge-request poll reported merged"
  pass "every merge-request lifecycle action verifies trusted identity"
}

test_checks_aggregate_without_dumping_successes() {
  local out
  reset_case
  out=$(FM_FAKE_PIPELINE_STATUS=failed run_adapter mr-checks "$REPO" 5) \
    || fail "failed checks should still return structured status"
  [ "$(jq -r '.checks.verdict' <<< "$out")" = failing ] || fail "failed verdict mismatch"
  [ "$(jq -r '.checks.failed' <<< "$out")" -eq 1 ] || fail "allowed failure counted as failure"
  [ "$(jq '.jobs | length' <<< "$out")" -eq 1 ] || fail "successful/allowed jobs should not bloat output"
  pass "pipeline checks are aggregated and only actionable jobs are returned"
}

test_transient_empty_pipeline_list_blocks_merge() {
  local out rc
  reset_case
  out=$(FM_FAKE_HEAD_PIPELINE=none FM_FAKE_PIPELINE_LIST=empty \
    run_adapter mr-checks "$REPO" 5) || fail "empty pipeline state should be inspectable"
  [ "$(jq -r '.checks.verdict' <<< "$out")" = pipeline_pending ] \
    || fail "empty pipeline state was not treated as pending"

  out=$(FM_FAKE_HEAD_PIPELINE=none FM_FAKE_PIPELINE_LIST=empty \
    run_adapter mr-merge "$REPO" 5 --method squash 2>&1)
  rc=$?
  expect_code 1 "$rc" "transient empty pipeline merge"
  assert_contains "$out" "pipeline is not ready (pipeline_pending)" \
    "transient empty pipeline refusal"
  assert_no_grep 'mr merge 5' "$LOG" "empty pipeline list still invoked merge"
  pass "an empty pipeline list remains pending during pipeline creation"
}

test_explicit_disabled_ci_allows_no_ci_merge() {
  local out
  reset_case
  out=$(FM_FAKE_HEAD_PIPELINE=none FM_FAKE_PIPELINE_LIST=empty \
    FM_FAKE_BUILDS_ACCESS_LEVEL=disabled run_adapter mr-checks "$REPO" 5) \
    || fail "explicit no-CI state should be inspectable"
  [ "$(jq -r '.checks.verdict' <<< "$out")" = no_ci ] \
    || fail "disabled project CI was not recognized"

  reset_case
  out=$(FM_FAKE_HEAD_PIPELINE=none FM_FAKE_PIPELINE_LIST=empty \
    FM_FAKE_BUILDS_ACCESS_LEVEL=disabled \
    run_adapter mr-merge "$REPO" 5 --method squash) \
    || fail "explicit no-CI project should merge"
  [ "$(jq -r '.mr.state' <<< "$out")" = merged ] || fail "no-CI merge was not verified"
  assert_grep 'mr merge 5' "$LOG" "explicit no-CI project did not invoke merge"
  pass "only an independently disabled CI feature authorizes a no-CI merge"
}

test_running_pipeline_blocks_merge() {
  local out rc
  reset_case
  out=$(FM_FAKE_PIPELINE_STATUS=running run_adapter mr-merge "$REPO" 5 --method squash 2>&1)
  rc=$?
  expect_code 1 "$rc" "running pipeline merge"
  assert_contains "$out" "pipeline is not ready (running)" "running pipeline refusal"
  assert_no_grep 'mr merge 5' "$LOG" "running pipeline still invoked merge"
  pass "a running GitLab pipeline blocks merge"
}

test_failing_pipeline_blocks_merge() {
  local out rc
  reset_case
  out=$(FM_FAKE_PIPELINE_STATUS=failed run_adapter mr-merge "$REPO" 5 --method squash 2>&1)
  rc=$?
  expect_code 1 "$rc" "failing pipeline merge"
  assert_contains "$out" "failing pipeline checks" "failing merge refusal"
  assert_no_grep 'mr merge 5' "$LOG" "failing checks still invoked merge"
  pass "a failing GitLab pipeline blocks merge"
}

test_stale_passing_pipeline_blocks_merge() {
  local out rc
  reset_case
  out=$(FM_FAKE_PIPELINE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_adapter mr-merge "$REPO" 5 --method squash 2>&1)
  rc=$?
  expect_code 1 "$rc" "stale passing pipeline merge"
  assert_contains "$out" "pipeline is not ready (stale_pipeline)" "stale pipeline refusal"
  assert_no_grep 'mr merge 5' "$LOG" "stale pipeline still invoked merge"
  pass "a passing pipeline for an older SHA cannot authorize merge"
}

test_merge_is_sha_pinned_and_verified() {
  local out
  reset_case
  out=$(FM_FAKE_PIPELINE_STATUS=success run_adapter mr-checks "$REPO" 5) \
    || fail "passing pipeline should be inspectable"
  [ "$(jq -r '.checks.verdict' <<< "$out")" = passing ] || fail "passing verdict mismatch"
  [ "$(jq -r '.pipeline.sha' <<< "$out")" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] \
    || fail "passing pipeline was not bound to the current merge-request SHA"

  reset_case
  out=$(FM_FAKE_PIPELINE_STATUS=success run_adapter mr-merge "$REPO" 5 --method squash --delete-branch) \
    || fail "passing MR should merge"
  assert_grep 'mr merge 5 --repo kisscut-museum/kisscut-platform --yes --auto-merge=false --sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --squash --remove-source-branch' \
    "$LOG" "merge was not project- and SHA-pinned"
  assert_grep 'token=unset' "$LOG" "merge inherited an ambient GitLab token"
  [ "$(jq -r '.mr.state' <<< "$out")" = merged ] || fail "merge result was not verified"
  pass "GitLab merge pins the reviewed head and verifies the merged state"
}

test_merge_requires_the_reviewed_sha() {
  local out rc
  reset_case
  out=$(FM_TEST_NO_DEFAULT_SHA=1 run_adapter mr-merge "$REPO" 5 --method squash 2>&1)
  rc=$?
  expect_code 2 "$rc" "merge without reviewed SHA"
  assert_contains "$out" "reviewed head SHA is required" "missing reviewed SHA refusal"
  assert_no_grep 'mr merge 5' "$LOG" "merge without reviewed SHA reached glab merge"

  reset_case
  out=$(FM_TEST_NO_DEFAULT_SHA=1 run_adapter mr-merge "$REPO" 5 --method squash \
    --sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)
  rc=$?
  expect_code 1 "$rc" "merge after reviewed head changed"
  assert_contains "$out" "does not match the reviewed SHA" "changed reviewed head refusal"
  assert_no_grep 'mr merge 5' "$LOG" "changed reviewed head reached glab merge"
  pass "GitLab merge requires and rechecks the reviewed head SHA"
}

test_checks_require_the_reviewed_sha() {
  local out rc
  reset_case
  out=$(run_adapter mr-checks "$REPO" 5 \
    --sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)
  rc=$?
  expect_code 1 "$rc" "checks after reviewed head changed"
  assert_contains "$out" "does not match the reviewed SHA" "changed-head checks refusal"
  pass "GitLab checks remain pinned to the reviewed head SHA"
}

test_nondefault_target_is_preserved_across_lifecycle() {
  local out
  reset_case
  out=$(FM_FAKE_TARGET_BRANCH=release run_adapter mr-view "$REPO" 5 --target release) \
    || fail "non-default target view should succeed"
  [ "$(jq -r '.mr.target_branch' <<< "$out")" = release ] || fail "view lost non-default target"

  reset_case
  out=$(FM_FAKE_TARGET_BRANCH=release run_adapter mr-find "$REPO" fm/fix --target release) \
    || fail "non-default target lookup should succeed"
  assert_grep 'target_branch=release' "$LOG" "lookup lost non-default target"

  reset_case
  FM_FAKE_TARGET_BRANCH=release run_adapter mr-checks "$REPO" 5 --target release >/dev/null \
    || fail "non-default target checks should succeed"

  reset_case
  FM_FAKE_TARGET_BRANCH=release run_adapter mr-merge "$REPO" 5 --target release --method squash >/dev/null \
    || fail "non-default target merge should succeed"

  out=$(FM_FAKE_TARGET_BRANCH=release run_adapter mr-poll "$REPO" \
    'https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5' --target release) \
    || fail "non-default target poll should succeed"
  [ "$out" = merged ] || fail "non-default target poll lost target identity"
  pass "non-default targets remain explicit through every lifecycle action"
}

test_poll_is_silent_until_merged() {
  local out
  reset_case
  out=$(run_adapter mr-poll "$REPO" 'https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5') \
    || fail "open MR poll should not fail"
  [ -z "$out" ] || fail "open MR poll should be silent"
  : > "$MERGED_MARKER"
  out=$(run_adapter mr-poll "$REPO" 'https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5') \
    || fail "merged MR poll should not fail"
  [ "$out" = merged ] || fail "merged MR poll did not emit exactly merged"
  pass "GitLab merge poll emits one line only after merge"
}

test_non_network_remote_is_rejected() {
  local local_repo out rc
  local_repo="$TMP/file-remote-repo"
  fm_git_init_commit "$local_repo"
  git -C "$local_repo" remote add origin 'file://gitlab.com/group/project'
  out=$(run_adapter repo "$local_repo" 2>&1)
  rc=$?
  expect_code 1 "$rc" "file GitLab-shaped remote"
  assert_contains "$out" "cannot be resolved safely" "file remote refusal"
  pass "local and unsupported remote schemes never select a credentialed forge"
}

test_malicious_remote_path_is_rejected() {
  local bad marker out rc
  bad="$TMP/bad-repo"
  marker="$TMP/remote-injection"
  fm_git_init_commit "$bad"
  git -C "$bad" remote add origin "git@gitlab.com:group/project;touch_${marker##*/}.git"
  out=$(run_adapter repo "$bad" 2>&1)
  rc=$?
  expect_code 1 "$rc" "unsafe remote path"
  assert_contains "$out" "cannot be resolved safely" "unsafe remote refusal"
  assert_absent "$marker" "unsafe remote path executed as shell"
  pass "unsafe remote text is rejected and never evaluated"
}

test_repo_identity_is_remote_derived
test_auth_targets_trusted_host
test_public_github_is_identified_without_credentials
test_registered_self_hosted_gitlab_is_explicit
test_unsupported_and_ambiguous_hosts_never_reach_credentials
test_issue_output_is_minimal_and_bounded
test_mr_url_must_match_origin
test_canonical_resource_urls_share_strict_validation
test_mr_body_file_cannot_read_outside_worktree
test_mr_find_requires_one_exact_project_and_branch_match
test_mr_create_reuses_only_one_exact_match
test_lifecycle_rejects_mismatched_merge_request_identity
test_checks_aggregate_without_dumping_successes
test_transient_empty_pipeline_list_blocks_merge
test_explicit_disabled_ci_allows_no_ci_merge
test_running_pipeline_blocks_merge
test_failing_pipeline_blocks_merge
test_stale_passing_pipeline_blocks_merge
test_merge_is_sha_pinned_and_verified
test_merge_requires_the_reviewed_sha
test_checks_require_the_reviewed_sha
test_nondefault_target_is_preserved_across_lifecycle
test_poll_is_silent_until_merged
test_non_network_remote_is_rejected
test_malicious_remote_path_is_rejected
