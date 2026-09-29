import Foundation
import PersistenceCore
import TrustCenter

public struct MacControlRunResult {
    public let statusCode: Int
    public let json: [String: Any]?
    public let rawData: Data
}

/// Compatibility routes and receipts for the Mac Control workbench and bridge.
/// The supplied client retains the canonical Mac Control execution gates.
public enum MacControlActionRoutes {
    public static func auditPath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("mac_control_audit.jsonl")
    }

    /// Generic POST under /v1/mac_control/* used by the workbench. Returns the
    /// raw status code + parsed dict + bytes so callers can branch on 202
    /// (pending_approval) vs 2xx done vs failure without re-parsing.
    ///
    /// Zero-daemon path: if the body is empty or a JSON object, dispatch through
    /// SwiftNativeMacControl. Non-object bodies are rejected locally because
    /// there is no daemon fallback to validate them.
    public static func run(path: String, bodyData: Data, dataRoot: URL, localWorkbench: Bool = false, makeClient: (SecurityOriginContext?, URL) -> any MacControlClient) async throws -> MacControlRunResult {
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
            let impl = makeClient(
                localWorkbench ? SecurityOriginContext(surface: "native_actions") : nil,
                auditPath(dataRoot: dataRoot)
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

}
