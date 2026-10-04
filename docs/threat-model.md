# NativeAgent Threat Model

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
| Peer-steered turns | `PeerTurnEffectPolicy` adds owner approval for protected effects, except for authenticated agents enabled in Trust → Connected agents; ordinary Trust and domain checks remain |
| Model input from web, tools or peers | Content is input, not operator authority |

Loopback is a network boundary, not privilege separation from another process
running as the same macOS user. A process able to read the descriptor can obtain
its bearer token.

## Defended Threats

- **Untrusted origin inheriting Full Mac:** `SecurityCenter+FullMacPolicy.swift`
  checks the concrete origin and saved policy. Authenticated, admitted remote
  operator surfaces may use Full Mac; a remote surface label alone grants nothing.
- **Peer-driven protected effects:** even under Full Mac, peer turns card User
  for deletes/irreversible acts, sends in their name, persona writes and approval
  actions. Authenticated turns from agents enabled in Trust → Connected agents
  carry User's authority and skip extra peer approvals. Lower Trust modes and
  ordinary domain checks retain their restrictions.
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
  network or process API. Calls re-enter the app action path, with execution
  limits and the action's scriptability check.

## Approval Architecture

Approvals live at `<dataRoot>/workflows/approvals/requests.json`.
`ApprovalInbox` owns durable decisions; a visible card alone is not permission
to execute. Executors still validate the requested action.

For admitted operator turns, Full Mac answers ordinary per-call approval
requests. Explicit blocks and hard security checks remain effective.
macOS privacy permission resets still ask the owner; peer turns retain the
protected-effect rules above.

## Secret Storage

| Material | Owner / location |
|---|---|
| GitHub PAT and OAuth credentials | `GitHubCredentialStore.swift`, backed by macOS Keychain |
| Other provider/connector OAuth and API credentials | App data under `providers/`, `oauth_tokens/`, `connectors/<id>/auth.json`, or provider-specific stores; see `Connectors+Auth.swift` and `OAuthCredentialDestinations.swift` |
| Codex OAuth credentials | App `codex_home/auth.json` and login-mode-dependent credential candidates in `LLMClient+OpenAIOAuthCredentials.swift` |
| Local agent bridge endpoint/token | `ClaudeBridge.swift` publishes its `bridge.json` descriptor |
| Browser IPC endpoint/token | `BrowserWindow.swift` publishes `browser_ipc.json` |
| iOS pairing material | `PairingSecretManager.swift` |

Treat file-backed credential stores as sensitive in backups and diagnostics;
GitHub's Keychain storage does not cover other credentials. Bridge tokens,
pairing secrets, OAuth tokens, APNS device tokens and provider credentials
must not be logged. Use redaction, suffixes or hashes when correlation is
needed; `NativeAgentSecretRedactor.swift` and `TurnSecretRedactor.swift` own
shared redaction rules.

Bridge descriptors use `NativePrivateFile` (mode `0600` at creation).
`NativeLoopbackListenerParameters.swift` binds to loopback. Each install uses
fixed ports; a collision fails rather than silently selecting another port.

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
