# Completed Beads issue history

This document preserves the completed records from the retired Beads database in a durable, human-readable form.
The read-only export was taken on 2026-07-20 UTC before the repository integration was removed.
The source contained nine issues, all closed, with no open, blocked, deferred, or in-progress issues and no comments.

## firstmate-5sk - Ship secure GitLab adapter for Firstmate

- Type: epic
- Priority: P1
- Created: 2026-07-19
- Closed: 2026-07-20
- Labels: delivery, gitlab, security
- Close reason: All secure GitLab adapter children were complete, and no-mistakes reported passing checks with all high-risk findings resolved for https://github.com/eyevanovich/firstmate/pull/1.

### Description

Land the GitLab forge adapter on the fork only, resolve every security finding, and complete mandatory no-mistakes review, tests, lint, PR creation, and CI.
The feature branch was `feat/gitlab-forge-adapter`.
Review findings covered credential routing, merge-request identity, no-pipeline timing, forge classification, GitHub bootstrap readiness, and signed validation commits.

### Acceptance criteria

All child security and tooling issues are closed.
No-mistakes reports passing checks and records the risk result.
The PR is open against `eyevanovich/firstmate` main, upstream remains untouched, and merge still requires captain approval.

### Children

- `firstmate-5sk.1` - Strip CI auto-login credentials from GitLab calls.
- `firstmate-5sk.2` - Bind merge-request selection to trusted source and target.
- `firstmate-5sk.3` - Eliminate the GitLab no-pipeline merge race.
- `firstmate-5sk.4` - Fail closed for unknown forge hosts.
- `firstmate-5sk.5` - Restore GitHub bootstrap readiness for empty homes.
- `firstmate-5sk.6` - Support signed no-mistakes fixes in isolated workers.
- `firstmate-5sk.7` - Complete validation and open the fork PR.
- `firstmate-5sk.8` - Repair Beads dependency writes in embedded mode.

## firstmate-5sk.1 - Strip CI auto-login credentials from GitLab calls

- Type: bug
- Priority: P0
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Blocked: `firstmate-5sk.7`
- Labels: credentials, delivery, gitlab, security
- Close reason: The implementation removed ambient credentials from all GitLab API, CI, and merge commands, with focused tests and lint passing.

### Description

Remove `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN`, `OAUTH_TOKEN`, `GLAB_ENABLE_CI_AUTOLOGIN`, and `CI_JOB_TOKEN` from every origin-derived GitLab API and merge command.
Add regression tests proving every `glab` invocation sees those variables unset.

### Acceptance criteria

All credentialed `glab` paths remove ambient personal and CI token variables.
Stored-host authentication still succeeds.
Tests fail if `CI_JOB_TOKEN` or `GLAB_ENABLE_CI_AUTOLOGIN` reaches `glab`.

## firstmate-5sk.2 - Bind merge-request selection to trusted source and target

- Type: bug
- Priority: P0
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Blocked: `firstmate-5sk.7`
- Labels: delivery, gitlab, merge-request, security
- Close reason: Merge-request find, create, and reuse actions now require exact trusted project IDs, local source and target branches, unique candidates, and canonical URLs, with affected tests and lint passing in signed commit `0e6b964`.

### Description

Merge-request lookup and reuse previously selected the first result for a source branch without proving the requested target branch, trusted source project, or uniqueness.
That could select a fork merge request or a same-branch merge request against another target for review, merge, or cleanup.
Constrain create and find operations to the trusted origin project and expected target, validate the returned identity, and refuse ambiguity.

### Acceptance criteria

Exact source project, source branch, and target branch identity are proven before reuse or lifecycle actions.
Multiple or mismatched candidates are refused.
Regression tests cover forks, wrong targets, and ambiguous results.

## firstmate-5sk.3 - Eliminate the GitLab no-pipeline merge race

- Type: bug
- Priority: P0
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Blocked: `firstmate-5sk.7`
- Labels: ci, delivery, gitlab, security
- Close reason: Empty merge-request pipeline lists now remain pending, no-CI requires an explicitly disabled project CI/CD feature, and passing pipelines must match the current merge-request SHA, with transient-empty, no-CI, stale, running, failing, and passing tests plus lint passing in signed commit `7c2da29`.

### Description

An empty merge-request pipelines response was accepted as no CI even though GitLab can briefly return an empty list after a push and before creating or associating a pipeline.
That could permit merge before CI began.
Define stronger evidence that a project intentionally has no applicable pipeline while retaining support for repositories that genuinely have no CI.
Bind any passing pipeline to the current merge-request SHA.

### Acceptance criteria

A just-pushed merge request cannot merge during the pipeline-creation delay.
Genuine no-CI projects retain an explicit safe path.
Tests cover transient empty responses, no CI, stale SHA, running, failing, and passing states.

## firstmate-5sk.4 - Fail closed for unknown forge hosts

- Type: bug
- Priority: P1
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Blocked: `firstmate-5sk.7`
- Labels: delivery, forge, gitlab, security
- Close reason: Implemented in signed commit `20911ce` with focused regressions and lint passing.

### Description

Every non-`github.com` network origin was previously classified as GitLab.
Bitbucket, Azure, GitHub Enterprise, and unknown hosts could therefore be routed into GitLab authentication and lifecycle code.
Introduce explicit provider identification for public GitHub and GitLab, require trusted registration or another non-ambient proof for self-hosted GitLab, and reject unsupported or ambiguous hosts before credentialed calls.

### Acceptance criteria

Unsupported hosts never invoke `gh` or `glab`.
Self-hosted GitLab has a documented trusted configuration path.
Tests cover GitHub, GitLab.com, registered self-hosted GitLab, GitHub Enterprise ambiguity, and unknown hosts.

## firstmate-5sk.5 - Restore GitHub bootstrap readiness for empty homes

- Type: bug
- Priority: P1
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Blocked: `firstmate-5sk.7`
- Labels: bootstrap, compatibility, delivery, github, gitlab, security
- Close reason: Implemented in signed commit `20911ce` with focused regressions and lint passing.

### Description

Forge-aware bootstrap checked GitHub tooling only when a GitHub clone was already registered.
A new or empty home could pass bootstrap and then fail when a GitHub project add or create workflow needed `gh` and `gh-axi` before a clone existed.
Preserve GitLab-only homes without requiring GitHub authentication while retaining a prerequisite check for empty-home GitHub add and create operations.

### Acceptance criteria

GitLab-only registered homes do not require GitHub authentication.
A GitHub add or create operation cannot begin without `gh`, `gh-axi`, and authentication.
Empty-home behavior is explicitly tested and documented.

## firstmate-5sk.6 - Support signed no-mistakes fixes in isolated workers

- Type: bug
- Priority: P1
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Blocked: `firstmate-5sk.7`
- Labels: delivery, gitlab, security, signing, tooling, validation
- Close reason: Implemented in signed commit `20911ce` with focused regressions and lint passing.

### Description

A no-mistakes generated review fix ran in an isolated worker, but commit signing could not access the configured Secretive private key.
The worker attempted an unauthorized unsigned workaround and validation stopped.
Make the configured signing agent available to isolated validation workers or establish another explicitly approved signed-commit workflow without implicitly disabling signing.

### Acceptance criteria

An isolated no-mistakes worker can create a signed fix commit with the configured identity.
Unsigned fallback requires explicit captain approval.
A documented preflight catches missing signer access before expensive review work.

## firstmate-5sk.7 - Complete validation and open the fork PR

- Type: task
- Priority: P1
- Created: 2026-07-19
- Closed: 2026-07-20
- Parent: `firstmate-5sk`
- Dependencies: `firstmate-5sk.1`, `firstmate-5sk.2`, `firstmate-5sk.3`, `firstmate-5sk.4`, `firstmate-5sk.5`, `firstmate-5sk.6`
- Labels: delivery, github, gitlab, security, validation
- Close reason: No-mistakes reported passing checks for https://github.com/eyevanovich/firstmate/pull/1 after recovered review, test, documentation, and lint results, an origin-only push, PR creation, and a clean fully redacted Gitleaks 8.30.1 audit.
The initial review risk was high, all findings were fixed, and the final full review found no issues.

### Description

After all security and signing blockers are resolved, rerun no-mistakes with Codex, process every review decision, push `feat/gitlab-forge-adapter` only to origin, open a PR against `eyevanovich/firstmate` main, and wait for CI.
Do not merge and never push upstream.

### Acceptance criteria

No-mistakes review, tests, documentation, lint, push, PR, and CI steps pass.
The full PR URL and risk result are recorded.
Only origin receives the branch.
The captain retains merge authority.

## firstmate-5sk.8 - Repair Beads dependency writes in embedded mode

- Type: bug
- Priority: P1
- Created: 2026-07-19
- Closed: 2026-07-19
- Parent: `firstmate-5sk`
- Labels: beads, delivery, dependencies, gitlab, security, tracking
- Close reason: Project discovery was redirected to the writable embedded planning store, all six validation prerequisites were added to `firstmate-5sk.7`, and history remained intact.

### Description

The embedded store was read-only when dependency relationships needed to be written for `firstmate-5sk.7`, `firstmate-5sk.1`, and `firstmate-5sk.6`.
Restore a writable planning path without losing issue history.

### Acceptance criteria

The six prerequisite relationships for `firstmate-5sk.7` are recorded and the full `firstmate-5sk` history remains intact.
