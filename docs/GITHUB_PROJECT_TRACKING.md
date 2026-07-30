# GitHub Project Tracking

NativeAgent's GitHub project view is a Swift-native capability owned by the
`GitHubConnector` target. Its default, explicit `contributions` mode turns one
authenticated contributor's authored PRs and the issues linked from their
PR bodies into durable Desk refs/items and a bounded chat digest; it is not a
script, a second task store, or an always-loaded prompt body.

## Durable state

- `data/connectors/github/tracking.json` is the versioned scope, contributor,
  repository selection, and cadence configuration. Repositories are resolved
  through the connected account and stored as canonical `owner/name` records.
  The contributor login must match the authenticated account. Neither a login
  nor a repository slug is compiled into the app. Passing an explicit
  repository list replaces the prior set and clears any discovery query.
- `data/connectors/github/tracking_snapshot.json` is a rebuildable cache of the
  latest bounded entity projection and material signatures. Open authored PRs
  and open keyword-linked issues are current entities; closed authored PRs and
  linked issues are retained as snapshot history but are not current Desk work. It drives
  change-only digests, cleanup ownership, and refresh throttling.
- Desk remains the personal tracking truth. GitHub issues and PRs are matched by
  `(ref kind, repository, number)` and upserted with `gh_issue` / `gh_pr` refs.
  The first refresh is the backfill/migration: open in-scope entities without a
  matching Desk ref become items; existing matching refs are reused and never
  duplicated. On later refreshes, tracker-shaped `.gh` items owned by the prior
  snapshot but absent from current scope are canceled and archived. Non-GitHub
  Desk data is never part of that cleanup boundary.

Both tracking files use `SwiftNativePersistenceCore` atomic writes under the
path flock. Version 2 requires an explicit mode and, for contribution mode, a
persisted contributor login. Legacy or invalid configurations fail closed and
ask for discovery rather than guessing an account, scope, or repository.

## Tool surface

The GitHub group is lazy-loaded. It includes repository/issue reads, qualified
search, PR list/detail, bounded changed files and patches, comments/reviews/
timeline activity, configurable tracking discovery, the concise project digest,
and one mutation executor.

`GitHubToolProjection` is the provider boundary for ordinary reads. Collection
actions return at most 20 compact rows, issue/PR/review bodies are excerpted to
1,000 characters, comments to 1,200, and diff hunks to 600. Nested GitHub API
objects that duplicate users/repositories or carry unrelated URLs are removed.
The project digest reports exact category counts while sampling at most 10 rows
from each changed/new/needs-attention/blocked/stale category. A shared tool-loop
backstop additionally replaces any GitHub result over 12,000 UTF-8 bytes with a
valid JSON head/tail projection and instructions to narrow or paginate. Direct
bridge tool diagnostics can still inspect the compact connector envelope; only
the model-facing block receives the final ceiling.

An explicit `tool_load` updates the persisted session loadout and the current
structured turn: newly authorized schemas are appended before the next provider
iteration in both streaming and non-streaming chat. The model does not need a
second user message or repeated catalog calls to use the loaded GitHub tool.

`github_mutate` supports issue and PR creation/update/comment/close/reopen,
review submission, reviewer requests, and merge. It is exact-name `confirm` in
the shipped TrustCenter defaults and is excluded from Full Mac/yolo elevation.
The dispatcher can execute it only after the normal chat approval/policy path
allows the exact tool call and payload. `/codex/tool` has no approval filer, so
direct bridge mutation probes fail closed. The connector never reads an
approval file or weakens policy itself.

## Refresh and noise policy

`BackgroundLoopsManager` owns the `github_tracking` runner. The manager offers a
five-minute tick, while the persisted configuration enforces a 5–1,440 minute
network cadence (15 minutes by default). With no config or before the due time,
the tick performs no GitHub request.

Contribution refresh uses GitHub's qualified issue search for PRs authored by
the configured login in each configured repository (up to ten 100-row pages),
then defensively rechecks the returned author. Every open authored PR is
expanded for current review/check state. Only `Fixes`, `Closes`, `Resolves`, or
`Refs` clauses in authored PR bodies can add linked issues; arbitrary issue
rows and casual `#N` mentions never enter scope. An explicit `repository` mode
retains the bounded whole-repository view for callers who intentionally request
it. PR file patches are separately paginated and capped at 80,000 characters by
default (250,000 hard maximum). HTTP failures are typed and rate-limit errors
include remaining/reset metadata without headers or tokens. Tracking snapshots
are the cache; repeated background ticks inside the configured interval are
local no-ops.

Only material signatures (state, update time, review state, CI, mergeability,
User-needed, blocked, and stale flags) update existing Desk items. New tracked
items default to `digest` notification policy with a six-hour cooldown. No
direct OS notification is enabled by tracking itself. The chat digest reports:

- changed and newly seen entities;
- authored PRs that need the contributor because CI failed or changes were
  requested, plus linked issues assigned to that contributor;
- failed CI or requested-changes blockers;
- stale open work;
- one recommended next action.

CI normalization is failure-dominant across check runs and the combined commit
status. Otherwise, a non-empty GitHub combined status is the authoritative
required-check rollup: `success` reports `passing` even if an optional check run
is still queued, while `pending` remains `pending`. GitHub's default `pending`
state for a zero-status legacy collection is ignored. When no real combined
rollup exists, the individual Check Runs determine `passing`, `pending`,
`failed`, or `none`.

## Verification

Focused checks:

```bash
swift test --package-path Modules/NativeAgentCore --filter github --no-parallel
swift build --jobs 4
./script/check_architecture_blueprint.swift --repo .
```

Installed proof should use the authenticated bridge: list the live GitHub tool
catalog, call `github_status`, configure tracking with
`github_discover_tracking` using `mode=contributions`, an authenticated
`contributor_login`, and an explicit repository list; refresh
`github_project_digest`, then call a harmless
`github_mutate` request through `/codex/tool` and verify it is rejected before
network execution because that bridge has no approval filer.

The July 10 installed proof used one configured upstream repository and its
authenticated contributor. A fresh chat turn loaded `github_search` once,
called it on the next provider iteration, and returned 20 of 36 open authored
PRs with `perPage=20`; provider input stayed `8,495 -> 9,083 -> 10,890`. The
forced durable refresh recorded 36 open authored PRs, 11 closed PR history
rows, 45 linked issues, and 76 open in-scope Desk items. Seventy-four rows from
the earlier unfiltered import were already archived with explicit
scope-correction receipts, while 17 non-GitHub live Desk items remained intact.
