# GitHub Project Tracking

`GitHubConnector` projects GitHub work into Desk and a bounded digest.
The default `contributions` mode tracks the authenticated contributor's
authored PRs and issues linked from their PR bodies. An explicit `repository`
mode provides a broader repository view.

## Durable state

Paths are relative to the running app's data root:

| Path | Purpose |
|---|---|
| `connectors/github/tracking.json` | Mode, contributor, selected repositories and refresh configuration |
| `connectors/github/tracking_snapshot.json` | Cached entity projection, detail timestamps and material signatures |
| `workshop/github_command/ops.jsonl` and `ops_base.json` | GitHub watcher's durable state |

Contribution scope uses the authenticated login. An explicit repository list
replaces the previous selection and clears the discovery query. Configuration
must name a valid mode and a contributor for contribution tracking.

Desk matches entities by reference kind, repository and number, reusing existing
items. Open in-scope entities become current work; closed PRs remain snapshot
history. Cleanup archives only tracker-shaped `.gh` items owned by the prior
snapshot that have left scope. A degraded repository refresh preserves its
prior entities instead of treating them as deleted.

## Tool surface

Use `app {"find":"GitHub"}` to discover the current actions and arguments.

| Action | Purpose |
|---|---|
| `github.status` | Connection status |
| `github.search` | Qualified GitHub search |
| `github.track` | Discover/configure tracking; persists by default |
| `github.digest` | Read or refresh the tracked project digest |
| `github.mutate` | Issue/PR mutations through the normal policy path |

Call an action as `app {"action":"github.status"}`; supply its arguments in
`args`. `AppActionRegistry.swift` and `ToolNameAliases.swift` own this mapping.

`GitHubToolProjection.swift` bounds ordinary collections to 20 rows, issue/PR
bodies to 1,000 characters, comments to 1,200 and diff hunks to 600.
Full Mac follows the shared origin-aware authority rules; peer-steered GitHub
mutations still require User's approval unless the authenticated agent is enabled
in Trust → Connected agents. Enabled agents carry User's authority; ordinary
Trust and domain checks still apply. See [Threat model](threat-model.md).

## Refresh and noise policy

`GitHubTrackingBackgroundWork` is event/deadline driven. Tracking config and
snapshot, Desk operations and GitHub Command operations wake a coalesced reread.
The connector supplies the next refresh deadline; the six-hour periodic
registration repairs missed events. The configured interval is bounded to
5–1,440 minutes, defaulting to 5.

Contribution refresh rechecks authorship. Closing/reference clauses such as
`Fixes #12` or `Refs owner/repo#12` add linked issues; casual issue mentions
do not. Every open authored PR enters the mergeability probe before cached
detail can be reused. Missing, unknown, conflicting or changed mergeability
forces detail. Pending checks and expired detail also prevent reuse.

New external, non-bot PR conversation comments are considered after the prior
detail boundary, avoiding a replay of historical comments. Maintainer review
gates are classified separately from technical failures and unexplained
aggregate failures.

New Desk items default to digest notifications with a six-hour cooldown.
The separate `GitHubCommandRuntime` watcher can claim a deduplicated notification
through `AttentionRouter` for actionable work. It records watcher state and
updates Desk; it does not start or resume Codex, provider calls or repository work.

## Verification

For a small installed check, inspect `app {"action":"github.status"}` and
the configured digest. Changing tracking scope or forcing a network refresh is
an explicit action; inspect the returned scope and result. A status or cached
digest read is not proof that an external mutation succeeded.

Implementation: `Modules/NativeAgentCore/Sources/GitHubConnector/`,
`BackgroundWork/GitHubTrackingBackgroundWork.swift` and the app's
`BackgroundLoopsAssembly+GitHubTracking.swift`.
