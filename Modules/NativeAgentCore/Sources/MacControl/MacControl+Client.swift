import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
// Blueprint: | `MacControl+Client.swift` | `SwiftNativeMacControl` actor; `dispatch`, `dispatchApprovedInjection`; `MacObservationMode` carries passive read authority without motor binding, wake, capabilities or desktop effects |
#endif

// MARK: - SwiftNative impl

/// Background perception carries this mode through the whole read, including nested dispatches. It may observe, never wake, write AX flags or use hands.
public enum MacObservationMode: Sendable {
    case interactive, passive
    @TaskLocal public static var current: MacObservationMode = .interactive
}

public actor SwiftNativeMacControl: MacControlClient {
    let now: @Sendable () -> Date
    /// Mac banners are posted by the app's one banner exit, which it injects here; a client built without one refuses `notify` instead of posting around it.
    let notificationCenterAdapter: (any NotificationPosting)?
    let appleScriptAdapter = AppleScriptExecution()
    let processAdapter = ProcessExecution()
    let fileManagerAdapter = FileBytes()
    let appControlAdapter = MacApplications()
    let openTargetAdapter = OpenTarget()
    /// Read-only accessibility perception; this source cannot emit input.
    let accessibilitySource: any MacAXElementSource
    /// Physical input emission, separate from the read source.
    let eventSink: any MacEventSink
    /// Semantic AX mutation, separate from perception.
    let accessibilityActSource: any MacAXActSource
    /// Effect observation listens on the target pid without emitting input.
    let effectObserverSource: any MacAXEffectObserverSource
    /// Screen capture preflights its separate Screen Recording grant without prompting or toggling it.
    let screenCaptureSource: any MacScreenCaptureSource
    let pointerPositionSource = SystemMacPointerPositionSource()
    /// Set-of-marks rendering with bounded placement and image size.
    let screenImageRenderer: any MacScreenImageRenderer
    /// Marks reference the latest fused view; every injection gate still applies.
    let screenViewStore: MacScreenViewStore
    /// Task-scoped perceptual frames resolve handles to paths; a handle grants no authority.
    let lookFrameStore: MacLookFrameStore
    /// Driver authority plus bounded fused-view continuity. Acts automatically start passive observation; every tool client shares the physical Mac.
    let attentionEventSource: any MacAttentionEventSource
    let attentionStore: MacAttentionSessionStore
    /// Login-session safety probe, separate from the sink that emits input.
    let sessionStateSource: any MacSessionStateSource
    /// Pasteboard access cannot walk a tree, post input or capture pixels.
    let pasteboardSource: any MacPasteboardSource
    /// Production uses the live Swift TrustCenter policy. A nil provider lets direct library callers exercise handlers without policy preflight.
    let policyProvider: (any MacControlPolicyProvider)?
    /// Optional refusal-audit path. Appends a stable legacy receipt under the shared file lock; nil disables auditing without changing the refusal.
    let auditAppendPath: URL?
    let operationStore: MacControlOperationStore?

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        notificationCenterAdapter: (any NotificationPosting)? = nil,
        accessibilitySource: any MacAXElementSource = defaultMacAXElementSource(),
        eventSink: any MacEventSink = defaultMacEventSink(),
        accessibilityActSource: any MacAXActSource = defaultMacAXActSource(),
        effectObserverSource: any MacAXEffectObserverSource = defaultMacAXEffectObserverSource(),
        screenCaptureSource: any MacScreenCaptureSource = defaultMacScreenCaptureSource(),
        screenImageRenderer: any MacScreenImageRenderer = defaultMacScreenImageRenderer(),
        screenViewStore: MacScreenViewStore = .shared,
        lookFrameStore: MacLookFrameStore = .shared,
        attentionEventSource: any MacAttentionEventSource = defaultMacAttentionEventSource(),
        attentionStore: MacAttentionSessionStore = .shared,
        sessionStateSource: any MacSessionStateSource = defaultMacSessionStateSource(),
        pasteboardSource: any MacPasteboardSource = defaultMacPasteboardSource(),
        policyProvider: (any MacControlPolicyProvider)? = nil,
        auditAppendPath: URL? = nil,
        operationStore: MacControlOperationStore? = nil
    ) {
        self.now = now
        self.notificationCenterAdapter = notificationCenterAdapter
        self.accessibilitySource = accessibilitySource
        self.eventSink = DriverCheckedMacEventSink(base: eventSink)
        self.accessibilityActSource = accessibilityActSource
        self.effectObserverSource = effectObserverSource
        self.screenCaptureSource = screenCaptureSource
        self.screenImageRenderer = screenImageRenderer
        self.screenViewStore = screenViewStore
        self.lookFrameStore = lookFrameStore
        self.attentionEventSource = attentionEventSource
        self.attentionStore = attentionStore
        self.sessionStateSource = sessionStateSource
        self.pasteboardSource = pasteboardSource
        self.policyProvider = policyProvider
        self.auditAppendPath = auditAppendPath
        self.operationStore = operationStore
    }

    /// Ordinary dispatch uses the canonical execution gates directly. No per-call human approval is required here. Policy, Full Mac, category, TCC and driver checks still apply; a JSON approval marker has no authority.
    public func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        try await dispatchCore(action: action, body: body, capability: nil)
    }

    /// Dispatch with an explicit capability, including an approved replay. It must be live, unspent and bound to this exact action and body.  Policy, Full Mac, category, TCC and driver checks still apply.
    public func dispatchApprovedInjection(
        action: String,
        body: [String: JSONValue],
        capability: MacInjectionCapability
    ) async throws -> MacControlResult {
        try await dispatchCore(action: action, body: body, capability: capability)
    }

    private func dispatchCore(
        action: String,
        body rawBody: [String: JSONValue],
        capability: MacInjectionCapability?
    ) async throws -> MacControlResult {
        if MacObservationMode.current == .passive {
            // No motor-driver binding or held-input cleanup for an observer.
            return try await dispatchBound(action: action, body: rawBody, capability: capability)
        }
        if MacDriverContext.binding == nil {
            let binding = await attentionStore.bindDriver(eventSource: attentionEventSource)
            return try await withTaskCancellationHandler {
                defer { binding.releaseHeldInputs() }
                return try await MacDriverContext.$binding.withValue(binding) {
                    try await dispatchCore(action: action, body: rawBody, capability: capability)
                }
            } onCancel: { binding.cancel() }
        }
        // An act admitted to run in an app in the back stays there, and his input elsewhere does not stop it (MacDriverBinding).
        let background = MacDriverContext.background || rawBody["background"] == .bool(true)
        return try await MacDriverContext.$background.withValue(background) {
            try await MacDriverContext.$inputStartCount.withValue(MacDriverContext.binding?.inputCount ?? 0) {
                driverCheckedResult(try await dispatchBound(action: action, body: rawBody, capability: capability), action: action)
            }
        }
    }

    private func driverCheckedResult(_ reply: MacControlResult, action: String) -> MacControlResult {
        guard macControlTakeoverActions.contains(action), MacDriverContext.binding?.yieldedToPerson == true else { return reply }
        var output: [String: JSONValue] = [:]
        if case .object(let existing) = reply.output { output = existing }
        output["status"] = .string("yielded_to_user")
        output["error"] = .string(MacAttentionSessionStore.driverRefusal)
        output["verification"] = .string("unverified")
        let emitted = max(0, (MacDriverContext.binding?.inputCount ?? 0) - MacDriverContext.inputStartCount)
        output["posted_events"] = .int(Int64(emitted))
        if output["requested_events_emitted"] != nil { output["requested_events_emitted"] = .int(Int64(emitted)) }
        return MacControlResult(
            ok: false, action: reply.action, output: .object(output),
            error: MacAttentionSessionStore.driverRefusal, durationMs: reply.durationMs,
            httpStatus: 409, operationId: reply.operationId,
            operationState: reply.operationState, verification: .unverified, nativePage: reply.nativePage
        )
    }

    private func dispatchBound(
        action: String,
        body rawBody: [String: JSONValue],
        capability: MacInjectionCapability?
    ) async throws -> MacControlResult {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !macControlDispatchableActions.contains(normalized) {
            throw MacControlError.unknownAction(normalized)
        }
        // A JSON approval marker has no authority and is removed before admission.
        var body = rawBody
        body.removeValue(forKey: "__mac_injection_approved")
        if MacObservationMode.current == .passive {
            // Refuse effects before creating a motor operation.
            return try await executeAction(normalized, body: body)
        }

        // Only an explicit replay capability has an authorization to validate and spend. Ordinary calls proceed to the same policy and driver gates.
        if macControlAccessibilityInjectionActions.contains(normalized), let capability {
            if let failure = capability.authorizationFailure(
                action: normalized,
                body: body,
                now: now()
            ) {
                return await injectionApprovalRefusal(
                    action: normalized,
                    reason: "\(failure.rawValue): \(normalized) authorization did not match this call",
                    body: body
                )
            }
            guard await MacInjectionCapabilityLedger.shared.consume(
                nonce: capability.nonce,
                now: now()
            ) else {
                return await injectionApprovalRefusal(
                    action: normalized,
                    reason: "\(MacInjectionCapability.AuthorizationFailure.alreadyUsed.rawValue): "
                        + "\(normalized) authorization was already spent",
                    body: body
                )
            }
        } else if capability != nil {
            // A capability handed to a non-injection action is a programming error, not an escalation — but fail loudly rather than silently widening what a capability means.
            throw MacControlError.unknownAction(normalized)
        }

        // Live reads retain policy preflight but bypass durable motor replay so screen, clipboard and document state stays fresh.
        if macControlLiveReadActions.contains(normalized) {
            return try await executeAction(normalized, body: body)
        }

        guard let operationStore else {
            return try await executeAction(normalized, body: body)
        }
        let operationId = body["operationId"]?.stringValue
            ?? body["operation_id"]?.stringValue
            ?? UUID().uuidString
        var operationBody = body
        operationBody["operationId"] = .string(operationId)
        let timeoutSeconds = Self.operationTimeoutSeconds(action: normalized, body: body)
        let begin: MacControlOperationBeginOutcome
        do {
            let requestDigest = try MacControlOperationStore.requestDigest(
                action: normalized,
                body: operationBody
            )
            begin = try await operationStore.begin(
                operationId: operationId,
                action: normalized,
                requestDigest: requestDigest,
                deadlineSeconds: timeoutSeconds
            )
        } catch {
            throw MacControlError.operation(error.localizedDescription)
        }
        switch begin {
        case .replay(let record):
            return Self.replayResult(record)
        case .duplicateActive(let record):
            return MacControlResult(
                ok: false,
                action: normalized,
                output: .object([
                    "status": .string("duplicate_active"),
                    "operationId": .string(operationId),
                ]),
                error: "operation already active",
                durationMs: 0,
                httpStatus: 409,
                operationId: operationId,
                operationState: record.state,
                verification: record.verification
            )
        case .accepted:
            break
        }

        let outcome = await gatePreflightOutcome(action: normalized, body: operationBody)
        if case .refuse(let refused) = outcome {
            let saved: Result<MacControlOperationRecord, Error> = await settle {
                do { return .success(try await operationStore.transition(
                operationId: operationId,
                to: .refused,
                verification: .notRequired,
                expectedNextEvidence: nil,
                outcomeCode: "policy_refused"
                )) } catch { return .failure(error) }
            }
            let record = try saved.get()
            return Self.attachingOperation(refused, record: record)
        }

        // Register before publishing started. The task cannot emit effects until the durable cancellation state has been reconciled below.
        let startGate = ContinuationOnce<Bool>()
        let task = Task<MacControlResult, Error> {
            guard await startGate.wait() else { throw CancellationError() }
            try Task.checkCancellation()
            return try await self.executeAction(normalized, body: operationBody, gateAlreadyChecked: true)
        }
        let execution = MacControlInFlightExecution(task: task)
        MacControlInFlightRegistry.shared.insert(execution, operationId: operationId)
        defer {
            task.cancel()
            startGate.resume(false)
            MacControlInFlightRegistry.shared.remove(operationId: operationId)
        }
        let startResult: Result<MacControlOperationRecord, Error> = await settle {
            do { return .success(try await operationStore.transition(
            operationId: operationId,
            to: .started,
            verification: .pending,
            expectedNextEvidence: "Mac Control terminal result",
            acknowledgePreStartCancellation: true
            )) } catch { return .failure(error) }
        }
        let started: MacControlOperationRecord
        do { started = try startResult.get() }
        catch {
            task.cancel()
            startGate.resume(false)
            _ = await task.result
            throw error
        }
        if started.state == .cancelAcknowledged {
            task.cancel()
            startGate.resume(false)
            _ = await task.result
            return Self.cancelledResult(action: normalized, record: started)
        }
        let current: MacControlOperationRecord?
        do { current = try await operationStore.record(operationId: operationId) }
        catch {
            task.cancel()
            startGate.resume(false)
            _ = await task.result
            throw error
        }
        if Task.isCancelled || current?.state == .cancelRequested {
            execution.requestCancellation()
        }
        startGate.resume(true)
        Task { execution.finish(await task.result) }
        let deadlineTask = Task<Void, Never> {
            // Process-backed handlers own the exact timeout themselves. A short grace lets their typed `timedOut` result win. A deadline requests Stop; the execution stays owned until its body settles.
            let nanos = UInt64(timeoutSeconds) * 1_000_000_000 + 250_000_000
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            guard !Task.isCancelled else { return }
            execution.reachDeadline()
        }
        defer {
            deadlineTask.cancel()
        }
        let signal = await withTaskCancellationHandler {
            await execution.wait()
        } onCancel: {
            execution.requestCancellation()
        }
        let trigger: OperationSettlementTrigger
        switch signal {
        case .result: trigger = .ordinary
        case .deadline: trigger = .deadline
        case .cancellationRequested: trigger = .cancellation
        }
        // The original body is the only effect owner. Never retire it merely because a caller's reporting deadline or cancellation arrived first.
        let result = (await task.result).map { driverCheckedResult($0, action: normalized) }
        let settled: Result<MacControlResult, Error> = await settle {
            do {
                return .success(try await self.finishKnownOperationResult(result,
                    action: normalized, operationId: operationId, trigger: trigger))
            } catch { return .failure(error) }
        }
        return try settled.get()
    }

    public func cancel(operationId: String) async throws -> MacControlCancellationResult {
        guard let operationStore else {
            throw MacControlError.operation("mac_operation_store_unconfigured: No operation store is configured. Repair NativeAgent's MacControl assembly before requesting cancellation; inspect the affected app with mac.look for prior effects.")
        }
        guard let current = try await operationStore.record(operationId: operationId) else {
            throw MacControlError.operation("mac_operation_not_found: No record exists for this operation_id. Check the original receipt's identity and inspect the affected app with mac.look before further action.")
        }
        if current.state.isTerminal {
            return MacControlCancellationResult(
                operationId: operationId,
                state: current.state,
                acknowledged: current.state == .cancelAcknowledged
            )
        }
        if current.state != .cancelRequested {
            _ = try await operationStore.transition(
                operationId: operationId,
                to: .cancelRequested,
                verification: .pending,
                expectedNextEvidence: "Process-group death acknowledgement",
                outcomeCode: "cancel_requested"
            )
        }
        guard let execution = MacControlInFlightRegistry.shared.execution(operationId: operationId) else {
            return MacControlCancellationResult(
                operationId: operationId,
                state: .cancelRequested,
                acknowledged: false
            )
        }
        execution.requestCancellation()
        // The dispatch owner, not the requester, decides whether the work actually stopped, raced to a real completion, or became unknowable. Wait only for the bounded settlement grace; never hang the cancel requester on an adapter that
        // ignores cooperative cancellation.
        let settled = try await operationStore.waitForCancellationSettlement(
            operationId: operationId, until: .now.advanced(by: .milliseconds(1_500)))
        let terminal: MacControlOperationRecord?
        if let settled { terminal = settled }
        else { terminal = try await operationStore.record(operationId: operationId) }
        return MacControlCancellationResult(
            operationId: operationId,
            state: terminal?.state ?? .cancelRequested,
            acknowledged: terminal?.state == .cancelAcknowledged
        )
    }

    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        try await operationStore?.motorActionReadModel(actionId: actionId)
    }

    struct WakeAttentionRefusal: Error {
        let result: MacControlResult
    }

    public func wakeScreenIfCovered(
        action: String,
        body: [String: JSONValue]
    ) async throws -> MacControlResult? {
        if MacObservationMode.current == .passive {
            guard MacScreenLock.isCovered() else { return nil }
            return MacControlResult(ok: false, action: action,
                output: .object(["status": .string("display_obstructed"),
                    "message": .string(MacScreenLock.passiveReply)]),
                error: "display_obstructed", durationMs: 0)
        }
        do {
            try await MacScreenLock.wakeIfCovered {
                if let refusal = await self.attentionActionRefusal(action: action, body: body) {
                    throw WakeAttentionRefusal(result: refusal)
                }
            }
            // Named background reads and actions leave her windows in place; hands, front-app and desktop access use PersonOnlyWindows' step-aside boundary.
            let named = !(body["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                || body["background"] == .bool(true)
            let behind = named && body["require_front"] != .bool(true) && body["require_front_pid"] == nil
            if !behind { await PersonOnlyWindows.stepAsideForScreen() }
            return nil
        } catch let refusal as WakeAttentionRefusal {
            return refusal.result
        }
    }

    private func executeAction(
        _ normalized: String,
        body: [String: JSONValue],
        gateAlreadyChecked: Bool = false
    ) async throws -> MacControlResult {
        if MacObservationMode.current == .passive,
           !["look", "view", "read", "file/read", "spotlight", "ax_status", "ax_tree", "ax_find", "clipboard_read"].contains(normalized) {
            return MacControlResult(ok: false, action: normalized,
                output: .object(["message": .string("raw view · passive observation · desktop effects are unavailable")]),
                error: "passive_observation", durationMs: 0)
        }
        // Apply live policy before native execution; refusal preserves the structured 403 result and gate reason.
        if !gateAlreadyChecked {
            let outcome = await gatePreflightOutcome(action: normalized, body: body)
            switch outcome {
            case .refuse(let result):
                return result
            case .proceed:
                break
            }
        }
        // An active attention session gives physical human input absolute priority. Check once at tool entry; handlers recheck at the exact effect boundary (and between multi-event gestures) so a mouse move arriving after this line still
        // stops the action. Document reads check this boundary only before their scroll effects, so reading the visible text remains available while the person drives.
        if macControlTakeoverActions.contains(normalized),
           let refusal = await attentionActionRefusal(action: normalized, body: body) {
            return refusal
        }
        // Perception, hands and any call that requires the front share the desktop-send wake: an inert nudge only while the saver covers the screen and the person is idle.
        if MacObservationMode.current == .passive,
           ["look", "view", "ax_tree", "ax_find"].contains(normalized), MacScreenLock.isCovered() {
            return MacControlResult(ok: false, action: normalized,
                output: .object(["status": .string("display_obstructed"), "message": .string(MacScreenLock.passiveReply)]),
                error: "display_obstructed", durationMs: 0)
        }
        if MacObservationMode.current != .passive,
           ["look", "view", "act", "hand", "menu", "menu_press"].contains(normalized) || body["require_front"] == .bool(true) {
            let started = now()
            do {
                if let refusal = try await wakeScreenIfCovered(action: normalized, body: body) {
                    return refusal
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let covered = error as? MacScreenLock.Covered
                let code = covered?.code ?? "display_obstructed"
                let message = covered?.detail ?? error.localizedDescription
                return MacControlResult(
                    ok: false, action: normalized,
                    output: .object(["status": .string(code), "message": .string(message), "guidance": .string(message)]),
                    error: code, durationMs: Int(now().timeIntervalSince(started) * 1000)
                )
            }
        }
        switch normalized {
        case "notify":      return try await handleNotify(body)
        case "file/read":   return try await handleFileRead(body)
        case "file/write":  return try await handleFileWrite(body)
        case "file/list":   return try await handleFileList(body)
        case "file/move":   return try await handleFileMove(body)
        case "file/trash":  return try await handleFileTrash(body)
        case "applescript": return try await handleAppleScript(body)
        case "volume":      return try await handleVolume(body)
        case "media":       return try await handleMedia(body)
        case "focus_app":   return try await handleFocusApp(body)
        case "quit_app":    return try await handleQuitApp(body)
        case "open_target": return try await handleOpenTarget(body)
        case "spotlight":   return try await handleSpotlight(body)
        case "shell":       return try await handleShell(body)
        case "ax_status":   return handleAXStatus()
        case "ax_tree":     return handleAXTree(body)
        case "ax_find":     return try handleAXFind(body)
        // Compiled AX perception is read tier and changes no UI state.
        case "look":
            return await MacAXLimits.$readDeadline.withValue(Date().addingTimeInterval(MacAXLimits.readSeconds)) {
                await handleLook(body)
            }
        // Fused AX/pixel perception is read tier because it changes no app state.
        case "view":        return await handleView(body)
        case "attention":   return await handleAttention(body)
        // Injection has passed policy preflight and, when supplied, consumed its explicit replay capability before reaching a handler.
        case "keystroke":   return await handleKeystroke(body)
        case "click":       return await handleClick(body)
        case "scroll":      return await handleScroll(body)
        case "ax_act":      return await handleAXAct(body)
        // Closed-loop actuation retains injection tier; returned perception is effect evidence.
        case "act":         return await handleAct(body)
        case "hand":        return await handleHand(body)
        // Wake nudges then recaptures; an obstructing saver/login layer refuses capture, not the nudge.
        case "wake":        return await handleWake(body)
        // Nudge emits only a bare mouse move and uses ordinary dispatch.
        case "nudge":       return await handleNudge(body)
        // Clipboard reads redact; writes replace and verify by readback.
        case "clipboard_read":  return handleClipboardRead(body)
        case "clipboard_write": return handleClipboardWrite(body)
        // Menu listing reads; pressing uses the shared actuator.
        case "menu":        return handleMenu(body)
        case "menu_press":  return await handleMenuPress(body)
        // Document extraction or viewport accumulation returns content retained by the turn's spill pager.
        case "read":        return await handleRead(body)
        case let action where macControlUnsupportedActions.contains(action):
            return Self.unsupportedResult(action: action)
        default:
            // Guarded by macControlDispatchableActions at the entry point.
            throw MacControlError.unknownAction(normalized)
        }
    }

    private static func operationTimeoutSeconds(
        action: String,
        body: [String: JSONValue]
    ) -> Int {
        if case .int(let value) = body["timeout"] ?? .null {
            return max(1, min(Int(value), 120))
        }
        if case .double(let value) = body["timeout"] ?? .null,
           let timeout = Int(exactly: value.rounded(.towardZero)) {
            return max(1, min(timeout, 120))
        }
        switch action {
        // In-process CGEvent / AX act; nothing here waits on another process.
        case "keystroke", "click", "scroll", "ax_act", "hand": return 15
        // One act, a bounded ≤2s effect wait, then one AX walk (which on a Chromium window may add a ≤4s settle + one re-walk).
        case "act": return 30
        // One CGEvent post, in-process, nothing awaited.
        case "nudge": return 15
        case "clipboard_write": return 10
        case "menu_press": return 15
        // A nudge, a bounded settle wait, then a full `view` capture.
        case "wake": return 30
        case "shell": return 60
        default: return 90
        }
    }
}

// MARK: - Factory

public func makeMacControl(
    policyProvider: (any MacControlPolicyProvider)? = nil,
    auditAppendPath: URL? = nil,
    operationDataRoot: URL? = nil,
    notificationCenterAdapter: (any NotificationPosting)? = nil
) -> any MacControlClient {
    let dataRoot = operationDataRoot ?? auditAppendPath?.deletingLastPathComponent()
    return SwiftNativeMacControl(
        notificationCenterAdapter: notificationCenterAdapter,
        policyProvider: policyProvider,
        auditAppendPath: auditAppendPath,
        operationStore: dataRoot.map { MacControlOperationStore(dataRoot: $0) }
    )
}
