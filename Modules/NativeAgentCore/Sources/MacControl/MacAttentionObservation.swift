import Foundation
import NativeAgentShared
import Senses
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
import UserNotifications
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacAttentionObservation.swift` | Bounded attention readout and observation continuity |
extension SwiftNativeMacControl {
    /// `mac_attention` — explicit, bounded continuity over `mac_view`.
    ///
    /// There is no frame loop and no model call here. Start installs passive
    /// system-event observers for a bounded lifetime and takes one fused view.
    /// Next sleeps on an event continuation (or its bounded deadline), then
    /// takes exactly one more fused view. Stop tears the observers down and
    /// invalidates the last attention-scene marks.
    func handleAttention(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let mode = (body["mode"]?.stringValue ?? "status").lowercased()
        func result(
            ok: Bool,
            output: [String: JSONValue],
            error: String? = nil,
            status: Int? = nil
        ) -> MacControlResult {
            MacControlResult(
                ok: ok,
                action: "attention",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                httpStatus: status
            )
        }
        switch mode {
        case "start":
            let duration = body["duration_seconds"]?.integerValue.flatMap(Int.init(exactly:))
                ?? MacAttentionSessionStore.defaultDurationSeconds
            await screenViewStore.invalidate()
            guard let initial = await attentionStore.start(
                durationSeconds: duration,
                now: now(),
                eventSource: attentionEventSource
            ) else {
                return result(
                    ok: false,
                    output: [
                        "active": .bool(false),
                        "status": .string("unavailable"),
                    ],
                    error: "attention_observer_unavailable",
                    status: 501
                )
            }
            return await attentionViewResult(
                body: body,
                pending: initial,
                started: started,
                status: "started"
            )
        case "next":
            guard let sessionId = body["session"]?.stringValue, !sessionId.isEmpty else {
                return result(
                    ok: false,
                    output: ["active": .bool(false), "status": .string("invalid_request")],
                    error: "missing required field: session",
                    status: 400
                )
            }
            let after = Int64(body["after_sequence"]?.integerValue.flatMap(Int.init(exactly:)) ?? -1)
            let waitMs = body["wait_ms"]?.integerValue.flatMap(Int.init(exactly:)) ?? 1_500
            let pending = await attentionStore.waitForActivity(
                sessionId: sessionId,
                after: after,
                timeoutMilliseconds: waitMs,
                now: now()
            )
            if Task.isCancelled {
                return result(
                    ok: false,
                    output: ["active": .bool(true), "status": .string("cancelled")],
                    error: "attention_wait_cancelled",
                    status: 499
                )
            }
            guard let pending else {
                return result(
                    ok: false,
                    output: ["active": .bool(false), "status": .string("not_active")],
                    error: "attention_session_not_active",
                    status: 409
                )
            }
            return await attentionViewResult(
                body: body,
                pending: pending,
                started: started,
                status: pending.timedOutWaiting ? "refreshed" : "changed"
            )
        case "status":
            guard let current = await attentionStore.status(now: now()) else {
                return result(ok: true, output: [
                    "active": .bool(false),
                    "status": .string("idle"),
                ])
            }
            return result(ok: true, output: [
                "active": .bool(true),
                "status": .string(
                    current.yieldRequired ? "yield_required"
                        : (current.refreshRequired ? "refresh_required" : "watching")
                ),
                "attention": current.toJSON(),
            ])
        case "stop":
            let wasActive = await attentionStore.stopAttentionSession()
            await screenViewStore.invalidate()
            return result(ok: true, output: [
                "active": .bool(false),
                "status": .string(wasActive ? "stopped" : "already_idle"),
            ])
        default:
            return result(
                ok: false,
                output: ["active": .bool(false), "status": .string("invalid_request")],
                error: "invalid mode: expected start, next, status, or stop",
                status: 400
            )
        }
    }
    private func attentionViewResult(
        body: [String: JSONValue],
        pending: MacAttentionSnapshot,
        started: Date,
        status: String
    ) async -> MacControlResult {
        let view = await handleView(body)
        guard case .object(var output) = view.output,
              case .string(let viewId)? = output["view"] else {
            return MacControlResult(
                ok: false,
                action: "attention",
                output: view.output,
                error: view.error ?? "attention_view_unavailable",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                httpStatus: view.httpStatus
            )
        }
        let current = await attentionStore.observed(
            sessionId: pending.sessionId,
            viewId: viewId,
            sequence: pending.sequence,
            userSequence: pending.userSequence,
            now: now()
        ) ?? pending
        if current.refreshRequired {
            // Input raced the capture. Never leave its marks usable while the
            // result truthfully says the agent must yield and look again.
            await screenViewStore.invalidate()
        }
        output["status"] = .string(
            current.yieldRequired ? "yield_required"
                : (current.refreshRequired ? "refresh_required" : status)
        )
        output["attention"] = current.toJSON()
        output["how_to_continue"] = .string(
            "While this attention session is active, pass attention_session and "
            + "attention_user_sequence from this result to every Mac action. If yield_required "
            + "is true, do not act; call mac_attention next and re-read the fresh fused view."
        )
        return MacControlResult(
            ok: view.ok,
            action: "attention",
            output: .object(output),
            error: view.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            httpStatus: view.httpStatus
        )
    }
    static let screenRecordingNote =
        "screen_recording_not_trusted: No image is available; the Accessibility legend still works. "
        + "Ask the owner to enable System Settings > Privacy & Security > Screen Recording > NativeAgent "
        + "and follow macOS's restart instruction if shown. This grant is separate from Accessibility."
}
