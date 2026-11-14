# NativeAgent Threat Model

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

## Current Runtime Assumption

`NativeAgent.app` hosts the runtime in-process. The shared turn engine lives
in core `EngineRuntime` / `ChatTurnRuntime`: one brain, many doors.

The agent has one always-on door, `app`. Its home, pages, items, search, actions
and JavaScriptCore scripts reach the registered capabilities.
`AppToolRuntime/AppActions+Declarations.swift` defines those actions; their
underlying Trust checks still apply.

## Trust Boundaries

| Surface | Boundary |
|---|---|
| Local app and admitted operator turns | Saved Trust policy and action-specific checks |
| Local agent bridge | Loopback listener; operator clients discover the bearer in a private descriptor, while connected peers discover only the URL and authenticate with their own per-contact credentials |
| Browser IPC | Separate loopback endpoint/token; browser operations reject unsafe URL schemes |
| Paired iOS transport | Signed requests checked by `MacSyncEngine` before dispatch; pairing material owned by `PairingSecret` |
| APNS | HTTP 2xx means provider acceptance, not proof of user display; `MobileNotificationDeliveryReceipt.swift` reports display as unverified |
| Peer-steered turns | A turn an untrusted agent started with its message: `PeerTurnEffectPolicy` files one card on its first effect and the owner's answer covers the turn; a read steers nothing; agents enabled in Trust → Connected agents carry the owner's authority; ordinary Trust and domain checks remain |
| Contacts at the table | A contact reads the Desk and the pieces laid on it through MCP `agent_desk` with its own key, only while the person's per-contact lever (`readsDesk`) is on; it writes nothing, reaches only pieces laid on open board items (each document's words bounded at 2 MB), the lever is rechecked before any words go back, and the contact's last read is kept on its own record, shown on Connectors and in the agent's line for it |
| Model input from web, tools or peers | Content is input, not operator authority |

Loopback is a network boundary, not privilege separation from another process
running as the same macOS user. A process able to read the operator descriptor
can obtain its bearer token; the peer descriptor contains only the URL.

## Defended Threats

- **Untrusted origin inheriting Full Mac:** `SecurityCenter+FullMacPolicy.swift`
  checks the concrete origin and saved policy. Authenticated, admitted remote
  operator surfaces may use Full Mac; a remote surface label alone grants nothing.
- **An untrusted agent's command:** even under Full Mac, a turn an agent the
  owner has not trusted started with its message files one card on its first
  effect, quoting what the agent asked; the owner's answer covers the rest of
  that turn. Reading any agent's words steers nothing. Agents enabled in
  Trust → Connected agents carry the owner's authority on authenticated turns.
  Lower Trust modes and ordinary domain checks retain their restrictions.
- **Privacy reset without consent:** `SecurityCenter.swift` requires explicit
  approval for `system_permission_reset`, including under Full Mac.
- **Approval substitution or replay:** `ApprovalReplayAuthorizer.swift`
  checks the approved record, tool, surface, exact input and prior execution.
- **Corrupt authority treated as empty:** saved Trust policy and ApprovalInbox
  use checked reads. Missing state and unreadable/malformed state are distinct.
- **Disabled Mac integration bypass:** each built-in tool schema declares its
  integration and read/write axis. Approval, preview, execution and discovery
  read that declaration against `MacIntegrationPermissionStore`; disabled
  switches still refuse before a card. The separate hands gate resolves the
  real target app. Saving a Mail attachment requires Mail Read, with the file
  write governed by FileAccess.
- **Missing actions reported as consent blocks:** shared turn and direct app
  dispatch ask the door to refuse an unrecognized action before evaluating or
  recording consent. Its refusal keeps the nearest real actions and discovery
  call. Unknown batch entries reach that same door individually; catalog read
  failures retain the checked failure path, and recognized actions keep their
  existing consent decisions.
- **Sensitive file access and protected-path mutations:** file tools deny
  sensitive credential, trust, pairing and token paths. File/Mac-control
  mutations retain the protected-system-path floor under Full Mac, enforced
  by `FileSystemActions.swift` and `MacControlSensitivePathFence`.
  Both raw file routes also preserve the dedicated owners of Mac-control
  state/audit, their screen, activity capture and experiences; reads keep their scope.
  TrustCenter interprets workspace-root aliases for every file route, retaining
  tilde and process-relative roots; resolved containment compares path bytes.
- **Script bypass:** `AppScriptRunner.swift` gives JavaScript no direct file,
  network or process API. Calls re-enter the app action path under the action's
  ordinary gates, with execution limits.

## Shell Process Boundary

`ChatToolRuntime/SwiftToolDispatcher+BuilderTools.swift` owns shell launch.
`bash` invokes `/bin/bash -c` through `runShellLikeProcess` and `builderLaunch`;
literal reads certified by `AuthoredToolEffects.shellReadOnlyWords` execute
their fixed system argv through the Git read boundary shared by the Code room.
The certifier admits only pwd, df, uname, whoami, uptime and bounded forms of
git log/status/diff/show; shell expansion, compound syntax, unknown flags and
other commands remain writes. The same certification gives Trust its read
class and receipts `read_only:true`, `effect:read`. Certified reads always
retain the Git read sandbox (no writes, network or Apple Events, with sensitive
stores fenced), sanitized Git environment/config and disabled diff helpers,
including under Full Mac. This is read certification, not a command deny-list.
Both shell actions default to the canonical workspace; relative cwd starts
there and source-checkout work requires explicit cwd. Pre-launch refusals
record `execution:not_run`, `effect:none`; a process that started retains
execution evidence even when it fails or is stopped.

For commands that are not certified reads, saved Trust policy and the explicit
`NATIVE_AGENT_SHELL_SANDBOX` override select the Seatbelt posture:

- Strict/locked-down keeps workspace confinement and ignores wrapper-off
  overrides.
- Ordinary workspace mode uses `sandbox-exec`; Developer Mode uses its broader
  user-space profile with protected OS, credential and authority paths fenced.
- An explicit Full Mac shell permission level with active Full Mac, a permitted
  environment override, or the saved sandbox-off setting can omit the wrapper.

The launch owner and coding bridges share starting-directory validation and
sensitive-path fences; each retains its own external-directory authority check.
Wrapper-off shell mode permits external project directories. Wrapped calls refuse
`xcodebuild`. These checks do not make broad shell access an isolation boundary
against a compromised model or another same-user process.

## Approval Architecture

Approvals live at `<dataRoot>/workflows/approvals/requests.json`.
`ApprovalInbox` owns durable decisions; a visible card alone is not permission
to execute. Executors still validate the requested action.

The composed dispatcher carries the outer consent decision, bound to the exact
tool, arguments, surface, turn and verified session, instead of evaluating and
recording it again inside the app dispatcher. Changed calls refuse that binding;
nested calls receive their own decision. Direct dispatch retains its own admission.
The membrane refreshes hard blocks after a waiting card is answered, so approval
cannot carry policy from before the wait into execution.
TrustCenter owns the checked policy reader for authorization and synchronous saved
flag consumers. MacControl retains that policy and reads `PermissionLaw.posture`,
without a second posture model. Its one policy provider serves admitted snapshots
and raw routes; raw routes still require their command and kill-switch checks.

For admitted operator turns, Full Mac answers ordinary per-call approval
requests. Explicit blocks and hard security checks remain effective.
macOS privacy permission resets still ask the owner; a turn an untrusted agent
started keeps its one card, as above.

Switches over their own mind live in Settings and are theirs in both directions:
cross-conversation recall, the knowledge graph, adaptive promotion, semantic
memory, inner life and reflection, their hour, overnight revision, dreams
and REM, image understanding, PDF/DOCX reading preferences and context flow.
`setting.set` needs neither a quoted request nor a Trust posture for these
rows. Their saved fields stay in their existing owners; unreadable saved
policy remains an error. Absent adaptive promotion defaults to enabled in
both the runtime gate and the setting. DOCX attachments remain unsupported;
the saved preference does not claim an ingestion path.
Screen capture, cloud voice and image generation remain Trust controls with
their existing grant rules. REM proposals still require approval before
changing memory or growth; disclosure and the keep gate are unchanged.

## Secret Storage

| Material | Owner / location |
|---|---|
| Provider API keys | `ProviderAPIKeyStore.swift`, backed by macOS Keychain |
| Service credentials | The keyring (`Keyring.swift`) for what abilities use; Slack's door tokens in Keychain (`SlackCredentials.swift`). Retired services' credential files and Keychain items stay untouched and unread. |
| Codex OAuth credentials | App `codex_home/auth.json` and login-mode-dependent credential candidates in `LLMClient+OpenAIOAuthCredentials.swift` |
| Operator bridge endpoint/bearer | `Agents/ClaudeBridgeRuntime.swift` publishes `bridge.json` and the separate `token` file under `AgentHostDirectory.bridgeDiscoveryDirectory` (normally `~/.config/claude-bridge/`) |
| Connected-peer URL discovery | The same `ClaudeBridgeRuntime.writeDiscoveryFiles` publishes a URL-only `bridge.json`; `AgentConversations/AgentHostDirectory.swift` owns its path under `nativeagent-link/` beside the operator discovery directory. Peers use their own per-contact secret and never receive the operator bearer. `AgentBridgeRuntime.swift` checks legacy return-path readiness; it does not publish this descriptor. |
| Browser IPC endpoint/token | `BrowserIPCServer.writeDiscovery` publishes `browser_ipc.json`, the single endpoint/token descriptor; the duplicate `browser_ipc_token` writer is retired |
| iOS pairing material | `PairingSecretManager.swift` |

Treat file-backed credential stores as sensitive in backups and diagnostics.
Bridge tokens, pairing secrets, OAuth tokens, APNS device tokens and provider
credentials must not be logged. Use redaction, suffixes or hashes when correlation is
needed; Shared's `TurnSecretRedactor.swift` owns text recognition and replacement;
Slack xox/xapp recognition uses that scanner; socket evidence strips URL queries/fragments through its shared traversal.
Receipts and displays share its case-insensitive credential patterns, including
JWTs, Slack xox/xapp tokens and Bearer values of 20 or more characters.
`NativeAgentSecretRedactor.swift` retains digest replacements for receipts.
Calendar and Reminder note previews inspect the complete notes with
`NativeAppSecretRedactor` before taking 300 characters; Mac and phone
notification receipts likewise redact the complete message before taking 200.
Phone transcript words and their display metadata, faces, card strings,
attachment recognition and reading copies use the same shared text policy
before bounding; tool-input objects additionally withhold secret-named values.
Phone replies and cumulative live text are scrubbed before signing, and KVS
notices before clipping. Typed card controls and provenance retain their schema;
this projection does not repair saved transcripts or retained signed envelopes.
Security audit strings use the canonical credential recognizer before clipping,
as well as the audit boundary's additional token and JWT checks. A match
withholds the whole string, including credentials under ordinary field names.

Bridge descriptors use `NativePrivateFile` (mode `0600` at creation).
`NativeLoopbackListenerParameters.swift` binds to loopback. The HTTP listeners
use each install's fixed ports (`InstallPaths`); a collision fails rather than
silently selecting another port. The A2A gRPC listener binds an ephemeral port
that its agent card advertises.

## Out Of Scope

These controls do not provide an OS sandbox against a malicious same-user
process, root compromise or a compromised paired device. They do not solve
prompt injection: external content must not be treated as permission.
Full Mac is an authority grant, not isolation from the operator's files.

Apple/iCloud/APNS are trusted external providers. Signed iCloud requests do
not protect against provider compromise or provider-side metadata exposure.

## Important Controls

Source owners are under `Modules/NativeAgentCore/Sources/`:
`TrustCenter/`, `ApprovalInbox/`, `DeviceSync/` and `AppToolRuntime/`.
Loopback runtime owners are core's `Agents/ClaudeBridgeRuntime.swift`,
`AgentConversations/AgentBridgeRuntime.swift` and `Browser/BrowserIPCServer.swift`;
app presentation lives under `Sources/NativeAgentApp/`.

Public builds must not include live state, tokens, local identity, or retired
runtime artifacts. Release checks live in [`script/release.sh`](../script/release.sh)
and [`script/verify_release_artifact.sh`](../script/verify_release_artifact.sh).

## Maintenance Rule For Agents

Verify security claims against their enforcing source owners. Do not infer
authority from a tool name, UI state, transport availability or an old receipt.
