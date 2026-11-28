import Foundation
import NativeAgentShared
import SenseCore
import NativeAgentCore
import PersistenceCore
import DeskCore
import AppKit
import CoreGraphics
import ApplicationServices
import UserNotifications
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacAttentionObservation.swift` | Bounded attention readout and observation continuity |
extension SwiftNativeMacControl {
    func handleAttention(_ body: [String: JSONValue], context: MacOperationContext) async -> MacControlResult {
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
            , context: context) else {
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
                context: context
            )
        case "status":
            guard let current = await attentionStore.status(now: now(), context: context) else {
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
            let wasActive = await attentionStore.stopAttentionSession(sessionId: body["session"]?.stringValue)
            let current = await attentionStore.status(now: now(), context: context)
            return result(ok: true, output: [
                "active": .bool(current != nil),
                "status": .string(wasActive ? "stopped" : current == nil ? "already_idle" : "session_replaced"),
                "attention": current?.toJSON() ?? .null,
            ])
        default:
            return result(
                ok: false,
                output: ["active": .bool(false), "status": .string("invalid_request")],
                error: "invalid mode: expected start, status, or stop",
                status: 400
            )
        }
    }
    private func attentionViewResult(
        body: [String: JSONValue],
        pending: MacAttentionSnapshot,
        started: Date,
        context: MacOperationContext
    ) async -> MacControlResult {
        let view = await handleView(body, context: context)
        guard case .object(var output) = view.output,
              case .string(let viewId)? = output["view"] else {
            var failure = view.output.objectValue ?? [:]
            failure["requested_session"] = .string(pending.sessionId)
            return MacControlResult(
                ok: false,
                action: "attention",
                output: .object(failure),
                error: view.error ?? "attention_view_unavailable",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                httpStatus: view.httpStatus
            )
        }
        output["requested_session"] = .string(pending.sessionId)
        guard let current = await attentionStore.observed(
            sessionId: pending.sessionId,
            viewId: viewId,
            sequence: pending.sequence,
            userSequence: pending.userSequence,
            now: now()
        , context: context) else {
            // Capture may outlive Stop, expiry, or replacement. The store owns continuity; this old capture cannot reactivate it or its marks.
            await screenViewStore.invalidate(viewId: viewId)
            output["view_current"] = .bool(false)
            let actual = await attentionStore.status(now: now(), context: context)
            output["active"] = .bool(actual != nil)
            output["status"] = .string(actual == nil ? "not_active" : "session_replaced")
            output["attention"] = actual?.toJSON() ?? .null
            return MacControlResult(ok: false, action: "attention", output: .object(output),
                error: "attention_session_not_active", durationMs: Int(now().timeIntervalSince(started) * 1000), httpStatus: 409)
        }
        if current.refreshRequired {
            // Input raced the capture. Never leave its marks usable while the result truthfully says the agent must yield and look again.
            await screenViewStore.invalidate(viewId: viewId)
            output["view_current"] = .bool(false)
        }
        output["status"] = .string(
            current.yieldRequired ? "yield_required"
                : (current.refreshRequired ? "refresh_required" : "started")
        )
        output["attention"] = current.toJSON()
        output["active"] = .bool(true)
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
