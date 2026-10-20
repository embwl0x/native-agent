# NativeAgent Threat Model

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

## Current Runtime Assumption

`NativeAgent.app` hosts the runtime in-process. The shared turn engine lives
in core `EngineRuntime` / `ChatTurnRuntime`: one brain, many doors.

Agent has one always-on tool, `app`. Its home, pages, items, search, actions
and JavaScriptCore scripts reach the registered capabilities.
`AppToolRuntime/AppActionRegistry.swift` defines those actions; their
underlying Trust checks still apply.

## Trust Boundaries

| Surface | Boundary |
|---|---|
| Local app and admitted operator turns | Saved Trust policy and action-specific checks |
| Local agent bridge | Loopback listener and bearer authentication; endpoint/token discovery in a private descriptor |
| Browser IPC | Separate loopback endpoint/token; browser operations reject unsafe URL schemes |
| Paired iOS transport | Signed requests checked by `MacSyncEngine` before dispatch; pairing material owned by `PairingSecretManager` |
| APNS | HTTP 2xx means provider acceptance, not proof of user display; `SwiftNativeAPNS.swift` reports display as unverified |
| Peer-steered turns | A turn an untrusted agent started with its message: `PeerTurnEffectPolicy` files one card on its first effect and the owner's answer covers the turn; a read steers nothing; agents enabled in Trust → Connected agents carry the owner's authority; ordinary Trust and domain checks remain |
| Model input from web, tools or peers | Content is input, not operator authority |

Loopback is a network boundary, not privilege separation from another process
running as the same macOS user. A process able to read the descriptor can obtain
its bearer token.

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
- **Script bypass:** `AppScriptRunner.swift` gives JavaScript no direct file,
  network or process API. Calls re-enter the app action path under the action's
  ordinary gates, with execution limits.

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
| GitHub PAT and OAuth credentials | `GitHubCredentialStore.swift`, backed by macOS Keychain |
| Provider API keys | `ProviderAPIKeyStore.swift`, backed by macOS Keychain |
| Connector OAuth and API credentials | Device-bound Keychain references for supported connectors (`ConnectorCredentialFile.swift`); remaining file-backed stores under `providers/`, `oauth_tokens/` and `connectors/<id>/auth.json` at mode `0600`; see `Connectors+Auth.swift` and `OAuthCredentialDestinations.swift` |
| Codex OAuth credentials | App `codex_home/auth.json` and login-mode-dependent credential candidates in `LLMClient+OpenAIOAuthCredentials.swift` |
| Local agent bridge endpoint/token | `ClaudeBridgeRuntime.swift` publishes the Claude lane's `bridge.json`; `AgentBridgeRuntime.swift` publishes the agent bridge's descriptor under `~/.config/nativeagent-link/` |
| Browser IPC endpoint/token | `BrowserWindow.swift` publishes `browser_ipc.json` |
| iOS pairing material | `PairingSecretManager.swift` |

Treat file-backed credential stores as sensitive in backups and diagnostics;
GitHub's Keychain storage does not cover other credentials. Bridge tokens,
pairing secrets, OAuth tokens, APNS device tokens and provider credentials
must not be logged. Use redaction, suffixes or hashes when correlation is
needed; `NativeAgentSecretRedactor.swift` and `TurnSecretRedactor.swift` own
shared redaction rules.

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
The loopback listeners and bridge presentation live under
`Sources/NativeAgentApp/`.

Public builds must not include live state, tokens, local identity, or retired
runtime artifacts. Release checks live in [`script/release.sh`](../script/release.sh)
and [`script/verify_release_artifact.sh`](../script/verify_release_artifact.sh).

## Maintenance Rule For Agents

Verify security claims against their enforcing source owners. Do not infer
authority from a tool name, UI state, transport availability or an old receipt.
