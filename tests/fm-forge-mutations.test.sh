#!/usr/bin/env bash
# Mutation and adversarial tests for the guarded GitLab forge adapter.
# The suite covers issue claim/status/comment/lifecycle flows, matching merge-
# request metadata flows, idempotence, identity checks, input validation, API
# failures, and deterministic post-mutation verification.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-forge-mutations-tests)
ADAPTER="$ROOT/bin/fm-forge.sh"
REPO="$TMP/repo"
FAKEBIN=$(fm_fakebin "$TMP")
LOG="$TMP/glab.log"
ISSUE_STATE="$TMP/issue.json"
MR_STATE="$TMP/mr.json"
ISSUE_NOTES="$TMP/issue-notes.json"
MR_NOTES="$TMP/mr-notes.json"
MUTATED="$TMP/mutated"

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
printf 'token=unset args=%s\n' "$*" >> "$FM_FAKE_GLAB_LOG"

case "${1:-} ${2:-}" in
  "auth status") [ "${FM_FAKE_AUTH_OK:-1}" = 1 ]; exit $? ;;
esac

issue_default() {
  local iid=${1:-7} owner labels state description
  owner=${FM_FAKE_ISSUE_OWNER:-self}
  labels=${FM_FAKE_ISSUE_LABELS:-'["bug"]'}
  state=${FM_FAKE_ISSUE_STATE:-opened}
  description=${FM_FAKE_ISSUE_DESCRIPTION:-Issue body}
  case "$owner" in
    self) owner='[{"id":42,"username":"mate"}]' ;;
    none) owner='[]' ;;
    other) owner='[{"id":77,"username":"rival"}]' ;;
    *) exit 90 ;;
  esac
  jq -cn --argjson iid "$iid" --arg state "$state" --arg description "$description" \
    --argjson labels "$labels" --argjson assignees "$owner" '
      {iid:$iid,project_id:314,title:"Fix cutter",state:$state,
       web_url:("https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/" + ($iid|tostring)),
       description:$description,labels:$labels,author:{id:7,username:"ivan"},
       assignees:$assignees,updated_at:"2026-07-18T00:00:00Z"}'
}

load_issue() {
  local iid=${1:-7}
  if [ ! -s "$FM_FAKE_ISSUE_STATE_FILE" ]; then
    issue_default "$iid" > "$FM_FAKE_ISSUE_STATE_FILE"
  fi
  jq --argjson iid "$iid" '
    .iid = $iid
    | .web_url = ("https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/" + ($iid|tostring))
  ' "$FM_FAKE_ISSUE_STATE_FILE"
}

save_issue_update() {
  local payload=$1 current add remove
  current=$(load_issue 7)
  add=$(jq -r '.add_labels // ""' <<< "$payload")
  remove=$(jq -r '.remove_labels // ""' <<< "$payload")
  jq -c --argjson payload "$payload" --arg add "$add" --arg remove "$remove" '
    .assignees = (if ($payload | has("assignee_ids")) then
      (if ($payload.assignee_ids | length) == 0 then [] else [{id:42,username:"mate"}] end)
      else .assignees end)
    | .labels = ((.labels
        - (if ($remove|length)>0 then ($remove|split(",")) else [] end)
        + (if ($add|length)>0 then ($add|split(",")) else [] end)) | unique)
    | .state = (if $payload.state_event == "close" then "closed"
        elif $payload.state_event == "reopen" then "opened" else .state end)
  ' <<< "$current" > "$FM_FAKE_ISSUE_STATE_FILE"
  : > "$FM_FAKE_MUTATED_MARKER"
}

mr_default() {
  local owner author labels state source target
  owner=${FM_FAKE_MR_OWNER:-none}
  author=${FM_FAKE_MR_AUTHOR:-self}
  labels=${FM_FAKE_MR_LABELS:-'["backend"]'}
  state=${FM_FAKE_MR_STATE:-opened}
  source=${FM_FAKE_MR_SOURCE:-fm/fix}
  target=${FM_FAKE_MR_TARGET:-main}
  case "$owner" in
    self) owner='[{"id":42,"username":"mate"}]' ;;
    none) owner='[]' ;;
    other) owner='[{"id":77,"username":"rival"}]' ;;
    *) exit 91 ;;
  esac
  case "$author" in
    self) author='{"id":42,"username":"mate"}' ;;
    other) author='{"id":77,"username":"rival"}' ;;
    *) exit 92 ;;
  esac
  jq -cn --arg state "$state" --arg source "$source" --arg target "$target" \
    --argjson labels "$labels" --argjson assignees "$owner" --argjson author "$author" '
      {iid:5,project_id:314,source_project_id:314,target_project_id:314,
       title:"Ship fix",state:$state,
       web_url:"https://gitlab.com/kisscut-museum/kisscut-platform/-/merge_requests/5",
       source_branch:$source,target_branch:$target,draft:false,
       merge_status:"can_be_merged",detailed_merge_status:"mergeable",
       sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",merge_commit_sha:null,
       labels:$labels,author:$author,assignees:$assignees,head_pipeline:null}'
}

load_mr() {
  if [ ! -s "$FM_FAKE_MR_STATE_FILE" ]; then
    mr_default > "$FM_FAKE_MR_STATE_FILE"
  fi
  if [ -e "$FM_FAKE_MUTATED_MARKER" ] && [ "${FM_FAKE_VERIFY_MISMATCH:-}" = changed-head ]; then
    jq '.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$FM_FAKE_MR_STATE_FILE"
  else
    cat "$FM_FAKE_MR_STATE_FILE"
  fi
}

save_mr_update() {
  local payload=$1 current add remove
  current=$(load_mr)
  add=$(jq -r '.add_labels // ""' <<< "$payload")
  remove=$(jq -r '.remove_labels // ""' <<< "$payload")
  jq -c --argjson payload "$payload" --arg add "$add" --arg remove "$remove" '
    .assignees = (if ($payload | has("assignee_ids")) then
      (if ($payload.assignee_ids | length) == 0 then [] else [{id:42,username:"mate"}] end)
      else .assignees end)
    | .labels = ((.labels
        - (if ($remove|length)>0 then ($remove|split(",")) else [] end)
        + (if ($add|length)>0 then ($add|split(",")) else [] end)) | unique)
    | .state = (if $payload.state_event == "close" then "closed"
        elif $payload.state_event == "reopen" then "opened" else .state end)
  ' <<< "$current" > "$FM_FAKE_MR_STATE_FILE"
  : > "$FM_FAKE_MUTATED_MARKER"
}

labels_catalog() {
  local labels target scenario
  labels='["bug","backend","docs","status::in-progress","status::blocked","status::deferred","ready-for-agent"]'
  target=${FM_FAKE_LABEL_NAME:-status::in-progress}
  scenario=${FM_FAKE_LABEL_SCENARIO:-ok}
  case "$scenario" in
    ok) jq -cn --argjson labels "$labels" '$labels | to_entries | map({id:(.key+1),name:.value,archived:false})' ;;
    missing) jq -cn --argjson labels "$labels" --arg target "$target" '$labels | map(select(. != $target)) | to_entries | map({id:(.key+1),name:.value,archived:false})' ;;
    archived) jq -cn --argjson labels "$labels" --arg target "$target" '$labels | to_entries | map({id:(.key+1),name:.value,archived:(.value == $target)})' ;;
    malformed) printf '%s\n' '[{"name":"bug"}]' ;;
    *) exit 93 ;;
  esac
}

note_object() {
  local type=$1 iid=$2 note_id=$3 body_json=$4
  jq -cn --arg type "$type" --argjson iid "$iid" --argjson id "$note_id" \
    --argjson body "$body_json" '
      {id:$id,body:$body,author:{id:42,username:"mate"},system:false,
       noteable_id:99,noteable_type:$type,project_id:314,noteable_iid:$iid,
       resolvable:false,confidential:false,internal:false}'
}

if [ "${1:-}" = api ]; then
  endpoint=${2:-}
  method=GET
  input=''
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
        [ "${args[$index]}" != - ] || input=$(cat)
        ;;
    esac
    index=$((index + 1))
  done
  [ -z "$input" ] || printf 'input=%s\n' "$input" >> "$FM_FAKE_GLAB_LOG"

  case "$endpoint" in
    user)
      printf '{"id":42,"username":"%s","state":"active","locked":false}\n' \
        "${FM_FAKE_USERNAME:-mate}"
      ;;
    projects/kisscut-museum%2Fkisscut-platform)
      printf '{"id":%s,"default_branch":"main","archived":%s,"builds_access_level":"enabled"}\n' \
        "${FM_FAKE_PROJECT_ID:-314}" "${FM_FAKE_PROJECT_ARCHIVED:-false}"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/labels\?*)
      [ "${FM_FAKE_API_FAIL:-}" != labels ] || exit 51
      labels_catalog
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues)
      [ "$method" = POST ] || exit 52
      [ "${FM_FAKE_API_FAIL:-}" != issue-create ] || exit 53
      labels=$(jq -r '.labels // ""' <<< "$input")
      jq -cn --argjson payload "$input" --arg labels "$labels" '
        {iid:8,project_id:314,title:$payload.title,state:"opened",
         web_url:"https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/8",
         description:($payload.description // ""),
         labels:(if ($labels|length)>0 then ($labels|split(",")) else [] end),
         author:{id:42,username:"mate"},
         assignees:(if ($payload.assignee_ids // [] | length)>0 then [{id:42,username:"mate"}] else [] end),
         updated_at:"2026-07-18T00:00:00Z"}' > "$FM_FAKE_ISSUE_STATE_FILE"
      if [ "${FM_FAKE_VERIFY_MISMATCH:-}" = create ]; then
        jq '.project_id=999' "$FM_FAKE_ISSUE_STATE_FILE" > "$FM_FAKE_ISSUE_STATE_FILE.tmp"
        mv "$FM_FAKE_ISSUE_STATE_FILE.tmp" "$FM_FAKE_ISSUE_STATE_FILE"
      fi
      cat "$FM_FAKE_ISSUE_STATE_FILE"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues/7|projects/kisscut-museum%2Fkisscut-platform/issues/8)
      iid=${endpoint##*/}
      if [ "$method" = PUT ]; then
        [ "${FM_FAKE_API_FAIL:-}" != issue-update ] || exit 54
        save_issue_update "$input"
        cat "$FM_FAKE_ISSUE_STATE_FILE"
      elif [ -e "$FM_FAKE_MUTATED_MARKER" ] && [ "${FM_FAKE_VERIFY_MISMATCH:-}" = issue-labels ]; then
        load_issue "$iid" | jq '.labels += ["surprise"]'
      elif [ -e "$FM_FAKE_MUTATED_MARKER" ] && [ "${FM_FAKE_VERIFY_MISMATCH:-}" = issue-owner ]; then
        load_issue "$iid" | jq '.assignees=[{id:77,username:"rival"}]'
      else
        load_issue "$iid"
      fi
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues/*/notes\?*)
      [ -s "$FM_FAKE_ISSUE_NOTES_FILE" ] && cat "$FM_FAKE_ISSUE_NOTES_FILE" || printf '%s\n' '[]'
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues/*/notes)
      [ "$method" = POST ] || exit 55
      [ "${FM_FAKE_API_FAIL:-}" != issue-note ] || exit 56
      note=$(note_object Issue 7 501 "$(jq -c '.body' <<< "$input")")
      jq -cn --argjson note "$note" '[$note]' > "$FM_FAKE_ISSUE_NOTES_FILE"
      printf '%s\n' "$note"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/issues/*/notes/501)
      note=$(jq -c '.[0]' "$FM_FAKE_ISSUE_NOTES_FILE")
      [ "${FM_FAKE_VERIFY_MISMATCH:-}" != note ] || note=$(jq '.author.id=77' <<< "$note")
      printf '%s\n' "$note"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5)
      if [ "$method" = PUT ]; then
        [ "${FM_FAKE_API_FAIL:-}" != mr-update ] || exit 57
        save_mr_update "$input"
        cat "$FM_FAKE_MR_STATE_FILE"
      else
        load_mr
      fi
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5/notes\?*)
      [ -s "$FM_FAKE_MR_NOTES_FILE" ] && cat "$FM_FAKE_MR_NOTES_FILE" || printf '%s\n' '[]'
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5/notes)
      [ "$method" = POST ] || exit 58
      [ "${FM_FAKE_API_FAIL:-}" != mr-note ] || exit 59
      note=$(note_object MergeRequest 5 601 "$(jq -c '.body' <<< "$input")")
      jq -cn --argjson note "$note" '[$note]' > "$FM_FAKE_MR_NOTES_FILE"
      printf '%s\n' "$note"
      ;;
    projects/kisscut-museum%2Fkisscut-platform/merge_requests/5/notes/601)
      note=$(jq -c '.[0]' "$FM_FAKE_MR_NOTES_FILE")
      [ "${FM_FAKE_VERIFY_MISMATCH:-}" != note ] || note=$(jq '.author.id=77' <<< "$note")
      printf '%s\n' "$note"
      ;;
    *)
      printf 'unexpected fake API endpoint: %s (%s)\n' "$endpoint" "$method" >&2
      exit 60
      ;;
  esac
  exit 0
fi

printf 'unexpected fake glab call: %s\n' "$*" >&2
exit 61
SH
chmod +x "$FAKEBIN/glab"

run_adapter() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_GLAB_LOG="$LOG" \
    FM_FAKE_ISSUE_STATE_FILE="$ISSUE_STATE" \
    FM_FAKE_MR_STATE_FILE="$MR_STATE" \
    FM_FAKE_ISSUE_NOTES_FILE="$ISSUE_NOTES" \
    FM_FAKE_MR_NOTES_FILE="$MR_NOTES" \
    FM_FAKE_MUTATED_MARKER="$MUTATED" \
    FM_FORGE_HOSTS_FILE="${FM_FORGE_HOSTS_FILE:-}" \
    GITLAB_TOKEN=AMBIENT GITLAB_ACCESS_TOKEN=AMBIENT OAUTH_TOKEN=AMBIENT \
    GLAB_ENABLE_CI_AUTOLOGIN=true CI_JOB_TOKEN=AMBIENT \
    "$ADAPTER" "$@"
}

reset_case() {
  : > "$LOG"
  rm -f "$ISSUE_STATE" "$MR_STATE" "$ISSUE_NOTES" "$MR_NOTES" "$MUTATED"
}

count_log() {
  local pattern=$1
  grep -c -- "$pattern" "$LOG" 2>/dev/null || true
}

test_issue_create_claim_and_canonical_view() {
  local body out
  reset_case
  body="$REPO/issue-body.md"
  printf 'Created safely.\n' > "$body"
  out=$(run_adapter issue-create "$REPO" --title 'New cutter issue' \
    --body-file "$body" --label bug --claim) || fail "claimed issue creation should succeed"
  [ "$(jq -r '.issue.iid' <<< "$out")" -eq 8 ] || fail "created issue IID mismatch"
  [ "$(jq -r '.issue.assignees[0]' <<< "$out")" = mate ] || fail "created issue was not self-assigned"
  jq -e '.issue.labels == ["bug","status::in-progress"]' <<< "$out" >/dev/null \
    || fail "created issue labels mismatch"
  out=$(run_adapter issue-view "$REPO" \
    'https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/8') \
    || fail "canonical created issue URL should resolve"
  [ "$(jq -r '.issue.url' <<< "$out")" = \
    'https://gitlab.com/kisscut-museum/kisscut-platform/-/issues/8' ] \
    || fail "canonical issue read-back mismatch"
  pass "issue creation validates labels, optional claim, identity, and canonical read-back"
}

test_issue_claim_status_note_close_reopen_and_release() {
  local note out before
  reset_case
  note="$REPO/issue-note.md"
  printf 'Worker update.\n' > "$note"
  out=$(FM_FAKE_ISSUE_OWNER=none \
    FM_FAKE_ISSUE_LABELS='["bug","status::blocked","ready-for-agent"]' \
    run_adapter issue-claim "$REPO" 7) || fail "issue claim should succeed"
  jq -e '.issue.assignees == ["mate"] and .issue.labels == ["bug","status::in-progress"]' \
    <<< "$out" >/dev/null || fail "claim did not establish exact owner/status"

  out=$(run_adapter issue-status "$REPO" 7 --status blocked) || fail "blocked transition should succeed"
  jq -e '.issue.labels == ["bug","status::blocked"]' <<< "$out" >/dev/null \
    || fail "blocked status mismatch"
  out=$(run_adapter issue-status "$REPO" 7 --status deferred) || fail "deferred transition should succeed"
  jq -e '.issue.labels == ["bug","status::deferred"]' <<< "$out" >/dev/null \
    || fail "deferred status mismatch"
  out=$(run_adapter issue-status "$REPO" 7 --status in-progress) \
    || fail "in-progress transition should succeed"
  jq -e '.issue.labels == ["bug","status::in-progress"]' <<< "$out" >/dev/null \
    || fail "in-progress status mismatch"

  out=$(run_adapter issue-note "$REPO" 7 --body-file "$note") || fail "issue note should succeed"
  [ "$(jq -r '.note.already' <<< "$out")" = false ] || fail "first issue note reported reuse"
  out=$(run_adapter issue-note "$REPO" 7 --body-file "$note") || fail "issue note retry should succeed"
  [ "$(jq -r '.note.already' <<< "$out")" = true ] || fail "issue note retry duplicated content"
  [ "$(count_log '/issues/7/notes --hostname.*--method POST')" -eq 1 ] \
    || fail "issue note retry posted more than once"

  out=$(run_adapter issue-close "$REPO" 7) || fail "issue close should succeed"
  [ "$(jq -r '.issue.state' <<< "$out")" = closed ] || fail "issue did not close"
  before=$(count_log 'input={"state_event":"close"}')
  run_adapter issue-close "$REPO" 7 >/dev/null || fail "already-closed issue should be idempotent"
  [ "$(count_log 'input={"state_event":"close"}')" -eq "$before" ] \
    || fail "already-closed issue was mutated again"
  out=$(run_adapter issue-reopen "$REPO" 7) || fail "issue reopen should succeed"
  [ "$(jq -r '.issue.state' <<< "$out")" = opened ] || fail "issue did not reopen"

  out=$(run_adapter issue-release "$REPO" 7 --status deferred) || fail "issue release should succeed"
  jq -e '.issue.assignees == [] and .issue.labels == ["bug","status::deferred"]' \
    <<< "$out" >/dev/null || fail "release did not verify unassignment/status"
  before=$(count_log 'input={"assignee_ids":\[\]')
  run_adapter issue-release "$REPO" 7 --status deferred >/dev/null \
    || fail "already-released issue should be idempotent"
  [ "$(count_log 'input={"assignee_ids":\[\]')" -eq "$before" ] \
    || fail "already-released issue was mutated again"
  pass "issue claim, status, note, close, reopen, and release converge safely"
}

test_issue_already_correct_and_custom_labels_are_idempotent() {
  local out
  reset_case
  out=$(FM_FAKE_ISSUE_LABELS='["bug","status::in-progress"]' \
    run_adapter issue-claim "$REPO" 7) || fail "already-correct claim should succeed"
  [ "$(count_log '--method PUT')" -eq 0 ] || fail "already-correct claim performed a mutation"
  out=$(run_adapter issue-status "$REPO" 7 --status in-progress) \
    || fail "already-correct status should succeed"
  [ "$(count_log '--method PUT')" -eq 0 ] || fail "already-correct status performed a mutation"
  out=$(run_adapter issue-labels "$REPO" 7 --add docs --remove bug) \
    || fail "custom issue labels should update"
  jq -e '.issue.labels == ["docs","status::in-progress"]' <<< "$out" >/dev/null \
    || fail "custom issue labels did not preserve workflow status"
  run_adapter issue-labels "$REPO" 7 --add docs --remove bug >/dev/null \
    || fail "custom issue label retry should succeed"
  [ "$(count_log 'input={"add_labels":"docs","remove_labels":"bug"}')" -eq 1 ] \
    || fail "custom issue label retry mutated twice"
  pass "already-correct issue claims, statuses, and label deltas are no-ops"
}

test_issue_release_ready_preserves_unrelated_labels() {
  local out
  reset_case
  out=$(FM_FAKE_ISSUE_LABELS='["bug","status::in-progress"]' \
    run_adapter issue-release "$REPO" 7 --status ready) \
    || fail "ready release should succeed"
  jq -e '.issue.assignees == [] and .issue.labels == ["bug","ready-for-agent"]' \
    <<< "$out" >/dev/null || fail "ready release did not preserve unrelated labels"
  pass "issue release can return self-owned work to the ready queue without clobbering labels"
}

test_issue_ownership_conflicts_stop_before_mutation() {
  local out rc
  reset_case
  out=$(FM_FAKE_ISSUE_OWNER=other run_adapter issue-claim "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "claiming another user's issue"
  assert_contains "$out" "refusing to steal ownership" "ownership conflict refusal"
  assert_no_grep '--method PUT' "$LOG" "ownership conflict still mutated issue"

  reset_case
  out=$(FM_FAKE_ISSUE_OWNER=other run_adapter issue-status "$REPO" 7 --status blocked 2>&1)
  rc=$?
  expect_code 1 "$rc" "status on another user's issue"
  assert_contains "$out" "not owned exactly" "status ownership refusal"
  assert_no_grep '--method PUT' "$LOG" "foreign-owned issue status still mutated"
  pass "issue mutations cannot steal or bypass exact ownership"
}

test_missing_archived_and_malformed_labels_stop_before_mutation() {
  local out rc
  reset_case
  out=$(FM_FAKE_ISSUE_OWNER=none FM_FAKE_LABEL_SCENARIO=missing \
    run_adapter issue-claim "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "claim with missing status label"
  assert_contains "$out" "does not exist: status::in-progress" "missing label refusal"
  assert_no_grep '--method PUT' "$LOG" "missing label still mutated issue"

  reset_case
  out=$(FM_FAKE_LABEL_SCENARIO=archived FM_FAKE_LABEL_NAME=docs \
    run_adapter issue-labels "$REPO" 7 --add docs 2>&1)
  rc=$?
  expect_code 1 "$rc" "archived custom label"
  assert_contains "$out" "label is archived: docs" "archived label refusal"

  reset_case
  out=$(FM_FAKE_LABEL_SCENARIO=malformed run_adapter issue-labels "$REPO" 7 --add docs 2>&1)
  rc=$?
  expect_code 1 "$rc" "malformed label catalog"
  assert_contains "$out" "catalog is malformed" "malformed catalog refusal"
  pass "missing, archived, and malformed label metadata blocks mutations"
}

test_malformed_targets_labels_and_files_are_rejected() {
  local outside symlink empty out rc before
  reset_case
  outside="$TMP/outside.md"
  symlink="$REPO/symlink.md"
  empty="$REPO/empty.md"
  printf 'outside\n' > "$outside"
  ln -s "$outside" "$symlink"
  : > "$empty"
  before=$(wc -l < "$LOG")
  for target in 0 'https://attacker.example/kisscut-museum/kisscut-platform/-/issues/7'; do
    out=$(run_adapter issue-view "$REPO" "$target" 2>&1)
    rc=$?
    expect_code 1 "$rc" "malformed issue target $target"
  done
  [ "$(wc -l < "$LOG")" -eq "$before" ] || fail "malformed issue target reached credentials"

  out=$(run_adapter issue-labels "$REPO" 7 --add 'bad,label' 2>&1)
  rc=$?
  expect_code 2 "$rc" "comma label"
  out=$(run_adapter issue-labels "$REPO" 7 --add status::blocked 2>&1)
  rc=$?
  expect_code 2 "$rc" "workflow label through generic command"
  assert_contains "$out" "must use issue-claim" "workflow label ownership refusal"

  for file in "$outside" "$symlink"; do
    out=$(run_adapter issue-note "$REPO" 7 --body-file "$file" 2>&1)
    rc=$?
    expect_code 2 "$rc" "unsafe note file $file"
  done
  out=$(run_adapter issue-note "$REPO" 7 --body-file "$empty" 2>&1)
  rc=$?
  expect_code 2 "$rc" "empty issue note"

  reset_case
  out=$(FM_FAKE_USERNAME='bad user' run_adapter issue-claim "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "malformed authenticated username"
  assert_contains "$out" "user identity is unavailable" "malformed username refusal"
  assert_no_grep '--method PUT' "$LOG" "malformed username still mutated issue"
  pass "malformed targets, labels, usernames, and non-regular note files are rejected"
}

test_untrusted_project_and_api_failures_stop_safely() {
  local out rc
  reset_case
  out=$(FM_FAKE_PROJECT_ARCHIVED=true run_adapter issue-claim "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "archived project mutation"
  assert_contains "$out" "project is archived" "archived project refusal"
  assert_no_grep '--method PUT' "$LOG" "archived project still mutated"

  reset_case
  out=$(FM_FAKE_PROJECT_ID=999 run_adapter issue-view "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "mismatched project identity"
  assert_contains "$out" "identity does not match" "project identity refusal"

  reset_case
  out=$(FM_FAKE_ISSUE_OWNER=none FM_FAKE_API_FAIL=issue-update \
    run_adapter issue-claim "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "issue update API failure"
  assert_contains "$out" "issue claim failed" "issue API failure report"

  reset_case
  printf 'API failure note.\n' > "$REPO/api-failure-note.md"
  out=$(FM_FAKE_API_FAIL=issue-note run_adapter issue-note "$REPO" 7 \
    --body-file "$REPO/api-failure-note.md" 2>&1)
  rc=$?
  expect_code 1 "$rc" "issue note API failure"
  assert_contains "$out" "issue note failed" "issue note API failure report"
  pass "untrusted projects and API failures never report a successful mutation"
}

test_post_mutation_verification_mismatch_is_reported() {
  local out rc
  reset_case
  out=$(FM_FAKE_ISSUE_OWNER=none FM_FAKE_VERIFY_MISMATCH=issue-labels \
    run_adapter issue-claim "$REPO" 7 2>&1)
  rc=$?
  expect_code 1 "$rc" "issue label verification mismatch"
  assert_contains "$out" "status verification mismatch" "issue verification mismatch report"

  reset_case
  printf 'Verify note.\n' > "$REPO/verify-note.md"
  out=$(FM_FAKE_VERIFY_MISMATCH=note run_adapter issue-note "$REPO" 7 \
    --body-file "$REPO/verify-note.md" 2>&1)
  rc=$?
  expect_code 1 "$rc" "issue note verification mismatch"
  assert_contains "$out" "note verification mismatch" "note verification mismatch report"
  pass "issue and note mutations require deterministic matching read-back"
}

test_merge_request_metadata_lifecycle_and_notes() {
  local out before
  reset_case
  printf 'MR update.\n' > "$REPO/mr-note.md"
  out=$(FM_FAKE_MR_LABELS='["backend","status::blocked","ready-for-agent"]' \
    run_adapter mr-claim "$REPO" 5) || fail "merge-request claim should succeed"
  jq -e '.mr.assignees == ["mate"] and .mr.labels == ["backend","status::in-progress"]' \
    <<< "$out" >/dev/null || fail "merge-request claim mismatch"
  before=$(count_log 'input={"assignee_ids":\[42\],"add_labels":"status::in-progress"')
  run_adapter mr-claim "$REPO" 5 >/dev/null || fail "merge-request claim retry should succeed"
  [ "$(count_log 'input={"assignee_ids":\[42\],"add_labels":"status::in-progress"')" -eq "$before" ] \
    || fail "merge-request claim retry mutated twice"

  out=$(run_adapter mr-status "$REPO" 5 --status blocked) \
    || fail "merge-request blocked status should succeed"
  jq -e '.mr.labels == ["backend","status::blocked"]' <<< "$out" >/dev/null \
    || fail "merge-request blocked status mismatch"
  out=$(run_adapter mr-status "$REPO" 5 --status deferred) \
    || fail "merge-request deferred status should succeed"
  jq -e '.mr.labels == ["backend","status::deferred"]' <<< "$out" >/dev/null \
    || fail "merge-request deferred status mismatch"

  out=$(run_adapter mr-labels "$REPO" 5 --add docs --remove backend) \
    || fail "merge-request labels should update"
  jq -e '.mr.labels == ["docs","status::deferred"]' <<< "$out" >/dev/null \
    || fail "merge-request labels mismatch"
  out=$(run_adapter mr-note "$REPO" 5 --body-file "$REPO/mr-note.md") \
    || fail "merge-request note should succeed"
  [ "$(jq -r '.note.already' <<< "$out")" = false ] || fail "first MR note reported reuse"
  out=$(run_adapter mr-note "$REPO" 5 --body-file "$REPO/mr-note.md") \
    || fail "merge-request note retry should succeed"
  [ "$(jq -r '.note.already' <<< "$out")" = true ] || fail "MR note retry duplicated content"

  out=$(run_adapter mr-close "$REPO" 5) || fail "merge-request close should succeed"
  [ "$(jq -r '.mr.state' <<< "$out")" = closed ] || fail "merge request did not close"
  out=$(run_adapter mr-reopen "$REPO" 5) || fail "merge-request reopen should succeed"
  [ "$(jq -r '.mr.state' <<< "$out")" = opened ] || fail "merge request did not reopen"
  out=$(run_adapter mr-release "$REPO" 5 --status ready) \
    || fail "merge-request release should succeed"
  jq -e '.mr.assignees == [] and .mr.labels == ["docs","ready-for-agent"]' <<< "$out" >/dev/null \
    || fail "merge-request release did not converge metadata"
  pass "merge-request claim, status, labels, notes, lifecycle, and release converge safely"
}

test_merge_request_workflow_labels_require_guarded_commands() {
  local out rc
  reset_case
  out=$(run_adapter mr-labels "$REPO" 5 --add status::blocked 2>&1)
  rc=$?
  expect_code 2 "$rc" "generic merge-request workflow label update"
  assert_contains "$out" "workflow label must use" "merge-request workflow label refusal"
  assert_no_grep '--method PUT' "$LOG" "generic merge-request workflow label still mutated"
  pass "merge-request workflow labels require status and release commands"
}

test_merge_request_identity_author_branch_and_head_guards() {
  local out rc
  reset_case
  out=$(FM_FAKE_MR_AUTHOR=other run_adapter mr-labels "$REPO" 5 --add docs 2>&1)
  rc=$?
  expect_code 1 "$rc" "metadata update on another author's merge request"
  assert_contains "$out" "author is not authenticated user" "merge-request author refusal"
  assert_no_grep '--method PUT' "$LOG" "foreign-authored merge request still mutated"

  reset_case
  out=$(FM_FAKE_MR_SOURCE=fm/other run_adapter mr-close "$REPO" 5 2>&1)
  rc=$?
  expect_code 1 "$rc" "wrong source branch merge request"
  assert_contains "$out" "identity does not match" "source branch identity refusal"

  reset_case
  out=$(run_adapter mr-note "$REPO" \
    'https://attacker.example/kisscut-museum/kisscut-platform/-/merge_requests/5' \
    --body-file "$REPO/mr-note.md" 2>&1)
  rc=$?
  expect_code 1 "$rc" "foreign merge-request URL"
  assert_contains "$out" "does not match the repository origin" "MR URL refusal"

  reset_case
  out=$(FM_FAKE_VERIFY_MISMATCH=changed-head run_adapter mr-labels "$REPO" 5 --add docs 2>&1)
  rc=$?
  expect_code 1 "$rc" "head changed during MR mutation"
  assert_contains "$out" "head changed during metadata mutation" "MR head verification refusal"

  reset_case
  out=$(FM_FAKE_API_FAIL=mr-update run_adapter mr-labels "$REPO" 5 --add docs 2>&1)
  rc=$?
  expect_code 1 "$rc" "MR update API failure"
  assert_contains "$out" "label update failed" "MR API failure report"

  reset_case
  printf 'MR API failure note.\n' > "$REPO/mr-api-failure-note.md"
  out=$(FM_FAKE_API_FAIL=mr-note run_adapter mr-note "$REPO" 5 \
    --body-file "$REPO/mr-api-failure-note.md" 2>&1)
  rc=$?
  expect_code 1 "$rc" "MR note API failure"
  assert_contains "$out" "merge-request note failed" "MR note API failure report"
  pass "merge-request mutations preserve project, author, branch, head, and API guards"
}

test_issue_create_and_note_failures_are_verified() {
  local out rc
  reset_case
  printf 'Create body.\n' > "$REPO/create-body.md"
  out=$(FM_FAKE_VERIFY_MISMATCH=create run_adapter issue-create "$REPO" \
    --title 'Create mismatch' --body-file "$REPO/create-body.md" --label bug 2>&1)
  rc=$?
  expect_code 1 "$rc" "created issue identity mismatch"
  assert_contains "$out" "identity" "created issue verification refusal"

  reset_case
  out=$(FM_FAKE_API_FAIL=issue-create run_adapter issue-create "$REPO" \
    --title 'Create failure' --label bug 2>&1)
  rc=$?
  expect_code 1 "$rc" "issue creation API failure"
  assert_contains "$out" "issue creation failed" "issue creation failure report"
  pass "issue creation and comments surface API and verification failures"
}

test_issue_create_claim_and_canonical_view
test_issue_claim_status_note_close_reopen_and_release
test_issue_already_correct_and_custom_labels_are_idempotent
test_issue_release_ready_preserves_unrelated_labels
test_issue_ownership_conflicts_stop_before_mutation
test_missing_archived_and_malformed_labels_stop_before_mutation
test_malformed_targets_labels_and_files_are_rejected
test_untrusted_project_and_api_failures_stop_safely
test_post_mutation_verification_mismatch_is_reported
test_merge_request_metadata_lifecycle_and_notes
test_merge_request_workflow_labels_require_guarded_commands
test_merge_request_identity_author_branch_and_head_guards
test_issue_create_and_note_failures_are_verified
