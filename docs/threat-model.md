# NativeAgent Threat Model

_Last updated: 2026-07-11_

## Current Runtime Assumption

NativeAgent is a Swift-native macOS app. `NativeAgent.app` owns the live runtime in-process: chat orchestration, tool dispatch, memory, scheduler loops, policy, approvals, iCloud sync, APNS, local bridges, and app UI.

There is no live external interpreter backend, bundled interpreter runtime, launchd-owned runtime, or approval state outside the Swift app. Historical external-runtime names appear only in compatibility vocabulary, old audit notes, cleanup checks, or legacy wire/model names.

## Trust Boundaries

| Caller or Surface | Trust Level | Authentication / Gate |
|---|---:|---|
| Local Swift app UI | High | Same-process user action plus app policy gates |
| Local chat and local agent bridge | High local trust | Loopback-only listener preferring `127.0.0.1:8771`; collision fallback endpoint and bearer token are published together mode `0600` |
| Browser IPC window | Narrow local trust | Loopback-only listener with a separate descriptor-published endpoint/token; URL scheme allow-list and navigation serialization |
| Paired iOS app | Remote paired trust | HMAC-signed action/message envelopes over iCloud KVS + Drive or entitlement-gated CloudKit private records |
| APNS | Delivery provider | Apple APNS accepts notification requests; HTTP 2xx means provider acceptance, not proof of user display |
| Telegram/Slack/connectors | External account trust | Connector-specific OAuth/token proof plus NativeAgent policy/action gates |
| Browser/web content | Untrusted | No direct app control without explicit browser IPC/tool path and token gate |

Loopback access is not a sandbox. A process already running as the same macOS user can often read local app data or reach loopback surfaces if it has the right token. NativeAgent treats this as single-user local trust and focuses on preventing remote, browser, iCloud, and connector-originated misuse.

## Defended Threats

- **Unpaired iOS or iCloud injection**: iOS-to-Mac chat/action envelopes are signed on both device transports. The Mac rejects envelopes whose HMAC does not match the current pairing secret, and action responses must match the expected message/action identity.
- **Replay and stale-response confusion**: signed action paths use message ids, transaction metadata, processed-id tracking, and response matching so old responses cannot satisfy a different current action.
- **Local bridge token leakage in logs**: bridge tokens, pairing secrets, OAuth tokens, APNS tokens, and provider credentials must not be logged. Logs should use suffixes or hashes only when identity correlation is needed.
- **Browser/web cross-control**: browser content is untrusted. NativeAgent's browser IPC is loopback-token gated and rejects non-http(s) navigation schemes.
- **Sensitive local file exposure through tools**: file tools deny app data subtrees containing OAuth tokens, pairing secrets, provider credentials, trust policy, and related secret-bearing state.
- **Remote Mac-control escalation**: iOS/Telegram/bridge-originated Mac control and write-capable actions go through the unified policy gates. Remote surfaces do not inherit silent local shell/process auto from a local Full Mac/Developer posture.
- **MCP/process lifecycle abuse**: MCP lifecycle and subprocess-style actions require explicit policy and receipts rather than being hidden side effects.
- **Approval orphaning**: approval records are durable files under app data. Resolvers must fail closed on stale/missing/orphaned records rather than executing an action because a UI row exists.
- **Release artifact leakage**: release verification rejects live state, persona material, tokens, private keys, Python/daemon artifacts, and local identity defaults in public bundles.

## Out Of Scope

- **Malicious same-user local process**: another process running as the same macOS user may read user-accessible files or attempt loopback access. NativeAgent does not claim OS-level privilege separation between same-user processes.
- **Root compromise or physical access**: root or physical access can read local state, tokens, or process memory.
- **Compromised paired iPhone**: a compromised paired iOS app can send signed remote requests. Policy gates still apply, but the pairing identity itself is trusted.
- **Apple/iCloud/APNS provider compromise**: iCloud and APNS are trusted external providers. NativeAgent signs sensitive iCloud actions but cannot protect against all provider-side metadata exposure.
- **LLM prompt injection as a solved problem**: tool result compaction, receipts, and policy gates reduce blast radius, but external text/web/tool outputs remain untrusted model input.
- **Shell sandbox as a security boundary**: shell and bash heuristics are defense-in-depth only. Protected-path floors and policy gates are the real safety controls.

## Secret Storage

| Secret | Location | Notes |
|---|---|---|
| Provider OAuth/API tokens | macOS Keychain for the GitHub PAT; app data under `providers/`, `oauth_tokens/`, or provider-specific stores for remaining credentials | GitHub migration verifies the Keychain write before scrubbing exact legacy paths and fails closed if Keychain is unavailable; mode `0600` where file-backed; never bundled in releases |
| Codex/ChatGPT OAuth material | App data or user Codex auth path, depending on login mode | Used by Swift provider adapters; not a Python runtime path |
| Local bridge endpoint + token | `~/.config/claude-bridge/bridge.json` | Atomic mode-`0600` discovery descriptor; cleared when listener stops; legacy token-only file retained for compatibility |
| Browser IPC endpoint + token | NativeAgent app-support `browser_ipc.json` | Mode `0600`; separate from local agent bridge token; legacy token-only file retained |
| iOS pairing secret | Mac app data plus iOS Keychain and the selected Apple-native pairing plane | Used to HMAC-sign iCloud/CloudKit bridge messages and actions |
| APNS device token | Mac notification token stores | Treat as sensitive; log only suffixes |

## Approval Architecture

- Approval requests are app-owned durable records, not daemon memory. The primary store is under app data at `workflows/approvals/requests.json`.
- Approval creation, resolution, timeout handling, and follow-up execution run through Swift app/core paths.
- Approved work must still pass the relevant action executor's policy and stale-record checks. A stale approval id or mismatched action must not execute.
- Autonomous and remote approval paths must leave compact receipts: requested action, risk/policy reason, decision, executor result, and any follow-up verification.

## Important Controls

| Control | Guarantee | Enforced In |
|---|---|---|
| Swift-only runtime gate | Missing runtime behavior is implemented in Swift or fails closed; retired external runtime paths are not resurrected. | `docs/ARCHITECTURE_BLUEPRINT.md`, Doctor Swift-only checks, release verification |
| Signed device envelopes | Paired iOS actions/messages require HMAC signatures using the pairing secret on both KVS/Drive and CloudKit transports. | `NativeAgentShared` transport/wire models, iOS `iCloudSyncEngine`, Mac `MacSyncEngine` |
| Unified policy model | Chat, iOS, Telegram, Mac control, file access, shell, autonomy, and connector writes share policy decisions and receipts. | TrustCenter/SecurityCenter, router plan, dispatch gates |
| Protected-path floor | Even Developer Mode/autonomy cannot mutate OS-protected paths. | Mac control and file/shell validators |
| Sensitive data deny-list | File tools refuse credential/trust/pairing/token state. | Dispatcher file-system actions |
| Local bridge auth | Local agent bridges require the loopback interface at listener creation, re-check accepted peer endpoints, and use bearer tokens with constant-time compare. | `NativeLoopbackListenerParameters.swift`, `ClaudeBridge.swift`, `MacControlBridge.swift` |
| Browser IPC auth | Browser IPC is token-gated and constrained to allowed navigation schemes. | `BrowserWindow.swift` |
| Connector proof | OAuth token presence alone is not enough; meaningful actions require fresh account/status proof where applicable. | Connector proof/status paths |
| Release blank-slate check | Public builds must not include live state, tokens, local identity, or retired runtime artifacts. | `script/release.sh`, `script/verify_release_artifact.sh` |

## Maintenance Rule For Agents

If this document, source comments, or old cutover notes conflict with `docs/ARCHITECTURE_BLUEPRINT.md` and current code, treat the blueprint/current code as source of truth and update the stale text in the same change. Stale architecture comments are considered safety bugs because agents use them as instructions.
