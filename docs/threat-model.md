# NativeAgent Threat Model

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

## Current Runtime Assumption

`NativeAgent.app` hosts the runtime in-process. The shared turn engine lives
in core `EngineRuntime` / `ChatTurnRuntime`: one brain, many doors.

The agent has one always-on tool, `app`. Its home, pages, items, search, actions
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

For admitted operator turns, Full Mac answers ordinary per-call approval
requests. Explicit blocks and hard security checks remain effective.
macOS privacy permission resets still ask the owner; a turn an untrusted agent
started keeps its one card, as above.

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
