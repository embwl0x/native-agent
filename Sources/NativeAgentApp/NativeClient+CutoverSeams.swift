import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

// W-H Band (U5 decomposition, move-only): Wave-3 runtime seam wrappers
// (mobile pairing, MacControl run, inbox/connector URLSession
// consolidation). Relocated verbatim with its companion struct
// (MacControlRunResult — used only by this cluster). The TTS
// (synthesizeSpeech / TTSAudioResponse) and KG-forget
// (forgetKGEntityViaClient) seams were removed once their last callers
// moved to SwiftOpenAITTSClient and the canonical KG forget client.
// Two documented fileprivate→internal lifts in the root (the connector
// registry helpers readConnectorRegistryEntry / mutateConnectorRegistryEntry
// stay in the root file) and one in this file (macControlPolicyProvider,
// raised so the root mac-tool caller still reaches it).

// MARK: - Wave 3 runtime seam wrappers
// Consolidates direct-URLSession callers in PairMobileView, VoiceOutputController,
// KnowledgeGraphView, InboxSettingsView, ContentView, MacControlPermissionsView,
// and ConnectorWizardView behind NativeClient so each subsystem has one
// app-owned Swift entry point.

struct MacControlRunResult {
    let statusCode: Int
    let json: [String: Any]?
    let rawData: Data
}

extension NativeClient {
    // --- Raw snapshot passthrough ------------------------------------------
    /// GET an arbitrary `/v1/...` route and return the raw response body bytes.
    /// Used by MacSyncEngine for snapshot endpoints whose typed Codable decode
    /// would silently fail (Mac models with non-optional defaulted fields the
    /// daemon doesn't emit — TrustPolicy.developerMode etc). Bypasses decode;
    /// iOS reads the resulting JSON with its own lenient structs.
    ///
    /// Returns nil on any transport failure or non-200 status (matches the
    /// previous MacSyncEngine inline helper — snapshot writes are best-effort
    /// and a single missing file must not abort the whole batch).
    ///
    /// WAVE 41 W15 (2026-06-02): the `/v1/trust` snapshot read is now covered
    /// by the `.trustCenter` seam. MacSyncEngine writes this body verbatim into
    /// `trust_policy.json` for the iOS app to decode with its own lenient
    /// struct; `loadTrustPolicyJSON()` produces the canonical compact snapshot.
    /// Other unported snapshot paths return nil in the Swift-only runtime.
    /// See CUTOVER_PLAN.md §6.241.
    /// L3#12 (2026-08-11): collapsed to what it is. The `path` parameter
    /// accepted anything and served exactly one route; every other value hit an
    /// NSLog that read like a live wiring defect in the logs and was not one.
    /// The body is now the trust-snapshot reader, and the one non-trust
    /// possibility is a programmer error, logged as such rather than as a
    /// missing feature.
    ///
    /// Returns nil if the trust policy cannot be serialized (snapshot writes
    /// are best-effort; a single missing file must not abort the batch).
    func trustSnapshotData() async -> Data? {
        try? await SwiftNativeTrustCenter().loadTrustPolicyJSON()
    }

    // --- Trust / inbox policy ----------------------------------------------
    /// GET /v1/trust as a raw dictionary so callers can pick fields the
    /// strongly-typed TrustPolicy doesn't currently surface (e.g. inboxPolicy).
    ///
    /// WAVE 41 W15 (2026-06-02): this RAW read path is now covered by the
    /// `.trustCenter` seam, closing the last typed-vs-raw gap. The typed
    /// `getTrustPolicy()` (above) already routed through SwiftNative; this
    /// untyped reader (used by InboxSettingsView to pick up `inboxPolicy`,
    /// which the typed TrustPolicy struct doesn't surface) still went to
    /// HTTP unconditionally. When `.trustCenter` is ON we decode the SAME
    /// daemon-wire bytes the seam's `loadTrustPolicyJSON()` produces
    /// (compact, sorted-keys, ASCII-escaped — byte-equivalent to the HTTP
    /// `/v1/trust` body), so `inboxPolicy` and every other surface key the
    /// in-Swift normalizer emits is visible in-process. Pure read; no flock
    /// needed (the cross-process lock guards trust/policy.json WRITES; this
    /// reader only reads it). See CUTOVER_PLAN.md §6.241.
    func getTrustRaw() async throws -> [String: Any] {
        // .trustCenter is DEFAULT-ON since b3978932; Swift-native only path.
        let data = try await SwiftNativeTrustCenter().loadTrustPolicyJSON()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // --- Context feedback ---------------------------------------------------
    // Exact, payload-free feedback after validating the canonical transcript
    // row. `dataRoot` is injectable so alternate runtimes and tests cannot
    // leak ratings into Agent's personal root. Persona is deliberately not
    // persisted: message/turn identity already supplies exact correlation.
    func postContextFeedback(
        messageId: String,
        sessionId: String,
        rating: String,
        persona _: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        _ = try await OutcomeFeedbackStore(dataRoot: dataRoot).record(
            sessionID: sessionId,
            messageID: messageId,
            rating: rating
        )
    }

    // --- Screen vision (v1, 2026-06-06) ------------------------------------
    // Swift-native one-shot screen capture. Two-layer fail-closed contract:
    //
    //   Layer 1 (ScreenVision module): SwiftNativeScreenVision.captureScreen()
    //     THROWS on permission denial, missing display, or capture failure.
    //     There is no mock fallback, no empty-Data return, no daemon HTTP
    //     path — that's where the fail-closed rule lives.
    //
    //   Layer 2 (this seam): the v1 spec for this hook is
    //     `func captureScreenForChat() async -> Data?` — it CATCHES the
    //     thrown error from layer 1 so callers that just want an optional
    //     image don't have to wrap try/catch at every call site. The error
    //     is logged via NSLog. NativeClient is a stateless `struct` so
    //     there's no `statusText` to assign here; the chat composer's
    //     existing handler in ContentView surfaces a user-visible toast
    //     via its own ScreenVisionError -> CaptureError mapping in
    //     NativeScreenCapture.captureImageBase64().
    //
    // If a future caller needs the underlying ScreenVisionError, call
    // `SwiftNativeScreenVision().captureScreen()` directly and handle the
    // throws yourself — this hook is the "best-effort, log on failure"
    // convenience wrapper.
    //
    // v1 callers: none yet — this is a public seam for future
    // vision-decision-loop work (e.g. /show slash command, autonomous
    // execution step). The composer button still goes through
    // ContentView.NativeScreenCapture.captureImageBase64() which delegates
    // to the SAME ScreenVision module under the hood.
    @MainActor
    func captureScreenForChat() async -> Data? {
        do {
            return try await SwiftNativeScreenVision().captureScreen()
        } catch {
            NSLog("[NativeClient] captureScreenForChat failed: \(error.localizedDescription)")
            return nil
        }
    }

    // --- Mac control --------------------------------------------------------
    // Zero-daemon Swift path: implemented MacControl actions execute in-process
    // behind the Swift TrustCenter-backed gate. Unknown/unimplemented actions
    // return Swift error envelopes; there is no raw HTTP fallback.
    func macControlNotify(title: String, message: String) async throws -> Bool {
        let impl = makeMacControl(
            policyProvider: macControlPolicyProvider,
            auditAppendPath: macControlAuditPath
        )
        let r = try await impl.dispatch(action: "notify", body: [
            "title": .string(title),
            "message": .string(message),
        ])
        return r.ok
    }

    /// Path to the app-owned `mac_control_audit.jsonl`. Threaded into
    /// `makeMacControl` so in-process gate refusals can append the same audit
    /// shape as older records. Uses `NativeAgentPaths.dataRoot` for the
    /// canonical data location.
    var macControlAuditPath: URL {
        NativeAgentPaths.dataRoot.appendingPathComponent("mac_control_audit.jsonl")
    }

    // W-H lift (move-only): private→internal so the root mac-tool caller
    // (runConnectorAction's mac dispatch) still reaches this provider.
    var macControlPolicyProvider: any MacControlPolicyProvider {
        TrustCenterMacControlPolicyProvider()
    }

    /// Generic POST under /v1/mac_control/* used by the workbench. Returns the
    /// raw status code + parsed dict + bytes so callers can branch on 202
    /// (pending_approval) vs 2xx done vs failure without re-parsing.
    ///
    /// Zero-daemon path: if the body is empty or a JSON object, dispatch through
    /// SwiftNativeMacControl. Non-object bodies are rejected locally because
    /// there is no daemon fallback to validate them.
    func macControlRun(path: String, bodyData: Data, timeout: TimeInterval = 90) async throws -> MacControlRunResult {
        // CORRECTNESS (R3-4): the Swift path requires a JSON-object body so
        // it can be re-emitted via JSONValue.object(...). If bodyData is
        // non-empty AND does not parse as an object (e.g. a top-level array,
        // raw bytes, or invalid JSON), reject locally — coercing to `[:]`
        // would silently drop the caller's payload. Empty body is fine
        // (treated as `{}`).
        let bodyIsObjectOrEmpty: Bool = {
            if bodyData.isEmpty { return true }
            guard let parsed = try? JSONValue.parse(bodyData) else { return false }
            if case .object = parsed { return true }
            return false
        }()
        if bodyIsObjectOrEmpty,
           let action = Self.macControlActionFromPath(path) {
            // W1b: the bridge route must accept every action
            // SwiftNativeMacControl.dispatch will accept — that is
            // `macControlDispatchableActions` (daemon-parity inventory ∪ the
            // Swift-native accessibility reads), NOT the daemon-parity set
            // alone. Gating on macControlAllActions here 404'd ax_status /
            // ax_tree / ax_find on the HTTP/iOS-remote path even though
            // dispatch implements them.
            guard macControlDispatchableActions.contains(action) else {
                let dict: [String: Any] = ["error": "unknown_action", "action": action]
                let raw = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
                return MacControlRunResult(statusCode: 404, json: dict, rawData: raw)
            }
            let impl = makeMacControl(
                policyProvider: macControlPolicyProvider,
                auditAppendPath: macControlAuditPath
            )
            let bodyDict: [String: JSONValue]
            if bodyData.isEmpty {
                bodyDict = [:]
            } else if let parsed = try? JSONValue.parse(bodyData),
                      case .object(let obj) = parsed {
                bodyDict = obj
            } else {
                // Unreachable: guarded by bodyIsObjectOrEmpty above. Defensive.
                bodyDict = [:]
            }
            do {
                // W2/W3-FIX INJECTION FENCE. This route is the HTTP /
                // iOS-remote bridge: the request body comes from OFF this
                // process, and nothing on this path has run the AutonomyGate or
                // filed an approval. It calls the UNPRIVILEGED
                // `dispatch(action:body:)`, whose signature has no way to carry
                // a `MacInjectionCapability` and which refuses
                // keystroke/click/scroll/ax_act/wake outright (403
                // approval_not_granted). W6 `wake` is reachable on this route
                // as a NAME (it is in `macControlDispatchableActions`, so it
                // 403s honestly instead of 404ing as unknown) and refused as a
                // CALL, exactly like the other four — the phone can ask, and
                // the answer is no. W7 `nudge` is different on purpose: it is
                // NOT in `macControlAccessibilityInjectionActions`, so the
                // unprivileged dispatch RUNS it. That is not a widening — the
                // phone still needs the accessibility category and an ACTIVE
                // Full Mac window (the pre-flight names the nudge set alongside
                // the reads), and what it buys is one bare mouse move that
                // cannot click, type or unlock. Waking a slept display from the
                // phone is the entire point of the tool. Remote injection is therefore
                // impossible by TYPE, not by remembering to strip a key from
                // the body — which is what the first cut of this wave relied
                // on. The AX reads keep working from the phone as before.
                let result = try await impl.dispatch(action: action, body: bodyDict)
                if macControlNativePortedActions.contains(action) {
                    // Receipt-shape mirror of daemon's make_receipt. The status
                    // code is no longer hardcoded 200: a Swift gate-pre-flight
                    // REFUSAL (W31 W05 fix — gpt-5.5 caught wave-30 W01 collapsing
                    // every native outcome to 200/blocked=false) carries its own
                    // `result.httpStatus` (403) and its `block_reason`, so the UI
                    // and any future consumer see an honest blocked receipt rather
                    // than a synthesized success. Non-refusal outcomes still get
                    // 200 (the daemon's own /v1/mac_control/* routes return 200
                    // even for a blocked receipt; the block rides in the body —
                    // see run_connector_action in the retired daemon — but surfacing
                    // the in-process refusal's 403 here is strictly MORE honest:
                    // MacControlPermissionsView branches non-2xx → "Failed", which
                    // is the correct render for a refused action).
                    let dict = Self.synthesizeNativeReceipt(action: action, result: result)
                    let raw = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
                    // refusalResult sets ok:false + httpStatus:403; pass that
                    // through. Successful native runs have httpStatus:nil → 200.
                    let statusCode = (!result.ok && result.httpStatus != nil) ? result.httpStatus! : 200
                    return MacControlRunResult(statusCode: statusCode, json: dict, rawData: raw)
                } else {
                    // Unsupported Swift action or Swift-shaped refusal: pass the
                    // result object and status through directly.
                    if case .object(_) = result.output {
                        let raw = (try? result.output.serializedData(pretty: false)) ?? Data()
                        let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
                        // Carry the real upstream status (202 pending_approval,
                        // 4xx validation, etc) when MacControlResult plumbed
                        // it through; fall back to ok→200/!ok→500 otherwise.
                        let status = result.httpStatus ?? (result.ok ? 200 : 500)
                        return MacControlRunResult(statusCode: status, json: dict, rawData: raw)
                    } else {
                        // Swift returned a non-object envelope — give the raw bytes back.
                        let raw = (try? result.output.serializedData(pretty: false)) ?? Data()
                        let status = result.httpStatus ?? (result.ok ? 200 : 500)
                        return MacControlRunResult(statusCode: status, json: nil, rawData: raw)
                    }
                }
            } catch let mcErr as MacControlError {
                let status: Int = {
                    switch mcErr {
                    case .unknownAction: return 404
                    case .missingField: return 400
                    case .sensitivePathDenied, .shellNotWhitelisted: return 403
                    case .proxyFailed(let s, _): return s
                    case .transport, .malformedResponse, .ioFailure,
                         .notificationFailed, .applescriptFailed, .appControlFailed,
                         .operation:
                        return 500
                    }
                }()
                let dict: [String: Any] = [
                    "error": mcErr.errorDescription ?? "\(mcErr)",
                    "dispatched_via": "swift",
                ]
                let raw = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
                return MacControlRunResult(statusCode: status, json: dict, rawData: raw)
            }
        }
        let status = Self.macControlActionFromPath(path) == nil ? 404 : 400
        let dict: [String: Any] = [
            "error": "MacControl Swift dispatch did not serve \(path)",
            "dispatched_via": "swift",
        ]
        let raw = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return MacControlRunResult(statusCode: status, json: dict, rawData: raw)
    }

    /// Map a legacy path like `/v1/mac_control/file/read` to the sub-action
    /// `file/read`. Returns nil for non-mac_control paths.
    fileprivate static func macControlActionFromPath(_ path: String) -> String? {
        let prefix = "/v1/mac_control/"
        guard path.hasPrefix(prefix) else { return nil }
        let action = String(path.dropFirst(prefix.count))
        return action.isEmpty ? nil : action
    }

    /// Build the receipt envelope used when a native action ran in-process.
    /// Callers (MacControlPermissionsView) expect this stable receipt shape,
    /// not the SwiftNativeMacControl `toJSON()` shape.
    ///
    /// **Receipt-shape parity (W31 W05, 2026-06-01)**: `block_reason` +
    /// `blocked` + `status:"blocked"` are now emitted faithfully when a Swift
    /// gate pre-flight refuses the action (closing the wave-30 W01 gap gpt-5.5
    /// caught — refused native actions used to synthesize 200/blocked=false).
    /// Still a subset of the historical success receipt shape:
    /// missing `id`, `args_hash`, `trigger`, `approval_required`, `executed_at`.
    /// Today only `MacControlPermissionsView` consumes these and it
    /// pretty-prints the whole dict, so the remaining gap doesn't crash any
    /// caller. Any future consumer that needs one of those success-only fields
    /// MUST enrich this helper first.
    ///
    /// Audit note: refused actions produce the correct receipt shape here. If a
    /// future consumer requires an audit-file append for every refusal, add that
    /// write in the Swift MacControl path under the same file-lock discipline as
    /// the rest of the app-owned ledgers.
    fileprivate static func synthesizeNativeReceipt(
        action: String,
        result: MacControlResult
    ) -> [String: Any] {
        let category: String
        switch action {
        case "notify":
            category = "notifications"
        case let a where a.hasPrefix("file/"):
            category = "file_ops"
        case "spotlight":
            category = "spotlight"
        default:
            category = action
        }
        // stdout: summarize file ops as `read N bytes sha256=X` /
        // `wrote N bytes` where it is reasonable.
        var stdoutStr = ""
        var topContent: Any? = nil
        if case .object(let obj) = result.output {
            switch action {
            case "file/read":
                let bytes: Int64 = {
                    if case .int(let n) = obj["bytes"] ?? .null { return n }
                    return 0
                }()
                let sha: String = {
                    if case .string(let s) = obj["sha256"] ?? .null { return s }
                    return ""
                }()
                stdoutStr = "read \(bytes) bytes sha256=\(sha)"
                if case .string(let s) = obj["content"] ?? .null { topContent = s }
            case "file/write":
                let bytes: Int64 = {
                    if case .int(let n) = obj["bytes"] ?? .null { return n }
                    return 0
                }()
                stdoutStr = "wrote \(bytes) bytes"
            default:
                // For other native actions (notify, file/list, file/move,
                // file/trash, spotlight) serialize the output dict as JSON
                // so callers can still parse it from stdout if needed.
                if let raw = try? result.output.serializedData(pretty: false),
                   let s = String(data: raw, encoding: .utf8) {
                    stdoutStr = s
                }
            }
        }
        // W31 W05: honor a Swift gate-pre-flight REFUSAL. `refusalResult`
        // (MacControl.swift) returns ok:false with an `output.object` carrying
        // `block_reason` + `blocked_by: "swift_gate_preflight"`. The wave-30
        // W01 version of this helper flattened that to blocked:false, so a
        // refused action looked like a success to MacControlPermissionsView
        // (and any future consumer) — the parity gap gpt-5.5 flagged. Read the
        // block markers out of result.output and mirror the daemon's
        // `make_receipt(blocked=True, block_reason=reason)` shape exactly.
        var blockReason: String? = nil
        if !result.ok, case .object(let obj) = result.output {
            if case .string(let r) = obj["block_reason"] ?? .null, !r.isEmpty {
                blockReason = r
            } else if case .bool(true) = obj["blocked"] ?? .null {
                // blocked:true with no explicit reason — fall back to the
                // result.error string. (Defensive: today's only blocked path is
                // refusalResult, which ALWAYS emits a non-empty block_reason and
                // takes the branch above, so this fallback is unreached. If a
                // future blocked-without-reason path appears, block_reason may be
                // "" here — matching make_receipt's empty-string default, which
                // the daemon also permits for a blocked receipt.)
                blockReason = result.error ?? ""
            }
        }
        let isBlocked = (blockReason != nil)
        var dict: [String: Any] = [
            "method": action,
            "category": category,
            // Daemon make_receipt: blocked receipts ride exit_code 0 but
            // blocked:true. We keep exit_code as the run signal (1 on any
            // non-ok outcome) so callers reading exit_code still see failure;
            // the authoritative block signal is `blocked` + `block_reason`.
            "exit_code": result.ok ? 0 : 1,
            "stdout": stdoutStr,
            "stderr": result.error ?? "",
            "duration_ms": result.durationMs,
            "blocked": isBlocked,
            "via_swift": true,
        ]
        if let operationId = result.operationId {
            dict["operationId"] = operationId
        }
        if let operationState = result.operationState {
            dict["operationState"] = operationState.rawValue
        }
        if let verification = result.verification {
            dict["verification"] = verification.rawValue
        }
        // Mirror the daemon shape: `block_reason` always present (empty string
        // when not blocked, matching make_receipt's default). When blocked,
        // also surface `status: "blocked"` so consumers that branch on the
        // connector-receipt `status` field (run_connector_action sets
        // status="blocked") get the same signal.
        dict["block_reason"] = blockReason ?? ""
        if isBlocked {
            dict["status"] = "blocked"
            dict["ok"] = false
        }
        if let c = topContent {
            dict["content"] = c
        }
        return dict
    }

    // --- Connector wizard ---------------------------------------------------
    // DAEMON-DEAD PORT (2026-06-02): registry decode of
    // <dataRoot>/connectors/registry.json. Missing entry → not-registered.
    func getConnectorRegistrationStatus(provider: String) async throws -> ConnectorRegistrationStatus {
        let root = PersistenceCore.defaultDataRoot()
        if case .nativeOAuth(let connectorId) =
            ConnectorWizardSetupRoute.resolve(provider: provider),
           NativeOAuthFlow.connectorOAuthAppCredentials(
               connectorId: connectorId,
               dataRoot: root
           ) != nil {
            return ConnectorRegistrationStatus(
                registered: true,
                registeredAt: nil,
                clientIdPresent: true
            )
        }
        if let entry = try await Self.readConnectorRegistryEntry(root: root, provider: provider) {
            let registered: Bool = {
                if case .bool(let b)? = entry["registered"] { return b }
                return false
            }()
            let registeredAt: String? = {
                if case .string(let s)? = entry["registered_at"] { return s }
                if case .string(let s)? = entry["registeredAt"] { return s }
                return nil
            }()
            let clientIdPresent: Bool = {
                if case .bool(let b)? = entry["client_id_present"] { return b }
                if case .bool(let b)? = entry["clientIdPresent"] { return b }
                return false
            }()
            return ConnectorRegistrationStatus(
                registered: registered,
                registeredAt: registeredAt,
                clientIdPresent: clientIdPresent
            )
        }
        return ConnectorRegistrationStatus(registered: false, registeredAt: nil, clientIdPresent: false)
    }

    // DAEMON-DEAD PORT (2026-06-02): in-process register-app is non-programmatic
    // — the real OAuth client_id provisioning lived in the daemon's per-provider
    // portal flow. Mark the connector entry registered in
    // <dataRoot>/connectors/registry.json so the wizard can advance, and return
    // an envelope that surfaces the per-provider portal URL the user must visit
    // manually.
    func registerConnectorApp(provider: String) async throws -> ConnectorRegisterAppResponse {
        let now = SwiftNativeManifestSigner.isoTimestamp(Date())
        _ = try await Self.mutateConnectorRegistryEntry(
            root: PersistenceCore.defaultDataRoot(),
            provider: provider,
            createIfMissing: true
        ) { entry in
            entry["registered"] = .bool(true)
            entry["registered_at"] = .string(now)
            entry["registeredAt"] = .string(now)
        }
        let portal: String? = {
            switch provider.lowercased() {
            case "google", "gmail", "email", "calendar", "gcal",
                 "googlecalendar", "google_calendar", "googledrive":
                return "https://console.cloud.google.com/apis/credentials"
            case "x", "twitter": return "https://developer.x.com/en/portal/dashboard"
            case "linear": return "https://linear.app/settings/api/applications/new"
            case "github": return "https://github.com/settings/applications/new"
            case "slack": return "https://api.slack.com/apps"
            default: return nil
            }
        }()
        return ConnectorRegisterAppResponse(
            provider: provider,
            programmatic: false,
            approvalUrl: nil,
            callbackPath: nil,
            portalUrl: portal,
            note: "Create an OAuth app at the provider portal, then save its client credentials in this wizard.",
            reason: nil,
            nextSteps: portal.map {
                [
                    "Open \($0)",
                    "Create an OAuth client with the redirect URI shown here",
                    "Paste the client ID and optional secret below",
                ]
            }
        )
    }

}
