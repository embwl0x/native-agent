import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
// Blueprint: | `MacControl+Client.swift` | `SwiftNativeMacControl`, `dispatch`, `dispatchApprovedInjection`, `MacObservationMode` |
#endif

// MARK: - SwiftNative impl

/// Background perception carries this mode through the whole read, including nested dispatches. It may observe, never wake, write AX flags or use hands.
public enum MacObservationMode: Sendable {
    case interactive, passive

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
    /// Renderer preparation may enable advertised AX modes but must emit no UI input.
    private let suppliedAccessibilitySource: any MacAXElementSource
    func accessibilitySource(context: MacOperationContext) -> any MacAXElementSource { axSession(context: context)?.read ?? suppliedAccessibilitySource }
    /// Keep physical input separate from read sources so observation grants no emission authority.
    let eventSink: any MacEventSink
    /// Keep AX mutation separate from perception so read admission cannot authorize writes.
    private let suppliedAccessibilityActSource: any MacAXActSource
    func accessibilityActSource(context: MacOperationContext) -> any MacAXActSource { axSession(context: context)?.act ?? suppliedAccessibilityActSource }
    /// Native reference tables belong to one dispatch, including its nested reads/acts and actual settlement. They never accumulate on this client.
    struct AXSession: Sendable {
        let owner: ObjectIdentifier
        let read: any MacAXElementSource
        let act: any MacAXActSource
    }

    private func axSession(context: MacOperationContext) -> AXSession? {
        let owner = ObjectIdentifier(self)
        guard let session = context.axSession ?? context.capture?.axSession(for: owner),
              session.owner == owner else { return nil }
        return session
    }
    /// Observe effects without emitting input so notifications cannot manufacture the evidence being judged.
    let effectObserverSource: any MacAXEffectObserverSource
    /// Screen capture preflights its separate Screen Recording grant without prompting or toggling it.
    let screenCaptureSource: any MacScreenCaptureSource
    let pointerPositionSource = SystemMacPointerPositionSource()
    let screenImageRenderer: any MacScreenImageRenderer
    /// Marks reference the latest fused view; every injection gate still applies.
    let screenViewStore: MacScreenViewStore
    /// Operation-scoped perceptual frames resolve handles to paths; a handle grants no authority.
    let lookFrameStore: MacLookFrameStore
    /// Driver authority plus bounded fused-view continuity. Acts automatically start passive observation; every tool client shares the physical Mac.
    let attentionEventSource: any MacAttentionEventSource
    let attentionStore: MacAttentionSessionStore
    /// Keep login-session safety independent of the sink that emits input.
    let sessionStateSource: any MacSessionStateSource
    /// Pasteboard access grants no tree, input or pixel-capture authority.
    let pasteboardSource: any MacPasteboardSource
    /// Production uses the live Swift TrustCenter policy. A nil provider lets direct library callers exercise handlers without policy preflight.
    let policyProvider: (any MacControlPolicyProvider)?
    /// The data root whose record holds each refusal as a `mac.act.audit` detail about its turn; nil disables auditing without changing the refusal.
    let auditDataRoot: URL?
    let operationStore: MacControlOperationStore?
    let permissionDataRoot: URL

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
        auditDataRoot: URL? = nil,
        operationStore: MacControlOperationStore? = nil,
        permissionDataRoot: URL = defaultDataRoot()
    ) {
        self.now = now
        self.notificationCenterAdapter = notificationCenterAdapter
        self.suppliedAccessibilitySource = accessibilitySource
        self.eventSink = DriverCheckedMacEventSink(base: eventSink)
        self.suppliedAccessibilityActSource = accessibilityActSource
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
        self.auditDataRoot = auditDataRoot
        self.operationStore = operationStore
        self.permissionDataRoot = permissionDataRoot
    }

    /// Ordinary dispatch uses the canonical execution gates directly. No per-call human approval is required here. Policy, Full Mac, category, TCC and driver
    /// checks still apply; a JSON approval marker has no authority.
    public func dispatch(action: String, body: [String: JSONValue], turn: Turn, context: MacOperationContext) async throws -> MacControlResult {
        // Releasing one captured session emits no input and needs no renewed work admission. Stop, expired authority or a disabled switch cannot prevent
        // settlement; the store still compares the exact session id.
        if action == "attention", body["mode"] == .string("stop"),
           let session = body["session"]?.stringValue, !session.isEmpty {
            return await handleAttention(body, context: context)
        }
        return try await context.holding(\.looking, Self.isLooking(action: action, body: body) || action == "hand" && context.looking) { context in
            try await dispatchCore(action: action, body: body, capability: nil, turn: turn, context: context)
        }
    }

    /// Dispatch with an explicit capability, including an approved replay. It must be live, unspent and bound to this exact action and body.  Policy, Full Mac,
    /// category, TCC and driver checks still apply.
    public func dispatchApprovedInjection(
        action: String,
        body: [String: JSONValue],
        capability: MacInjectionCapability,
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult {
        try await context.holding(\.looking, Self.isLooking(action: action, body: body) || action == "hand" && context.looking) { context in
            try await dispatchCore(action: action, body: body, capability: capability, turn: turn, context: context)
        }
    }

    private static func isLooking(action: String, body: [String: JSONValue]) -> Bool {
        ["look", "view", "read", "menu", "ax_tree", "ax_find", "scroll", "nudge", "wake", "focus_app", "open_target"].contains(action)
            || action == "act" && body["verb"]?.stringValue == "scroll"
            || action == "hand" && body["gesture"]?.stringValue == "scroll"
    }

    private func dispatchCore(
        action: String,
        body rawBody: [String: JSONValue],
        capability: MacInjectionCapability?,
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult {
        if axSession(context: context) == nil {
            #if canImport(ApplicationServices) && os(macOS)
            let read: any MacAXElementSource = suppliedAccessibilitySource is SystemMacAXElementSource
                ? SystemMacAXElementSource() : suppliedAccessibilitySource
            let act: any MacAXActSource = suppliedAccessibilityActSource is SystemMacAXActSource
                ? SystemMacAXActSource() : suppliedAccessibilityActSource
            #else
            let read = suppliedAccessibilitySource
            let act = suppliedAccessibilityActSource
            #endif
            let created = AXSession(owner: ObjectIdentifier(self), read: read, act: act)
            // Look and its pixel supplement are separate dispatches of one observation. Its binding owns their shared references until exit.
            let session = context.capture?.retainAXSession(created) ?? created
            return try await context.holding(\.axSession, session) { context in
                try await dispatchCore(action: action, body: rawBody, capability: capability, turn: turn, context: context)
            }
        }
        if context.deadline == nil {
            do {
                return try await OperationWaitBudget.withDeadline(
                    seconds: Double(Self.operationTimeoutSeconds(action: action, body: rawBody)),
                  budget: context.waitBudget) { budget in
                    let context = context.with(\.deadline, budget.deadline)
                    return try await self.dispatchCore(action: action, body: rawBody, capability: capability, turn: turn, context: context) }
            } catch is OperationWaitBudget.Exceeded {
                return Self.deadlineResult(action: action)
            }
        }
        guard !context.expired else { return Self.deadlineResult(action: action) }
        try Task.checkCancellation()
        if context.dataRoot != permissionDataRoot {
            return try await context.holding(\.dataRoot, permissionDataRoot) { context in
                try await dispatchCore(action: action, body: rawBody, capability: capability, turn: turn, context: context)
            }
        }
        if context.observationMode == .passive {
            // No motor-driver binding or held-input cleanup for an observer.
            return try await dispatchBound(action: action, body: rawBody, capability: capability, turn: turn, context: context)
        }
        if context.driver == nil {
            let binding = try await attentionStore.bindDriver(eventSource: attentionEventSource)
            return try await withTaskCancellationHandler {
                defer { binding.releaseHeldInputs() }
                return try await context.holding(\.driver, binding) { context in
                    try await dispatchCore(action: action, body: rawBody, capability: capability, turn: turn, context: context)
                }
            } onCancel: { binding.cancel() }
        }
        // Arbitrary app scripts can move the person's cursor, keys, focus or screen; background labels cannot exempt them from foreground takeover.
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let background = normalized != "applescript"
            && (context.background || rawBody["background"] == .bool(true))
        return try await context.holding(\.background, background) { context in
            try await context.holding(\.inputStartCount, context.driver?.inputCount ?? 0) { context in
                driverCheckedResult(try await dispatchBound(action: action, body: rawBody, capability: capability, turn: turn, context: context),
                    action: normalized, context: context)
            }
        }
    }

    private func driverCheckedResult(_ reply: MacControlResult, action: String, context: MacOperationContext) -> MacControlResult {
        if let refusal = context.driver?.takeAppActRefusal() { return refusal.result(action: action) }
        guard macControlTakeoverActions.contains(action), context.driver?.yieldedToPerson == true else { return reply }
        var output: [String: JSONValue] = [:]
        if case .object(let existing) = reply.output { output = existing }
        output["status"] = .string("yielded_to_user")
        output["error"] = .string(MacAttentionSessionStore.driverRefusal(context: context))
        output["verification"] = .string("unverified")
        let emitted = max(0, (context.driver?.inputCount ?? 0) - context.inputStartCount)
        output["posted_events"] = .int(Int64(emitted))
        if output["requested_events_emitted"] != nil { output["requested_events_emitted"] = .int(Int64(emitted)) }
        return MacControlResult(
            ok: false, action: reply.action, output: .object(output),
            error: MacAttentionSessionStore.driverRefusal(context: context), durationMs: reply.durationMs,
            httpStatus: 409, operationId: reply.operationId,
            operationState: reply.operationState, verification: .unverified, nativePage: reply.nativePage
        )
    }

    private func dispatchBound(
        action: String,
        body rawBody: [String: JSONValue],
        capability: MacInjectionCapability?,
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !macControlDispatchableActions.contains(normalized) {
            throw MacControlError.unknownAction(normalized)
        }
        // A JSON approval marker has no authority and is removed before admission.
        var body = rawBody
        body.removeValue(forKey: "__mac_injection_approved")
        if context.observationMode == .passive {
            // Refuse effects before creating a motor operation.
            return try await executeAction(normalized, body: body, turn: turn, context: context)
        }

        // Spend only explicit replay capabilities; ordinary calls still pass the same policy and driver gates.
        if macControlAccessibilityInjectionActions.contains(normalized), let capability {
            if let failure = capability.authorizationFailure(
                action: normalized,
                body: body,
                now: now()
            ) {
                return await injectionApprovalRefusal(
                    action: normalized,
                    reason: "\(failure.rawValue): \(normalized) authorization did not match this call",
                    body: body, turn: turn
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
                    body: body, turn: turn
                )
            }
        } else if capability != nil {
            // A capability handed to a non-injection action is a programming error, not an escalation — but fail loudly rather than silently widening what a
            // capability means.
            throw MacControlError.unknownAction(normalized)
        }

        // Live reads retain policy preflight but bypass durable motor replay so screen, clipboard and document state stays fresh.
        if macControlLiveReadActions.contains(normalized) {
            return try await executeAction(normalized, body: body, turn: turn, context: context)
        }

        guard let operationStore else {
            return try await executeAction(normalized, body: body, turn: turn, context: context)
        }
        let operationId = body["operationId"]?.stringValue
            ?? body["operation_id"]?.stringValue
            ?? UUID().uuidString
        let executionKey = MacControlInFlightRegistry.Key(store: operationStore.registryIdentity, operationId: operationId)
        var operationBody = body
        operationBody["operationId"] = .string(operationId)
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
                deadlineAt: context.wallDate
            )
        } catch let error as ToolFailureError {
            throw error
        } catch {
            throw MacControlError.operation(error.localizedDescription)
        }
        switch begin {
        case .replay(let record):
            if let retained = MacControlInFlightRegistry.shared.execution(key: executionKey)?.settledResult {
                return try retained.get()
            }
            return Self.replayResult(record)
        case .duplicateActive(let record):
            if let retained = MacControlInFlightRegistry.shared.execution(key: executionKey)?.settledResult {
                return try retained.get()
            }
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

        let outcome: GatePreflightOutcome
        do { outcome = try await gatePreflightOutcome(action: normalized, body: operationBody, turn: turn, context: context) }
        catch {
            // Discovery is read-only: cancellation before admission emitted no effect, but the accepted durable operation still owes settlement.
            let saved: Result<MacControlOperationRecord, Error> = await settle {
                do { return .success(try await operationStore.transition(
                    operationId: operationId, to: .cancelAcknowledged,
                    verification: .notRequired, outcomeCode: "cancelled_before_start",
                    acknowledgePreStartCancellation: true)) }
                catch { return .failure(error) }
            }
            _ = try saved.get()
            throw error
        }
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
            guard await startGate.wait(budget: context.waitBudget, cancellingWith: false) else { throw context.cancellationError }
            try Task.checkCancellation()
            guard case .proceed(let fullMacAdmitted) = outcome else { preconditionFailure("Refused operations return before execution") }
            return try await turn.holding(\.fullMacAdmitted, fullMacAdmitted) { turn in
                try await self.executeAction(normalized, body: operationBody, gateAlreadyChecked: true, turn: turn, context: context)
            }
        }
        let execution = MacControlInFlightExecution(task: task)
        MacControlInFlightRegistry.shared.insert(execution, key: executionKey)
        // Actual exit is the sole terminal settlement owner. Caller cancellation resolves only its response signal, never this retained body result.
        Task {
            let bodyResult = (await task.result).map { self.driverCheckedResult($0, action: normalized, context: context) }
            let settled: Result<MacControlResult, Error> = await settle {
                do { return .success(try await self.finishKnownOperationResult(bodyResult,
                    action: normalized, operationId: operationId, trigger: .ordinary)) }
                catch { return .success(Self.settlementFailure(error, body: bodyResult,
                    action: normalized, operationId: operationId, context: context)) }
            }
            execution.finish(settled)
            MacControlInFlightRegistry.shared.finished(key: executionKey)
        }
        defer {
            task.cancel()
            startGate.resume(false)
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
            throw error
        }
        if started.state == .cancelAcknowledged {
            task.cancel()
            startGate.resume(false)
            return Self.cancelledResult(action: normalized, record: started)
        }
        let current: MacControlOperationRecord?
        do { current = try await operationStore.record(operationId: operationId) }
        catch {
            task.cancel()
            startGate.resume(false)
            throw error
        }
        if Task.isCancelled || current?.state == .cancelRequested {
            execution.requestCancellation()
        }
        startGate.resume(true)
        let signal = await withTaskCancellationHandler {
            await execution.wait(context: context)
        } onCancel: {
            execution.requestCancellation()
        }
        if let result = execution.settledResult { return try result.get() }
        // Only the response wait ended. Publish uncertainty without consuming the actual-exit result or authorizing another physical execution.
        let timedOut = signal == .deadline
        let pending: Result<MacControlOperationRecord, Error> = await settle {
            do { return .success(try await operationStore.responseUnavailable(operationId: operationId,
                timedOut: timedOut)) }
            catch { return .failure(error) }
        }
        let record = try pending.get()
        // Actual settlement can win while the reporting record is written.
        if let result = execution.settledResult { return try result.get() }
        return Self.unknownResult(action: normalized, record: record)
    }

    public func cancel(operationId: String) async throws -> MacControlCancellationResult {
        guard let operationStore else {
            throw MacControlError.operation("""
                mac_operation_store_unconfigured: No operation store is configured. Repair NativeAgent's MacControl assembly before requesting cancellation; \
                inspect the affected app with mac.look for prior effects.
                """)
        }
        let executionKey = MacControlInFlightRegistry.Key(store: operationStore.registryIdentity, operationId: operationId)
        guard let current = try await operationStore.record(operationId: operationId) else {
            throw MacControlError.operation("""
                mac_operation_not_found: No record exists for this operation_id. Check the original receipt's identity and inspect the affected app with \
                mac.look before further action.
                """)
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
        guard let execution = MacControlInFlightRegistry.shared.execution(key: executionKey) else {
            return MacControlCancellationResult(
                operationId: operationId,
                state: .cancelRequested,
                acknowledged: false
            )
        }
        execution.requestCancellation()
        // The dispatch owner, not the requester, decides whether the work actually stopped, raced to a real completion, or became unknowable. Wait only for the
        // bounded settlement grace; never hang the cancel requester on an adapter that ignores cooperative cancellation.
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
        body: [String: JSONValue],
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult? {
        if context.observationMode == .passive {
            guard try MacScreenLock.isCovered() else { return nil }
            return MacControlResult(ok: false, action: action,
                output: .object(["status": .string("display_obstructed"),
                    "message": .string(MacScreenLock.passiveReply)]),
                error: "display_obstructed", durationMs: 0)
        }
        do {
            try await MacScreenLock.wakeIfCovered(turn: turn, context: context) {
                if let refusal = await self.attentionActionRefusal(action: action, body: body, turn: turn, context: context) {
                    throw WakeAttentionRefusal(result: refusal)
                }
            }
            // Named background reads and actions leave the agent's windows in place; hands, front-app and desktop access use PersonOnlyWindows' step-aside
            // boundary.
            let named = !(body["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                || body["background"] == .bool(true)
            let behind = named && body["require_front"] != .bool(true) && body["require_front_pid"] == nil
            if !behind { await PersonOnlyWindows.stepAsideForScreen(turn: turn) }
            return nil
        } catch let refusal as WakeAttentionRefusal {
            return refusal.result
        }
    }

    private func executeAction(
        _ normalized: String,
        body: [String: JSONValue],
        gateAlreadyChecked: Bool = false,
        turn: Turn, context: MacOperationContext
    ) async throws -> MacControlResult {
        if context.observationMode == .passive,
           !["look", "view", "read", "file/read", "spotlight", "ax_status", "ax_tree", "ax_find", "clipboard_read"].contains(normalized) {
            return MacControlResult(ok: false, action: normalized,
                output: .object(["message": .string("raw view · passive observation · desktop effects are unavailable")]),
                error: "passive_observation", durationMs: 0)
        }
        // Apply live policy before native execution; refusal preserves the structured 403 result and gate reason.
        if !gateAlreadyChecked {
            let outcome = try await gatePreflightOutcome(action: normalized, body: body, turn: turn, context: context)
            switch outcome {
            case .refuse(let result):
                return result
            case .proceed(let fullMacAdmitted):
                return try await turn.holding(\.fullMacAdmitted, fullMacAdmitted) { turn in
                    try await executeAction(normalized, body: body, gateAlreadyChecked: true, turn: turn, context: context)
                }
            }
        }
        // An active attention session gives physical human input absolute priority. Check once at tool entry; handlers recheck at the exact effect boundary
        // (and between multi-event gestures) so a mouse move arriving after this line still stops the action. Document reads check this boundary only before
        // their scroll effects, so reading the visible text remains available while the person drives.
        if macControlTakeoverActions.contains(normalized),
           let refusal = await attentionActionRefusal(action: normalized, body: body, turn: turn, context: context) {
            return refusal
        }
        // Perception, hands and any call that requires the front share the desktop-send wake: an inert nudge only while the saver covers the screen and the
        // person is idle.
        if context.observationMode == .passive,
           ["look", "view", "ax_tree", "ax_find"].contains(normalized), try MacScreenLock.isCovered() {
            return MacControlResult(ok: false, action: normalized,
                output: .object(["status": .string("display_obstructed"), "message": .string(MacScreenLock.passiveReply)]),
                error: "display_obstructed", durationMs: 0)
        }
        if context.observationMode != .passive,
           ["look", "view", "act", "hand", "menu", "menu_press"].contains(normalized) || body["require_front"] == .bool(true) {
            let started = now()
            do {
                if let refusal = try await wakeScreenIfCovered(action: normalized, body: body, turn: turn, context: context) {
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
        case "applescript": return try await handleAppleScript(body, context: context)
        case "volume":      return try await handleVolume(body)
        case "media":       return try await handleMedia(body, context: context)
        case "focus_app":   return try await handleFocusApp(body, turn: turn, context: context)
        case "quit_app":    return try await handleQuitApp(body, context: context)
        case "open_target": return try await handleOpenTarget(body, context: context)
        case "spotlight":   return try await handleSpotlight(body)
        case "shell":       return try await handleShell(body)
        case "ax_status":   return handleAXStatus(context: context)
        case "ax_tree":     return handleAXTree(body, context: context)
        case "ax_find":     return try handleAXFind(body, context: context)
        case "look":
            return await context.holding(\.readDeadline, Date().addingTimeInterval(MacAXLimits.readSeconds)) { context in
                await handleLook(body, turn: turn, context: context)
            }
        // Fused perception stays read tier because it emits no UI input.
        case "view":        return await handleView(body, context: context)
        case "attention":   return await handleAttention(body, context: context)
        // Reach handlers only after policy admission and consumption of any supplied replay capability.
        case "keystroke":   return await handleKeystroke(body, turn: turn, context: context)
        case "click":       return await handleClick(body, turn: turn, context: context)
        case "scroll":      return await handleScroll(body, turn: turn, context: context)
        case "ax_act":      return await handleAXAct(body, turn: turn, context: context)
        // Returned perception is effect evidence; it cannot lower actuation from injection tier.
        case "act":         return await handleAct(body, turn: turn, context: context)
        case "hand":        return await handleHand(body, turn: turn, context: context)
        // Wake nudges then recaptures; an obstructing saver/login layer refuses capture, not the nudge.
        case "wake":        return await handleWake(body, turn: turn, context: context)
        case "nudge":       return await handleNudge(body, turn: turn, context: context)
        // Clipboard writes need readback; set-call success alone cannot verify contents.
        case "clipboard_read":  return handleClipboardRead(body)
        case "clipboard_write": return handleClipboardWrite(body)
        // Keep menu discovery read-only; pressing uses the actuator's mutation authority.
        case "menu":        return handleMenu(body, context: context)
        case "menu_press":  return await handleMenuPress(body, turn: turn, context: context)
        // Retain document text through the existing spill pager so extraction adds no second owner.
        case "read":        return await handleRead(body, turn: turn, context: context)
        case let action where macControlUnsupportedActions.contains(action):
            return Self.unsupportedResult(action: action)
        default:
            // Guarded by macControlDispatchableActions at the entry point.
            throw MacControlError.unknownAction(normalized)
        }
    }

    public static func operationTimeoutSeconds(
        action: String,
        body: [String: JSONValue]
    ) -> Int {
        let action = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if case .int(let value) = body["timeout"] ?? .null {
            return max(1, min(Int(value), 120))
        }
        if case .double(let value) = body["timeout"] ?? .null,
           let timeout = Int(exactly: value.rounded(.towardZero)) {
            return max(1, min(timeout, 120))
        }
        switch action {
        case "keystroke", "click", "scroll", "ax_act", "hand": return 15
        // Budget the effect wait plus the post-action AX walk, including any bounded renderer settle.
        case "act": return 30
        case "nudge": return 15
        case "clipboard_write": return 10
        case "menu_press": return 15
        // Wake needs both bounded settling and a fresh capture to report the resulting screen.
        case "wake": return 30
        case "shell": return 60
        default: return 90
        }
    }
}

// MARK: - Factory

public func makeMacControl(
    policyProvider: (any MacControlPolicyProvider)? = nil,
    auditDataRoot: URL? = nil,
    operationDataRoot: URL? = nil,
    notificationCenterAdapter: (any NotificationPosting)? = nil
) -> any MacControlClient {
    let dataRoot = operationDataRoot ?? auditDataRoot
    return SwiftNativeMacControl(
        notificationCenterAdapter: notificationCenterAdapter,
        policyProvider: policyProvider,
        auditDataRoot: auditDataRoot,
        operationStore: dataRoot.map { MacControlOperationStore(dataRoot: $0) },
        permissionDataRoot: dataRoot ?? defaultDataRoot()
    )
}
