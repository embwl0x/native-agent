import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - SwiftNative impl

private final class MacControlOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var didResolve = false
    private var continuation: CheckedContinuation<Value, Never>?

    func resolve(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>?
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            return
        }
        didResolve = true
        waiter = continuation
        continuation = nil
        if waiter == nil {
            self.value = value
        }
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didResolve, let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private enum MacControlExecutionSignal: @unchecked Sendable {
    case result(Result<MacControlResult, Error>)
    case deadline
    case cancellationRequested
}

private enum MacControlBoundedResult: @unchecked Sendable {
    case result(Result<MacControlResult, Error>)
    case elapsed
}

private final class MacControlInFlightExecution: @unchecked Sendable {
    let task: Task<MacControlResult, Error>
    private let signal = MacControlOneShot<MacControlExecutionSignal>()

    init(task: Task<MacControlResult, Error>) {
        self.task = task
    }

    func wait() async -> MacControlExecutionSignal { await signal.wait() }
    func finish(_ result: Result<MacControlResult, Error>) { signal.resolve(.result(result)) }

    func requestCancellation() {
        signal.resolve(.cancellationRequested)
        task.cancel()
    }

    func reachDeadline() {
        signal.resolve(.deadline)
        task.cancel()
    }
}

private final class MacControlInFlightRegistry: @unchecked Sendable {
    static let shared = MacControlInFlightRegistry()
    private let lock = NSLock()
    private var executions: [String: MacControlInFlightExecution] = [:]

    func insert(_ execution: MacControlInFlightExecution, operationId: String) {
        lock.lock()
        executions[operationId] = execution
        lock.unlock()
    }

    func remove(operationId: String) {
        lock.lock()
        executions.removeValue(forKey: operationId)
        lock.unlock()
    }

    func execution(operationId: String) -> MacControlInFlightExecution? {
        lock.lock()
        defer { lock.unlock() }
        return executions[operationId]
    }
}

public actor SwiftNativeMacControl: MacControlClient {
    private let now: @Sendable () -> Date
    private let notificationCenterAdapter: NotificationCenterAdapter
    private let appleScriptAdapter: AppleScriptAdapter
    private let processAdapter: ProcessAdapter
    private let fileManagerAdapter: FileManagerAdapter
    private let appControlAdapter: AppControlAdapter
    /// Read-only accessibility perception seam (W1). Production reads live
    /// AXUIElement state; tests inject a synthetic tree so the caps and the
    /// ranking are pinned without a window server.
    private let accessibilitySource: any MacAXElementSource
    /// W2 — the physical input seam (CGEvent). Production posts real events at
    /// the HID tap; tests inject a recorder so no test ever moves the real
    /// mouse or keyboard. Deliberately separate from `accessibilitySource`:
    /// the read seam has no member that can emit anything.
    private let eventSink: any MacEventSink
    /// W3 — the semantic act seam (AXUIElementPerformAction / SetAttributeValue),
    /// again separate from the read seam so perception stays provably
    /// injection-free.
    private let accessibilityActSource: any MacAXActSource
    /// W3.5 — the picture half of the fused view. Screen Recording is its OWN
    /// TCC permission; this seam only ever PREFLIGHTS it (never prompts, never
    /// toggles) and reports the answer honestly.
    private let screenCaptureSource: any MacScreenCaptureSource
    /// W3.5 — set-of-marks renderer. Injectable so the placement math and the
    /// byte budget are pinned with no window server in the loop.
    private let screenImageRenderer: any MacScreenImageRenderer
    /// W3.5 — the latest fused view, so a later `mark` resolves to a real
    /// element. A mark is a REFERENCE ONLY: every injection gate still runs.
    private let screenViewStore: MacScreenViewStore
    /// Explicit, bounded continuity over fused views. The source installs no
    /// observers until `mac_attention start`; the store is shared because the
    /// dispatcher constructs a short-lived MacControl client per tool call.
    private let attentionEventSource: any MacAttentionEventSource
    private let attentionStore: MacAttentionSessionStore
    /// W6 — the login-session probe `wake` refuses on. Injectable so the
    /// locked-refusal is pinned without a real password lock in the loop, and
    /// deliberately separate from the event sink: the thing that DECIDES
    /// whether to post must not be the thing that posts.
    private let sessionStateSource: any MacSessionStateSource
    /// Optional live-policy source for the in-process gate pre-flight
    /// (wave 30 W01). `nil` ⇒ pre-flight disabled ⇒ wave-29 behavior. The
    /// daemon remains the execution/approval/receipt authority regardless.
    private let policyProvider: (any MacControlPolicyProvider)?
    /// Optional path to the daemon's `mac_control_audit.jsonl` (wave 32 W03,
    /// CUTOVER_PLAN §6.55 prereq #4). When non-nil AND a gate pre-flight
    /// REFUSES an action in-process, the refusal is appended to this file as a
    /// `_blocked_receipt`-equivalent JSONL row UNDER the shared cross-process
    /// flock — mirroring the daemon's `MacControl._blocked_receipt`
    /// → `_append_audit` write so a Swift-side refusal is
    /// auditable identically to a daemon-side one. `nil` ⇒ no Swift-side audit
    /// write (the wave-31 behavior): the refusal is still correctly SHAPED
    /// (403/blocked), just not logged from Swift. The daemon remains the
    /// execution / approval / receipt authority; this only adds the refusal row.
    private let auditAppendPath: URL?
    private let persistence = SwiftNativePersistenceCore()
    private let operationStore: MacControlOperationStore?

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        notificationCenterAdapter: NotificationCenterAdapter = SystemNotificationCenterAdapter(),
        appleScriptAdapter: AppleScriptAdapter = SystemAppleScriptAdapter(),
        processAdapter: ProcessAdapter = SystemProcessAdapter(),
        fileManagerAdapter: FileManagerAdapter = SystemFileManagerAdapter(),
        appControlAdapter: AppControlAdapter = SystemAppControlAdapter(),
        accessibilitySource: any MacAXElementSource = defaultMacAXElementSource(),
        eventSink: any MacEventSink = defaultMacEventSink(),
        accessibilityActSource: any MacAXActSource = defaultMacAXActSource(),
        screenCaptureSource: any MacScreenCaptureSource = defaultMacScreenCaptureSource(),
        screenImageRenderer: any MacScreenImageRenderer = defaultMacScreenImageRenderer(),
        screenViewStore: MacScreenViewStore = .shared,
        attentionEventSource: any MacAttentionEventSource = defaultMacAttentionEventSource(),
        attentionStore: MacAttentionSessionStore = .shared,
        sessionStateSource: any MacSessionStateSource = defaultMacSessionStateSource(),
        policyProvider: (any MacControlPolicyProvider)? = nil,
        auditAppendPath: URL? = nil,
        operationStore: MacControlOperationStore? = nil
    ) {
        _ = http
        self.now = now
        self.notificationCenterAdapter = notificationCenterAdapter
        self.appleScriptAdapter = appleScriptAdapter
        self.processAdapter = processAdapter
        self.fileManagerAdapter = fileManagerAdapter
        self.appControlAdapter = appControlAdapter
        self.accessibilitySource = accessibilitySource
        self.eventSink = eventSink
        self.accessibilityActSource = accessibilityActSource
        self.screenCaptureSource = screenCaptureSource
        self.screenImageRenderer = screenImageRenderer
        self.screenViewStore = screenViewStore
        self.attentionEventSource = attentionEventSource
        self.attentionStore = attentionStore
        self.sessionStateSource = sessionStateSource
        self.policyProvider = policyProvider
        self.auditAppendPath = auditAppendPath
        self.operationStore = operationStore
    }

    /// THE PUBLIC API — and deliberately the UNPRIVILEGED one.
    ///
    /// W2/W3-FIX 1: this signature has no parameter that can carry an injection
    /// authorization, and it refuses every injection action outright. That is
    /// the whole point: the HTTP / iOS bridge, the app's direct MacControl
    /// callers, the model's own tool arguments and any raw
    /// `SwiftToolDispatcher` all reach the executor through here, so making the
    /// refusal a property of the SIGNATURE means none of them can inject no
    /// matter what they put in `body`. Approved injection has its own entry
    /// point, `dispatchApprovedInjection(action:body:capability:)`, which needs
    /// a `MacInjectionCapability` — a type with a private init that cannot be
    /// parsed from JSON.
    public func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        try await dispatchCore(action: action, body: body, capability: nil)
    }

    /// The ONLY path that synthesizes input. `capability` must be a live,
    /// unspent `MacInjectionCapability` minted from a resolved human approval
    /// and bound to this exact action and body.
    ///
    /// Every gate the read/act path already had still runs underneath
    /// (master + accessibility category, ACTIVE Full Mac window, TCC): the
    /// capability is an ADDITIONAL requirement, never a bypass.
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
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !macControlDispatchableActions.contains(normalized) {
            throw MacControlError.unknownAction(normalized)
        }
        // Belt and braces on the retired marker: if any stale caller (or a
        // model that read an old prompt) still sends `__mac_injection_approved`,
        // it is a plain dictionary key with no meaning anywhere in this file —
        // drop it so it can never be revived by a future reader as "evidence".
        var body = rawBody
        body.removeValue(forKey: "__mac_injection_approved")

        // GATE 3 of 3 — the APPROVAL tier, resolved here at the entry point so
        // there is exactly one place to read for "can this call inject".
        // USER 2026-08-12 — YOLO: "Nothing should be approval gated for her.
        // Nothing." When no capability is supplied, this entry point now mints
        // one for the call instead of refusing. Full Mac + the accessibility
        // category + the macOS TCC grant are still checked below and still gate
        // every one of these actions; what is gone is the per-call approval
        // prompt, which made them dead on any non-interactive surface (bridge,
        // scheduler, while User is away) — exactly when he needs her to act.
        // To restore: delete the `?? MacInjectionCapability.mint(...)` fallback.
        if macControlAccessibilityInjectionActions.contains(normalized) {
            let capability = capability ?? MacInjectionCapability.mint(
                approvalID: "yolo-\(UUID().uuidString)",
                action: normalized,
                body: body,
                now: now()
            )
            guard let capability else {
                return await injectionApprovalRefusal(
                    action: normalized,
                    reason: "approval_not_granted: \(normalized) requires an approved injection request",
                    body: body
                )
            }
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
            // A capability handed to a non-injection action is a programming
            // error, not an escalation — but fail loudly rather than silently
            // widening what a capability means.
            throw MacControlError.unknownAction(normalized)
        }

        guard let operationStore else {
            return try await executeAction(normalized, body: body)
        }
        let operationId = body.stringValue("operationId")
            ?? body.stringValue("operation_id")
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
                viaSwift: true,
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
            let record = try await operationStore.transition(
                operationId: operationId,
                to: .refused,
                verification: .notRequired,
                expectedNextEvidence: nil,
                outcomeCode: "policy_refused"
            )
            return Self.attachingOperation(refused, record: record)
        }

        _ = try await operationStore.transition(
            operationId: operationId,
            to: .started,
            verification: .pending,
            expectedNextEvidence: "Mac Control terminal result"
        )
        let task = Task<MacControlResult, Error> {
            try await self.executeAction(normalized, body: operationBody, gateAlreadyChecked: true)
        }
        let execution = MacControlInFlightExecution(task: task)
        Task { execution.finish(await task.result) }
        let deadlineTask = Task<Void, Never> {
            // Process-backed handlers own the exact timeout themselves. A
            // short grace lets their typed `timedOut` result win. If an adapter
            // cannot acknowledge cancellation within the bounded settlement
            // grace below, the operation becomes explicitly outcome-unknown.
            let nanos = UInt64(timeoutSeconds) * 1_000_000_000 + 250_000_000
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            guard !Task.isCancelled else { return }
            execution.reachDeadline()
        }
        MacControlInFlightRegistry.shared.insert(execution, operationId: operationId)
        defer {
            deadlineTask.cancel()
            MacControlInFlightRegistry.shared.remove(operationId: operationId)
        }
        let signal = await withTaskCancellationHandler {
            await execution.wait()
        } onCancel: {
            execution.requestCancellation()
        }
        switch signal {
        case .result(let result):
            return try await finishKnownOperationResult(
                result,
                action: normalized,
                operationId: operationId,
                trigger: .ordinary
            )
        case .deadline:
            if let result = await Self.boundedResult(of: task) {
                return try await finishKnownOperationResult(
                    result,
                    action: normalized,
                    operationId: operationId,
                    trigger: .deadline
                )
            }
            return try await finishUnknownOperation(
                action: normalized,
                operationId: operationId,
                outcomeCode: "deadline_effect_unknown"
            )
        case .cancellationRequested:
            if let result = await Self.boundedResult(of: task) {
                return try await finishKnownOperationResult(
                    result,
                    action: normalized,
                    operationId: operationId,
                    trigger: .cancellation
                )
            }
            return try await finishUnknownOperation(
                action: normalized,
                operationId: operationId,
                outcomeCode: "cancel_effect_unknown"
            )
        }
    }

    public func cancel(operationId: String) async throws -> MacControlCancellationResult {
        guard let operationStore else {
            throw MacControlError.operation("canonical operation store is not configured")
        }
        guard let current = try await operationStore.record(operationId: operationId) else {
            throw MacControlError.operation("operation not found")
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
        // The dispatch owner, not the requester, decides whether the work
        // actually stopped, raced to a real completion, or became unknowable.
        // Wait only for the bounded settlement grace; never hang the cancel
        // requester on an adapter that ignores cooperative cancellation.
        var terminal = try await operationStore.record(operationId: operationId)
        for _ in 0..<300 where terminal?.state == .cancelRequested {
            try await Task.sleep(nanoseconds: 5_000_000)
            terminal = try await operationStore.record(operationId: operationId)
        }
        return MacControlCancellationResult(
            operationId: operationId,
            state: terminal?.state ?? .cancelRequested,
            acknowledged: terminal?.state == .cancelAcknowledged
        )
    }

    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        try await operationStore?.motorActionReadModel(actionId: actionId)
    }

    private func executeAction(
        _ normalized: String,
        body: [String: JSONValue],
        gateAlreadyChecked: Bool = false
    ) async throws -> MacControlResult {
        // GATE PRE-FLIGHT (wave 30 W01). When a live policy is available, run
        // the W4 MacControlGate read-only refusal pipeline IN-PROCESS, in the
        // EXACT order the daemon does (_gate master/remote/category → file
        // policy for file_ops), reproducing byte-identical refusal strings.
        // On refusal we short-circuit BEFORE the native handler:
        // a 403-shaped result with viaSwift:true. This is purely subtractive
        // (it can only REFUSE earlier; it never grants what the daemon would
        // deny) so it is safe even with the daemon still owning execution,
        // approval, receipts, and TCC-bridge attribution.
        if !gateAlreadyChecked {
            let outcome = await gatePreflightOutcome(action: normalized, body: body)
            switch outcome {
            case .refuse(let result):
                return result
            case .proceed:
                break
            }
        }
        // An active attention session gives physical human input absolute
        // priority. Check once at tool entry; handlers recheck at the exact
        // effect boundary (and between multi-event gestures) so a mouse move
        // arriving after this line still stops the action.
        if macControlAccessibilityInjectionActions.contains(normalized)
            || macControlAccessibilityNudgeActions.contains(normalized),
           let refusal = await attentionActionRefusal(action: normalized, body: body) {
            return refusal
        }
        switch normalized {
        case "notify":      return try await handleNotify(body)
        case "file/read":   return try await handleFileRead(body)
        case "file/write":  return try await handleFileWrite(body)
        case "file/list":   return try await handleFileList(body)
        case "file/move":   return try await handleFileMove(body)
        case "file/trash":  return try await handleFileTrash(body)
        case "applescript": return try await handleAppleScript(body)
        case "focus_app":   return try await handleFocusApp(body)
        case "quit_app":    return try await handleQuitApp(body)
        case "spotlight":   return try await handleSpotlight(body)
        case "shell":       return try await handleShell(body)
        case "ax_status":   return handleAXStatus()
        case "ax_tree":     return handleAXTree(body)
        case "ax_find":     return try handleAXFind(body)
        // W3.5 — THE FUSED VIEW. Read tier like the three above: it looks at
        // the screen (AX structure + pixels) and changes nothing.
        case "view":        return await handleView(body)
        case "attention":   return await handleAttention(body)
        // W2/W3 — INJECTION. Every one of these is behind the three-gate
        // predicate in `gatePreflightOutcome` (category + active Full Mac +
        // approval attestation) before control ever arrives here.
        case "keystroke":   return await handleKeystroke(body)
        case "click":       return await handleClick(body)
        case "scroll":      return await handleScroll(body)
        case "ax_act":      return await handleAXAct(body)
        // W6 — the nudge + re-capture. Injection like the four above (it posts
        // HID events), with one extra refusal of its own: a real password lock.
        case "wake":        return await handleWake(body)
        // W7 — the NUDGE. Reached through the unprivileged `dispatch` like the
        // reads above, not through `dispatchApprovedInjection`: it emits one
        // bare mouse move and nothing else.
        case "nudge":       return await handleNudge(body)
        case let action where macControlUnsupportedActions.contains(action):
            return Self.unsupportedResult(action: action)
        default:
            // Defensive — guarded by macControlAllActions check above.
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
        if case .double(let value) = body["timeout"] ?? .null, value.isFinite {
            return max(1, min(Int(value), 120))
        }
        switch action {
        case "spotlight": return 10
        // In-process AX reads; nothing here waits on another process.
        case "ax_status", "ax_tree", "ax_find": return 15
        // W3.5 — one AX walk plus one ScreenCaptureKit screenshot + encode.
        // Still in-process, but the capture is the slowest read here.
        case "view": return 20
        // Event-driven wait is caller-bounded to 15s, followed by one view.
        case "attention": return 40
        // In-process CGEvent / AX act; nothing here waits on another process.
        case "keystroke", "click", "scroll", "ax_act": return 15
        // W7 — one CGEvent post, in-process, nothing awaited.
        case "nudge": return 15
        // W6 — a nudge, a bounded settle wait, then a full `view` capture.
        case "wake": return 30
        case "shell": return 60
        default: return 90
        }
    }

    private enum OperationSettlementTrigger: Equatable {
        case ordinary
        case deadline
        case cancellation
    }

    /// Cancellation is cooperative for several AppKit / Apple-event adapters.
    /// Wait briefly for a real terminal observation, then stop pretending the
    /// effect is known. The durable unknown state blocks automatic replay.
    private static let settlementGraceNanoseconds: UInt64 = 500_000_000

    private static func boundedResult(
        of task: Task<MacControlResult, Error>
    ) async -> Result<MacControlResult, Error>? {
        let result = MacControlOneShot<MacControlBoundedResult>()
        Task {
            result.resolve(.result(await task.result))
        }
        let timer = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: settlementGraceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            result.resolve(.elapsed)
        }
        let settled = await result.wait()
        timer.cancel()
        switch settled {
        case .result(let value): return value
        case .elapsed: return nil
        }
    }

    private func finishKnownOperationResult(
        _ executionResult: Result<MacControlResult, Error>,
        action: String,
        operationId: String,
        trigger: OperationSettlementTrigger
    ) async throws -> MacControlResult {
        guard let operationStore else {
            return try executionResult.get()
        }
        if let current = try await operationStore.record(operationId: operationId),
           current.state.isTerminal {
            if current.state == .outcomeUnknown {
                return Self.unknownResult(action: action, record: current)
            }
            return Self.replayResult(current)
        }

        switch executionResult {
        case .success(let result):
            if Self.resultTimedOut(result) {
                let record = try await operationStore.transition(
                    operationId: operationId,
                    to: .timedOut,
                    verification: .failed,
                    expectedNextEvidence: nil,
                    outcomeCode: "timeout"
                )
                return Self.attachingOperation(result, record: record)
            }
            let verification = Self.verificationState(action: action, result: result)
            let record = try await operationStore.transition(
                operationId: operationId,
                to: result.ok ? .completed : .failed,
                verification: verification,
                expectedNextEvidence: result.ok && verification != .satisfied
                    ? "Separate observation of intended effect"
                    : nil,
                outcomeCode: Self.exitOutcomeCode(result) ?? (result.ok ? "completed" : "handler_failed")
            )
            return Self.attachingOperation(result, record: record)

        case .failure(let error):
            if error is CancellationError {
                if trigger == .deadline {
                    let record = try await operationStore.transition(
                        operationId: operationId,
                        to: .timedOut,
                        verification: .failed,
                        expectedNextEvidence: nil,
                        outcomeCode: "deadline_exceeded_after_stop"
                    )
                    return Self.timeoutResult(action: action, record: record)
                }
                if try await operationStore.record(operationId: operationId)?.state == .started {
                    _ = try await operationStore.transition(
                        operationId: operationId,
                        to: .cancelRequested,
                        verification: .pending,
                        expectedNextEvidence: "Cancellation acknowledgement",
                        outcomeCode: "cancel_requested"
                    )
                }
                let record = try await operationStore.transition(
                    operationId: operationId,
                    to: .cancelAcknowledged,
                    verification: .failed,
                    expectedNextEvidence: nil,
                    outcomeCode: "cancelled_before_effect_completion"
                )
                return Self.cancelledResult(action: action, record: record)
            }
            _ = try await operationStore.transition(
                operationId: operationId,
                to: .failed,
                verification: .failed,
                expectedNextEvidence: nil,
                outcomeCode: "execution_failed"
            )
            throw error
        }
    }

    private func finishUnknownOperation(
        action: String,
        operationId: String,
        outcomeCode: String
    ) async throws -> MacControlResult {
        guard let operationStore else {
            throw MacControlError.operation("canonical operation store is not configured")
        }
        if let current = try await operationStore.record(operationId: operationId),
           current.state.isTerminal {
            return current.state == .outcomeUnknown
                ? Self.unknownResult(action: action, record: current)
                : Self.replayResult(current)
        }
        let record = try await operationStore.transition(
            operationId: operationId,
            to: .outcomeUnknown,
            verification: .unknown,
            expectedNextEvidence: "Separate observation of intended effect; do not retry automatically",
            outcomeCode: outcomeCode
        )
        return Self.unknownResult(action: action, record: record)
    }

    private static func attachingOperation(
        _ result: MacControlResult,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: result.ok,
            action: result.action,
            output: result.output,
            error: result.error,
            durationMs: result.durationMs,
            viaSwift: result.viaSwift,
            httpStatus: result.httpStatus,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    private static func replayResult(_ record: MacControlOperationRecord) -> MacControlResult {
        let ok = record.state == .completed
        let status: Int?
        switch record.state {
        case .blocked, .refused: status = 403
        case .timedOut: status = 408
        case .outcomeUnknown: status = 409
        case .failed: status = 500
        default: status = nil
        }
        return MacControlResult(
            ok: ok,
            action: record.action,
            output: .object([
                "status": .string("idempotent_replay"),
                "operation_state": .string(record.state.rawValue),
            ]),
            error: ok ? nil : record.outcomeCode,
            durationMs: 0,
            viaSwift: true,
            httpStatus: status,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    private static func unknownResult(
        action: String,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "status": .string("outcome_unknown"),
                "retryable": .bool(false),
            ]),
            error: "Mac Control stopped waiting, but the external effect could not be verified; do not retry automatically",
            durationMs: 0,
            viaSwift: true,
            httpStatus: 409,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    private static func cancelledResult(
        action: String,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object(["status": .string("cancel_acknowledged")]),
            error: "cancelled",
            durationMs: 0,
            viaSwift: true,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    private static func timeoutResult(
        action: String,
        record: MacControlOperationRecord
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "status": .string("timed_out"),
                "timed_out": .bool(true),
            ]),
            error: "Mac Control deadline exceeded",
            durationMs: 0,
            viaSwift: true,
            httpStatus: 408,
            operationId: record.operationId,
            operationState: record.state,
            verification: record.verification
        )
    }

    private static func resultTimedOut(_ result: MacControlResult) -> Bool {
        guard case .object(let object) = result.output,
              case .bool(let timedOut)? = object["timed_out"] else { return false }
        return timedOut
    }

    private static func exitOutcomeCode(_ result: MacControlResult) -> String? {
        guard case .object(let object) = result.output,
              case .int(let exit)? = object["exit_code"] else { return nil }
        return "exit_\(exit)"
    }

    private static func verificationState(
        action: String,
        result: MacControlResult
    ) -> MotorVerificationState {
        if resultTimedOut(result) || !result.ok { return .failed }
        if case .object(let object) = result.output,
           case .bool(let verified)? = object["verified"] {
            return verified ? .satisfied : .unverified
        }
        switch action {
        case "file/read", "file/list", "spotlight", "ax_status", "ax_tree", "ax_find", "view":
            return .satisfied
        case "notify", "file/write", "file/move", "file/trash", "focus_app", "quit_app", "applescript", "shell":
            return .unverified
        // W2/W3 injection. UNVERIFIED on purpose, including `ax_act`: the
        // handler re-reads the element afterwards and returns that post-state,
        // but "I read the element again" is not proof the app's handler ran or
        // that the intended consequence happened. Claiming `satisfied` here
        // would manufacture settlement evidence out of a second read.
        case "keystroke", "click", "scroll", "ax_act":
            return .unverified
        // W6 `wake` never reaches here: it always publishes its own `verified`
        // flag above, decided by RE-READING the session after the nudge rather
        // than by having posted one. Listed so the intent survives a refactor.
        case "wake":
            return .unverified
        // W7 `nudge` — UNVERIFIED, deliberately. It posted a move; whether the
        // window server woke a display or dismissed a saver is not something a
        // move-only tool observes, and it does not probe the session to find
        // out. Claiming `satisfied` would be manufacturing evidence.
        case "nudge":
            return .unverified
        default:
            return .notRequired
        }
    }

    // MARK: gate pre-flight (wave 30 W01)

    /// Outcome of the gate pre-flight. Distinguishes the three states the
    /// dispatcher must handle differently:
    ///   • `.refuse`            — gate denied; return the 403-shaped result.
    ///   • `.proceed`           — gate allowed (or no provider / self_test):
    ///                            continue to the native/unsupported path.
    private enum GatePreflightOutcome {
        case refuse(MacControlResult)
        case proceed
    }

    private static let developerModeOnlyActions: Set<String> = [
        "file/move",
        "file/trash",
        "shell",
        "system",
    ]

    /// Run the W4 `MacControlGate` read-only refusal pipeline in-process.
    ///
    /// Order mirrors the daemon method bodies exactly:
    ///   1. `_gate(category, trigger)` — master → remote_ios → per-category.
    ///   2. For file_ops actions only: `_file_policy_reason(paths…)`.
    ///      (`_sensitive_path_reason` is already enforced by the native file
    ///      handlers' fence; the gate adds the workspace/full-mac file-policy
    ///      layer the fence omits.)
    ///
    /// We do NOT reproduce approval-queue (202), risk-gate session caching,
    /// validate_tool_args, receipt persistence, or TCC-bridge attribution —
    /// those stay daemon-owned. This is strictly a fast-refuse layer.
    private func gatePreflightOutcome(
        action: String,
        body: [String: JSONValue]
    ) async -> GatePreflightOutcome {
        // GATE 3 of 3 for injection — the APPROVAL tier — is enforced at the
        // ENTRY POINT (`dispatchCore`), not here, because it is now a property
        // of which function you called and what capability you held, not of the
        // body's contents. By the time an injection action reaches this
        // pre-flight it has already presented a live, body-bound, single-use
        // `MacInjectionCapability`. The remaining two gates below still apply
        // to it in full.
        //
        // No provider configured: tests and direct library callers can exercise
        // handlers in isolation. Production wires a Swift TrustCenter provider.
        guard let provider = policyProvider else { return .proceed }
        guard let category = macControlGateCategory(forAction: action) else {
            // self_test / unmapped: no single category to pre-gate. Unsupported
            // actions fail closed after this pre-flight.
            return .proceed
        }
        guard let policy = await provider.currentPolicy() else {
            return .refuse(Self.refusalResult(
                action: action,
                reason: "mac_control_policy_unavailable: Swift trust policy could not be resolved",
                now: now
            ))
        }
        let trigger = body.stringValue("trigger").flatMap { $0.isEmpty ? nil : $0 } ?? "user"

        let decision = MacControlGate.gate(policy, category: category, trigger: trigger)
        if !decision.allowed {
            let result = Self.refusalResult(action: action, reason: decision.reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: decision.reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        // gpt-5.5 BLOCKING (2026-08-12): the accessibility READ actions must also
        // require an ACTIVE Full Mac trust window, exactly as the model-tool path
        // does (accessibilityReadAllowed = fullMacActive && accessibility_allowed).
        // The category gate above checks only `accessibility_allowed`; without
        // this, the HTTP / iOS-remote bridge (`/v1/mac_control/ax_tree`) could
        // read the on-screen UI tree under an EXPIRED or never-confirmed Full Mac
        // window — a privilege the same category never grants through chat. This
        // is scoped to the Swift-native AX reads this wave added; the two
        // daemon-parity app-control actions keep their existing bridge behavior.
        //
        // W2/W3 (2026-08-12): the INJECTION actions carry the same Full Mac
        // requirement, for a strictly stronger reason — they type and click.
        //
        // W7 (2026-08-12): `nudge` carries the SAME Full Mac requirement as the
        // reads, for the same reason and by the same rule — the accessibility
        // category alone must not be reachable through the bridge under an
        // expired window. It is named through its own set rather than folded
        // into either neighbour, so neither of their contracts has to bend.
        if macControlAccessibilityReadActions.contains(action)
            || macControlAccessibilityNudgeActions.contains(action)
            || macControlAccessibilityInjectionActions.contains(action),
           !(policy.trustPolicy.map { MacControlGate.fullMacActive($0, now: now()) } ?? false) {
            let reason = "full_mac_inactive: \(action) requires an active Full Mac trust window"
            let result = Self.refusalResult(action: action, reason: reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        // file_ops: run the W4 file-policy layer (workspace roots + full-mac
        // window). This reproduces `_file_policy_reason` with byte-identical
        // refusal strings (the W4 port).
        //
        // ORDERING PARITY (W01 round-1 self-review): the daemon checks
        // `_sensitive_path_reason` BEFORE `_file_policy_reason` (read_file
        // L856-859, write_file L894-897, move_file L938-941), so for a path
        // that is BOTH sensitive AND outside-workspace, Python surfaces the
        // SENSITIVE reason. We deliberately do NOT emit the Swift fence's
        // sensitive reason here — its root-form string diverges from the
        // daemon's fully-resolved-root string (a pre-existing wave-29 fence
        // gap). Instead, when a path is sensitive we SKIP the pre-flight
        // file-policy refusal and let it fall through: the native handler's
        // own fence then surfaces the authoritative sensitive reason. This
        // keeps the pre-flight emitting ONLY the verbatim-parity file-policy
        // string, never a divergent sensitive string, while preserving the
        // "sensitive wins over file-policy" precedence.
        let pathKeys = macControlFilePolicyPathKeys(forAction: action)
        if !pathKeys.isEmpty {
            let paths: [String] = pathKeys.compactMap { key in
                guard let v = body.stringValue(key), !v.isEmpty else { return nil }
                return v
            }
            let anySensitive = paths.contains { MacControlSensitivePathFence.reason(forPath: $0) != nil }
            if !anySensitive, !paths.isEmpty,
               let reason = MacControlGate.fileReason(policy, forPaths: paths, now: now()) {
                let result = Self.refusalResult(action: action, reason: reason, now: now)
                await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
                return .refuse(result)
            }
        }
        if Self.developerModeOnlyActions.contains(action),
           !MacControlGate.destructiveActionsAllowed(policy.trustPolicy) {
            let reason = "developer_mode_required: \(action) requires Developer Mode"
            let result = Self.refusalResult(action: action, reason: reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        return .proceed
    }

    /// Build the 403-shaped refusal result. `viaSwift:true` (the refusal was
    /// decided in-process); `httpStatus:403` so NativeClient surfaces a real
    /// 403 to the UI rather than collapsing it. `output.error` carries the
    /// gate reason verbatim so callers can render the daemon-parity message.
    private static func refusalResult(
        action: String,
        reason: String,
        now: @Sendable () -> Date
    ) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("blocked"),
                "error": .string(reason),
                "block_reason": .string(reason),
                "blocked_by": .string("swift_gate_preflight"),
            ]),
            error: reason,
            durationMs: 0,
            viaSwift: true,
            httpStatus: 403
        )
    }

    private static func unsupportedResult(action: String) -> MacControlResult {
        let error = "unsupported_mac_control_action: \(action) is not implemented in Swift"
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("unsupported"),
                "error": .string(error),
                "dispatched_via": .string("swift"),
            ]),
            error: error,
            durationMs: 0,
            viaSwift: true,
            httpStatus: 501
        )
    }

    // MARK: blocked-receipt audit append (wave 32 W03 — CUTOVER §6.55 prereq #4)

    /// Maps a dispatch sub-action to the daemon METHOD name that
    /// `MacControl._blocked_receipt` passes as `method=` (mac_control.py call
    /// sites). Used so a Swift-side refusal audit row carries the SAME `method`
    /// field a daemon-side refusal would, keeping `mac_control_audit.jsonl`
    /// consumers (the GET `/v1/mac_control/audit` reader, any analytics) unable
    /// to tell which process logged the row. Verified against the
    /// `self._blocked_receipt("<method>", "<category>", …)` calls in each
    /// daemon method.
    private static func daemonMethodName(forAction action: String, body: [String: JSONValue]) -> String {
        switch action {
        case "applescript":   return "run_applescript"
        case "jxa":           return "run_jxa"
        case "shortcut",
             "shortcut/run":  return "run_shortcut"
        case "focus_app":     return "focus_app"
        case "quit_app":      return "quit_app"
        case "keystroke":     return "keystroke"
        // No daemon ancestor (W1 Swift-native reads). The audit row still
        // wants a stable method name, so it is the action itself.
        case "ax_status":     return "ax_status"
        case "ax_tree":       return "ax_tree"
        case "ax_find":       return "ax_find"
        case "view":          return "view"
        case "wake":          return "wake"
        case "nudge":         return "nudge"
        case "scroll":        return "scroll"
        case "ax_act":        return "ax_act"
        case "click":         return "click_at"
        case "system":        return systemMethodName(body: body)
        case "file/read":     return "read_file"
        case "file/write":    return "write_file"
        case "file/list":     return "list_directory"
        case "file/move":     return "move_file"
        case "file/trash":    return "trash_file"
        case "notify":        return "post_notification"
        case "shell":         return "run_shell"
        case "spotlight":     return "spotlight_search"
        default:              return action
        }
    }

    /// `/v1/mac_control/system` has NO single daemon method — it fans out to
    /// `set_volume` / `set_brightness` / `sleep_display` / `lock_screen` /
    /// `set_focus_mode` based on the request body's `action` field, and each of
    /// those is the method `_blocked_receipt` records (the retired daemon/839/
    /// 859/870/882). Resolve the concrete method from the body's `action`,
    /// mirroring the daemon route's `_sys_action_id_map`
    ///. Unknown / missing action → `"system"` (the
    /// daemon route would 400 such a request before it ever reached a method;
    /// the generic label is the only honest value when there is no daemon method).
    private static func systemMethodName(body: [String: JSONValue]) -> String {
        let action: String = {
            if case .string(let s)? = body["action"] { return s }
            return ""
        }()
        switch action {
        case "volume", "set_volume": return "set_volume"
        case "brightness":           return "set_brightness"
        case "sleep_display":        return "sleep_display"
        case "lock_screen":          return "lock_screen"
        case "focus_mode":           return "set_focus_mode"
        default:                     return "system"
        }
    }

    /// Byte-faithful port of daemon `MacControl._approval_required(category)`
    ///. Records the SAME `approval_required` value the
    /// daemon's `_blocked_receipt` would write for this refusal:
    ///   • when the live policy carries `approval_required_for`
    ///     (`policy.approvalRequiredFor != nil`), use it verbatim, EXCEPT the
    ///     daemon's `shell` special-case: `"shell" in policy.get(
    ///     "approval_required_for", ["shell"])`. Because the key IS present
    ///     here, the `["shell"]` default does not apply — shell follows the
    ///     list like any other category. (The Python `["shell"]` fallback only
    ///     fires when the key is ABSENT; that maps to the `nil` branch below.)
    ///   • when absent (`nil`): shell → `["shell"]` default ⇒ true; every other
    ///     category → `[]` default ⇒ false. Reproduced exactly.
    private static func approvalRequired(forCategory category: String, policy: MacControlPolicy) -> Bool {
        guard let list = policy.approvalRequiredFor else {
            // Key absent: daemon defaults `shell` → ["shell"], others → [].
            return category == "shell"
        }
        return list.contains(category)
    }

    /// Append a `_blocked_receipt`-equivalent row to `mac_control_audit.jsonl`
    /// under the shared cross-process flock. No-op when `auditAppendPath` is
    /// nil. Best-effort: a write failure is swallowed exactly as the daemon's
    /// `_append_audit` swallows its `except Exception: pass` — the refusal
    /// itself already succeeded; failing to log it must never turn a blocked
    /// action into an executed one.
    ///
    /// Record shape mirrors daemon `make_receipt(method, category, blocked=True,
    /// block_reason=reason, trigger=trigger, approval_required=…)` with
    /// `content` popped (the daemon does `audit_r.pop("content", None)` before
    /// `_append_audit`; blocked receipts never carry `content` anyway). Fields:
    ///   id, method, category, args_hash, trigger, trigger_source,
    ///   approval_required, approved(null), exit_code(0), stdout(""),
    ///   stderr(""), duration_ms(0), executed_at, blocked(true), block_reason.
    ///
    /// BYTE-EQUIVALENCE (wave-33 W02, CUTOVER §6.96). The wave-32 W03 mirror was
    /// FUNCTIONALLY equivalent (right fields, parseable) but NOT byte-equivalent:
    ///   1. Key ORDER: the daemon's `_append_audit` does `json.dumps(receipt)`
    ///      with NO `sort_keys`, so keys land in `make_receipt(...)` insertion
    ///      order (`id` first … `block_reason` last). The Swift mirror went
    ///      through `JSONValue.serialize`, which ALWAYS `sort_keys` (alphabetical
    ///      by UTF-8). Different bytes.
    ///   2. EXTRA `logged_by` key the daemon never writes — a 16th field that
    ///      makes the line non-identical even after fixing order.
    ///   3. `executed_at` format: Swift emitted `…Z` + millis; Python's
    ///      `isoformat()` emits `…+00:00` + microseconds (and `Z` is rejected by
    ///      `datetime.fromisoformat` before Python 3.11).
    /// All three are fixed here: emit the EXACT `make_receipt` field order via
    /// `serializeOrderedObjectPython` (insertion-order, Python default
    /// separators), drop `logged_by`, and format the timestamp as `+00:00` with
    /// 6 fractional digits. Python stays the authority — its on-disk format is
    /// unchanged; the Swift writer conforms to it. (Distinguishing the writer is
    /// not lost: a Swift-logged refusal has `approved=null, exit_code=0,
    /// stdout="", stderr="", duration_ms=0` and is, by construction, only ever a
    /// blocked row — identical to the daemon's own `_blocked_receipt`, which is
    /// the whole point of byte-equivalence.)
    private func emitBlockedAudit(
        action: String,
        category: String,
        reason: String,
        trigger: String,
        policy: MacControlPolicy,
        body: [String: JSONValue]
    ) async {
        guard let path = auditAppendPath else { return }
        // EXACT make_receipt(...) insertion order. Emitting
        // via serializeOrderedObjectPython preserves this order (no sort) and
        // uses Python's default compact separators `(', ', ': ')`.
        let orderedPairs: [(String, JSONValue)] = [
            // Python's make_receipt uses `str(uuid.uuid4())`, which is LOWERCASE.
            // Apple Foundation's `UUID().uuidString` is UPPERCASE — a byte
            // divergence; lowercase it for parity. (gpt-5.5 review finding #1.)
            ("id", .string(UUID().uuidString.lowercased())),
            ("method", .string(Self.daemonMethodName(forAction: action, body: body))),
            ("category", .string(category)),
            // make_receipt sets args_hash="sha256:none" when args is None;
            // _blocked_receipt passes no args, so this matches.
            ("args_hash", .string("sha256:none")),
            ("trigger", .string(trigger)),
            ("trigger_source", .string(trigger)),
            ("approval_required", .bool(Self.approvalRequired(forCategory: category, policy: policy))),
            ("approved", .null),
            ("exit_code", .int(0)),
            ("stdout", .string("")),
            ("stderr", .string("")),
            ("duration_ms", .int(0)),
            ("executed_at", .string(Self.iso8601(now()))),
            ("blocked", .bool(true)),
            ("block_reason", .string(reason)),
        ]
        do {
            let line = try JSONValue.serializeOrderedObjectPython(orderedPairs)
            try await persistence.withFileLock(path) {
                try await persistence.appendAuditLineRaw(line, to: path)
                // M6 (2026-07-09): rotate under the SAME flock as the append —
                // the cap does a read-trim-replace and must not race a
                // concurrent writer. Cannot use appendJSONLCapped here: this
                // feed is byte-equivalent to the daemon's `_append_audit` and
                // must go through appendAuditLineRaw, not JSONValue.serialize.
                let dropped = try enforceJSONLLineCap(at: path, maxLines: JSONLLineCaps.macControlAudit)
                if dropped > 0 {
                    NSLog("MacControl.audit: %@ cap dropped %d oldest line(s)",
                          path.lastPathComponent, dropped)
                }
            }
        } catch {
            // Swallow — parity with daemon `_append_audit` best-effort write.
            // The block already happened; an unloggable refusal must stay a refusal.
        }
    }

    /// ISO-8601 UTC timestamp byte-matching Python's
    /// `datetime.now(timezone.utc).isoformat()`:
    /// `YYYY-MM-DDTHH:MM:SS.ffffff+00:00` — `+00:00` offset (NOT `Z`, which
    /// `datetime.fromisoformat` rejects before Python 3.11) and SIX fractional
    /// digits (microseconds). `ISO8601DateFormatter` only emits millis and a `Z`
    /// suffix, so it cannot reproduce this; build the string by hand.
    ///
    /// MICROSECONDS = TRUNCATION, not round-to-nearest (gpt-5.5 review #3):
    /// Python's epoch→`datetime` conversion floors to integer microseconds, so a
    /// round-to-nearest here would differ by 1µs vs the daemon for the same
    /// instant. To keep the second-component and the micros from EVER disagreeing
    /// at a boundary, derive BOTH from one floored microsecond-since-epoch value:
    /// `wholeSeconds = floor(totalMicros / 1e6)`, `micros = totalMicros % 1e6`,
    /// then format the calendar components from `Date(wholeSeconds)`.
    ///
    /// WHOLE-SECOND CASE (gpt-5.5 review #2, round 2): Python's `isoformat()`
    /// defaults to `timespec='auto'`, which OMITS the fractional part entirely
    /// when `microsecond == 0` (`…07+00:00`, not `…07.000000+00:00`). For any
    /// nonzero microsecond it always prints all 6 digits. Mirror that: emit
    /// `.ffffff` only when `micros != 0`.
    private static func iso8601(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        // Floor to integer microseconds (Python truncates, never rounds up).
        let totalMicros = Int64((interval * 1_000_000).rounded(.down))
        let wholeSeconds = totalMicros / 1_000_000
        let micros = Int(totalMicros % 1_000_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Build components from the FLOORED whole-second instant so the printed
        // second and the micros are taken from the same split — no boundary skew.
        let secondsDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: secondsDate
        )
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        if micros == 0 {
            return base + "+00:00"  // timespec='auto' omits the fraction
        }
        return base + String(format: ".%06d+00:00", micros)
    }

    // MARK: notify

    private func handleNotify(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let title = body.stringValue("title") ?? ""
        let message = body.stringValue("message") ?? ""
        let sound = body.stringValue("sound")
        if title.isEmpty && message.isEmpty {
            throw MacControlError.missingField("title or message")
        }
        let started = now()
        do {
            try await notificationCenterAdapter.postNotification(
                title: title,
                message: message,
                soundName: sound
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "notify",
                output: .object(["title": .string(title), "message": .string(message)]),
                error: "notify failed: \(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "notify",
            output: .object([
                "title": .string(title),
                "message": .string(message),
                "sound": sound.map { .string($0) } ?? .null,
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/read

    private func handleFileRead(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        var maxBytes = 1_000_000
        if case .int(let n) = body["max_bytes"] ?? .null {
            maxBytes = max(1, min(Int(n), 1_000_000))
        } else if case .double(let d) = body["max_bytes"] ?? .null {
            maxBytes = max(1, min(Int(d), 1_000_000))
        }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        // TOCTOU shrink: re-resolve right before the syscall + re-fence.
        // Foundation has no O_NOFOLLOW open, so this still leaves a window
        // between resolve and FileManager open — see fence doc comment.
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let content: String
        let rawData: Data
        do {
            rawData = try fileManagerAdapter.readData(at: url, maxBytes: maxBytes)
            // Mirror Python's `errors="replace"`: non-UTF8 bytes become U+FFFD
            // rather than silently producing an empty string.
            content = String(decoding: rawData, as: UTF8.self)
        } catch {
            throw MacControlError.ioFailure("read \(path): \(error)")
        }
        let sha256Hex: String
        #if canImport(CryptoKit)
        sha256Hex = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        #else
        sha256Hex = ""
        #endif
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/read",
            output: .object([
                "path": .string(path),
                "content": .string(content),
                "bytes": .int(Int64(rawData.count)),
                "sha256": .string(sha256Hex),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/write

    private func handleFileWrite(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let content = body.stringValue("content") ?? ""
        var append = false
        if case .bool(let b) = body["append"] ?? .null { append = b }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.writeData(
                Data(content.utf8),
                to: url,
                append: append
            )
        } catch {
            throw MacControlError.ioFailure("write \(path): \(error)")
        }
        let verified: Bool = {
            guard let verifier = fileManagerAdapter as? any FileStateVerificationAdapter,
                  verifier.itemExists(at: url),
                  let observed = try? fileManagerAdapter.readData(at: url, maxBytes: 10_000_000) else {
                return false
            }
            let expected = Data(content.utf8)
            return append ? observed.suffix(expected.count) == expected[...] : observed == expected
        }()
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/write",
            output: .object([
                "path": .string(path),
                "bytes": .int(Int64(content.utf8.count)),
                "append": .bool(append),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/list

    private func handleFileList(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let entries: [URL]
        do {
            entries = try fileManagerAdapter.listDirectory(at: url)
        } catch {
            throw MacControlError.ioFailure("list \(path): \(error)")
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        let names = entries.map { JSONValue.string($0.lastPathComponent) }
        return MacControlResult(
            ok: true,
            action: "file/list",
            output: .object([
                "path": .string(path),
                "entries": .array(names),
                "count": .int(Int64(names.count)),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/move

    private func handleFileMove(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let src = body.stringValue("src"), !src.isEmpty else {
            throw MacControlError.missingField("src")
        }
        guard let dst = body.stringValue("dst"), !dst.isEmpty else {
            throw MacControlError.missingField("dst")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: src) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dst) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let srcURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        let dstURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: srcURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: dstURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: srcURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: dstURL.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.moveItem(from: srcURL, to: dstURL)
        } catch {
            throw MacControlError.ioFailure("move \(src) -> \(dst): \(error)")
        }
        let verified = (fileManagerAdapter as? any FileStateVerificationAdapter)
            .map { !$0.itemExists(at: srcURL) && $0.itemExists(at: dstURL) } ?? false
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/move",
            output: .object([
                "src": .string(src),
                "dst": .string(dst),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: file/trash

    private func handleFileTrash(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let path = body.stringValue("path"), !path.isEmpty else {
            throw MacControlError.missingField("path")
        }
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        let started = now()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            throw MacControlError.sensitivePathDenied(reason)
        }
        do {
            try fileManagerAdapter.trashItem(at: url)
        } catch {
            throw MacControlError.ioFailure("trash \(path): \(error)")
        }
        let verified = (fileManagerAdapter as? any FileStateVerificationAdapter)
            .map { !$0.itemExists(at: url) } ?? false
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "file/trash",
            output: .object([
                "path": .string(path),
                "verified": .bool(verified),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: applescript

    private func handleAppleScript(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let script = body.stringValue("script"), !script.isEmpty else {
            throw MacControlError.missingField("script")
        }
        let started = now()
        let result: String
        do {
            result = try await appleScriptAdapter.run(script: script)
        } catch {
            return MacControlResult(
                ok: false,
                action: "applescript",
                output: .object(["script": .string(String(script.prefix(200)))]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: true,
            action: "applescript",
            output: .object([
                "script": .string(String(script.prefix(200))),
                "stdout": .string(result),
            ]),
            error: nil,
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: focus_app / quit_app

    private func requestedAppName(_ body: [String: JSONValue]) throws -> String {
        let value = body.stringValue("app")
            ?? body.stringValue("name")
            ?? body.stringValue("bundle_id")
            ?? body.stringValue("bundleId")
            ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacControlError.missingField("app")
        }
        return trimmed
    }

    private func handleFocusApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let app = try requestedAppName(body)
        let started = now()
        do {
            let result = try await appControlAdapter.focusApp(named: app)
            let ok = result.activated || result.launched
            let observedFrontmost = await (appControlAdapter as? any AppStateVerificationAdapter)?
                .isFrontmostApplication(matching: app)
            let verified = ok && observedFrontmost == true
            return MacControlResult(
                ok: ok,
                action: "focus_app",
                output: appControlOutput(
                    result,
                    status: ok ? "focused" : "focus_failed",
                    verified: verified
                ),
                error: ok ? nil : "focus_app failed for \(app)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "focus_app",
                output: .object([
                    "requested": .string(app),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    private func handleQuitApp(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let app = try requestedAppName(body)
        let started = now()
        do {
            let result = try await appControlAdapter.quitApp(named: app)
            let ok = result.terminated || result.alreadyInDesiredState
            let observedRunning = await (appControlAdapter as? any AppStateVerificationAdapter)?
                .isApplicationRunning(matching: app)
            let verified = ok && observedRunning == false
            return MacControlResult(
                ok: ok,
                action: "quit_app",
                output: appControlOutput(
                    result,
                    status: ok ? "quit_requested" : "quit_failed",
                    verified: verified
                ),
                error: ok ? nil : "quit_app failed for \(app)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        } catch {
            return MacControlResult(
                ok: false,
                action: "quit_app",
                output: .object([
                    "requested": .string(app),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                error: "\(error)",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    private func appControlOutput(
        _ result: AppControlRunResult,
        status: String,
        verified: Bool
    ) -> JSONValue {
        .object([
            "requested": .string(result.requestedName),
            "matched_name": result.matchedName.map { .string($0) } ?? .null,
            "bundle_identifier": result.bundleIdentifier.map { .string($0) } ?? .null,
            "process_identifier": result.processIdentifier.map { .int(Int64($0)) } ?? .null,
            "launched": .bool(result.launched),
            "activated": .bool(result.activated),
            "terminated": .bool(result.terminated),
            "already_in_desired_state": .bool(result.alreadyInDesiredState),
            "verified": .bool(verified),
            "status": .string(status),
        ])
    }

    // MARK: accessibility perception (W1 — READ-ONLY)

    /// Resolve the caller-supplied bounds, clamped to the hard ceilings by
    /// `MacAXLimits.init`. A caller CANNOT raise the caps, only lower them.
    private static func axLimits(from body: [String: JSONValue]) -> MacAXLimits {
        func intValue(_ key: String) -> Int? {
            switch body[key] ?? .null {
            case .int(let n): return Int(n)
            case .double(let d) where d.isFinite: return Int(d)
            default: return nil
            }
        }
        return MacAXLimits(
            maxNodes: intValue("max_nodes") ?? MacAXLimits.hardMaxNodes,
            maxDepth: intValue("max_depth") ?? MacAXLimits.hardMaxDepth,
            maxMatches: intValue("limit") ?? MacAXLimits.hardMaxMatches
        )
    }

    private func axUntrustedResult(action: String) -> MacControlResult {
        let error = "accessibility_not_trusted"
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "trusted": .bool(false),
                "status": .string("not_trusted"),
                "error": .string(error),
                "note": .string(MacAccessibilityReader.notTrustedNote),
            ]),
            error: error,
            durationMs: 0,
            viaSwift: true
        )
    }

    private func handleAXStatus() -> MacControlResult {
        let started = now()
        let trusted = accessibilitySource.isTrusted()
        var output: [String: JSONValue] = ["trusted": .bool(trusted)]
        if !trusted {
            output["note"] = .string(MacAccessibilityReader.notTrustedNote)
            output["grant_path"] = .string("System Settings → Privacy & Security → Accessibility")
        }
        if let app = accessibilitySource.frontmostApp() {
            output["frontmost_app"] = app.toJSON()
        }
        // The STATUS read itself always succeeds — "I don't have permission" is
        // a true answer, not a failure. Only the tree/find reads fail closed.
        return MacControlResult(
            ok: true,
            action: "ax_status",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    private func axSnapshot(
        limits: MacAXLimits
    ) -> (snapshot: MacAXTreeSnapshot, app: MacAXAppInfo?, rootTitle: String?)? {
        guard let root = accessibilitySource.frontmostWindowRoot() else { return nil }
        let snapshot = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: root,
            limits: limits
        )
        return (snapshot, accessibilitySource.frontmostApp(), snapshot.nodes.first?.attributes.title)
    }

    private static func axTruncationJSON(_ snapshot: MacAXTreeSnapshot, limits: MacAXLimits) -> [String: JSONValue] {
        [
            "truncated": .bool(snapshot.truncated),
            "truncation_reasons": .array(snapshot.truncationReasons.map { .string($0) }),
            "skipped_at_least": .int(Int64(snapshot.skippedAtLeast)),
            "max_nodes": .int(Int64(limits.maxNodes)),
            "max_depth": .int(Int64(limits.maxDepth)),
        ]
    }

    private func handleAXTree(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "ax_tree") }
        let limits = Self.axLimits(from: body)
        guard let read = axSnapshot(limits: limits) else {
            return MacControlResult(
                ok: false,
                action: "ax_tree",
                output: .object([
                    "trusted": .bool(true),
                    "status": .string("no_frontmost_window"),
                    "error": .string("no_frontmost_window"),
                ]),
                error: "no_frontmost_window",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        var output: [String: JSONValue] = Self.axTruncationJSON(read.snapshot, limits: limits)
        output["trusted"] = .bool(true)
        output["app"] = read.app?.toJSON() ?? .null
        // W3.5-FIX-R3 — the SIBLING organ's leak. `mac_view` redacts its text
        // channel, legend and window title; `ax_tree` reads the same screen
        // through the same walk and shipped every node title/value and the
        // window title RAW into the same trace/persist/sync sinks. Same
        // standalone shape redactor, applied here at the tool-serialization
        // boundary so `MacAccessibilityReader`'s walk stays byte-identical.
        output["window_title"] = read.rootTitle.map {
            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: limits.valueChars)
        } ?? .null
        output["count"] = .int(Int64(read.snapshot.nodes.count))
        output["nodes"] = .array(
            MacScreenViewTextRedaction.redactedNodesJSON(
                read.snapshot.nodes,
                valueChars: limits.valueChars
            )
        )
        return MacControlResult(
            ok: true,
            action: "ax_tree",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// The `ax_find` query, echoed back with its free-text fields shape-tested.
    /// `role` is an AX role constant (`AXButton`), never user text, so it rides
    /// out as-is — redacting it would break the caller's ability to see what it
    /// asked for with no secret to protect.
    static func redactedQueryJSON(_ query: MacAXQuery, valueChars: Int) -> JSONValue {
        func redacted(_ text: String?) -> JSONValue {
            guard let text else { return .null }
            return MacScreenViewTextRedaction.redactedLegendString(text, valueChars: valueChars)
        }
        return .object([
            "role": query.role.map { .string($0) } ?? .null,
            "title": redacted(query.title),
            "value": redacted(query.value),
        ])
    }

    private func handleAXFind(_ body: [String: JSONValue]) throws -> MacControlResult {
        let started = now()
        let query = MacAXQuery(
            role: body.stringValue("role"),
            title: body.stringValue("title"),
            value: body.stringValue("value")
        )
        if query.isEmpty {
            throw MacControlError.missingField("role|title|value")
        }
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "ax_find") }
        // Search the SAME bounded tree ax_tree returns: node/depth caps stay
        // hard, and the truncation state rides along so a zero-match answer is
        // distinguishable from "the button was past the cap".
        let limits = Self.axLimits(from: body)
        guard let read = axSnapshot(limits: limits) else {
            return MacControlResult(
                ok: false,
                action: "ax_find",
                output: .object([
                    "trusted": .bool(true),
                    "status": .string("no_frontmost_window"),
                    "error": .string("no_frontmost_window"),
                ]),
                error: "no_frontmost_window",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let matches = MacAccessibilityReader.find(
            nodes: read.snapshot.nodes,
            query: query,
            limits: limits
        )
        var output: [String: JSONValue] = Self.axTruncationJSON(read.snapshot, limits: limits)
        output["trusted"] = .bool(true)
        output["app"] = read.app?.toJSON() ?? .null
        // W3.5-FIX-R4 — the CALLER's own words are an egress too. A model that
        // just read a code off the screen and calls
        // `mac_ax_find(value: "482913")` to locate the field puts that code
        // back into a tool result that is traced, persisted and synced — the
        // redaction on the way OUT is undone by the echo on the way IN. Same
        // standalone shape test as every other channel, so a non-secret query
        // ("Send", "AXButton") stays legible and the echo stays useful.
        output["query"] = Self.redactedQueryJSON(query, valueChars: limits.valueChars)
        output["searched"] = .int(Int64(read.snapshot.nodes.count))
        output["count"] = .int(Int64(matches.count))
        output["max_matches"] = .int(Int64(limits.maxMatches))
        // W3.5-FIX-R3 — a match is a node, so it leaks the same way. The
        // caption context is built from the WHOLE snapshot, not just the
        // matched set: a "2FA code" label that the query did not match still
        // names the value it sits above.
        output["matches"] = .array(
            MacScreenViewTextRedaction.redactedMatchesJSON(
                matches,
                valueChars: limits.valueChars,
                context: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes)
            )
        )
        return MacControlResult(
            ok: true,
            action: "ax_find",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: the fused view (W3.5)

    /// `view` — ONE frozen scene: the picture and the structure together, with
    /// every actionable element numbered on the image and the same number bound
    /// to its real AX path in the legend.
    ///
    /// The two perceptions are taken as close together as the machine allows
    /// (window rect → capture → AX walk, all in-process) and the residual gap
    /// is REPORTED as `fusion_gap_ms` rather than claimed to be zero. A stale
    /// pairing — marks drawn from one moment onto a picture from another — is
    /// the bug this whole tool exists to avoid, so the honest number matters:
    /// a large gap is a reason to look again, and only the caller can judge it.
    ///
    /// PARTIAL PERCEPTION IS STILL PERCEPTION. The two permissions are
    /// independent, so all four combinations return something true:
    ///   • AX + Screen Recording → the fused view.
    ///   • AX only              → the legend with no picture, and the reason.
    ///   • Screen Recording only → the picture with no marks, and the reason
    ///     (this is also the canvas/game/video case — point at a coordinate).
    ///   • neither              → both flags false and how to grant them.
    private func handleView(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let scope: MacScreenCaptureScope = {
            if case .bool(true)? = body["full_screen"] { return .fullScreen }
            if (body.stringValue("scope") ?? "").lowercased() == "full_screen" { return .fullScreen }
            return .focusedWindow
        }()
        let limits = Self.axLimits(from: body)
        let maxMarks = Self.intValue(body, "max_marks") ?? MacScreenViewBuilder.hardMaxMarks
        let maxImageBytes = min(
            Self.intValue(body, "max_image_bytes") ?? MacScreenViewBuilder.hardMaxImageBytes,
            MacScreenViewBuilder.hardMaxImageBytes
        )

        let accessibilityTrusted = accessibilitySource.isTrusted()
        let screenTrusted = screenCaptureSource.isScreenRecordingTrusted()

        // 1. Where to look. The window rect comes from AX (the root node's own
        //    frame), so the capture is exactly the window — not a guessed crop.
        var windowRect: MacAXFrame?
        var app: MacAXAppInfo?
        var windowTitle: String?
        var snapshot: MacAXTreeSnapshot?
        if accessibilityTrusted, let read = axSnapshot(limits: limits) {
            snapshot = read.snapshot
            app = read.app
            windowTitle = read.rootTitle
            windowRect = read.snapshot.nodes.first?.attributes.frame
        }
        let captureRect: MacAXFrame? = (scope == .fullScreen) ? nil : windowRect
        let capturedAt = now()
        let capture = await screenCaptureSource.capture(rect: captureRect)
        let fusionGapMs = Int(abs(now().timeIntervalSince(capturedAt)) * 1000)

        var output: [String: JSONValue] = [
            "accessibility_trusted": .bool(accessibilityTrusted),
            "screen_recording_trusted": .bool(screenTrusted),
            "scope": .string(scope.rawValue),
            "app": app?.toJSON() ?? .null,
            // W3.5-FIX-R2 2 — the window title is visible screen text, but the
            // root AXWindow is not a TEXT role, so it never enters
            // `visibleText` and the source redaction never saw it. A title is
            // routinely the secret itself ("1Password — Recovery Code", a
            // terminal window titled with the token it just printed, a browser
            // tab whose title is the OTP), and it rode out raw into every
            // mac_view sink. Same standalone shape redactor as the legend.
            "window_title": windowTitle.map {
                MacScreenViewTextRedaction.redactedLegendString(
                    $0,
                    valueChars: limits.valueChars
                )
            } ?? .null,
            "fusion_gap_ms": .int(Int64(fusionGapMs)),
        ]
        if !accessibilityTrusted {
            output["accessibility_note"] = .string(MacAccessibilityReader.notTrustedNote)
        }
        if !screenTrusted {
            output["screen_recording_note"] = .string(Self.screenRecordingNote)
        }

        // 2. The geometry the whole fusion hangs on. With no picture there is
        //    still a frame of reference: the window rect itself, at 1 point per
        //    pixel — so the legend is complete and only the drawing is missing.
        let shot: MacScreenShot?
        var imageFailure: MacScreenCaptureFailure?
        switch capture {
        case .success(let value): shot = value
        case .failure(let failure):
            shot = nil
            imageFailure = failure
        }
        let geometry: MacScreenViewGeometry? = {
            if let shot { return MacScreenViewGeometry(shot: shot) }
            guard let rect = windowRect ?? captureRect, rect.w > 0, rect.h > 0 else { return nil }
            return MacScreenViewGeometry(
                bounds: rect,
                pixelWidth: Int(rect.w.rounded()),
                pixelHeight: Int(rect.h.rounded())
            )
        }()

        // 3. Number the actionable elements, and read what the window SAYS.
        //
        // THE EFFORTLESS-VISION ORDERING (User, 2026-08-12): the structured
        // channel is her primary vision — text she reads losslessly — and the
        // picture is the spatial backdrop it rides on. So both halves of the
        // structure are built even when there is no image at all: the numbered
        // controls AND the prose. The bar is "could she act correctly from the
        // legend alone", and a legend with no prose fails it — a set of
        // controls with no idea what the window says is not seeing the screen.
        var selection = MacScreenViewBuilder.Selection(marks: [], omitted: 0, offscreen: 0)
        var text = MacScreenViewBuilder.TextSelection(items: [], omitted: 0)
        if let snapshot, let geometry {
            selection = MacScreenViewBuilder.select(
                nodes: snapshot.nodes,
                geometry: geometry,
                maxMarks: maxMarks
            )
            text = MacScreenViewBuilder.visibleText(
                nodes: snapshot.nodes,
                geometry: geometry,
                limit: Self.intValue(body, "max_text_items") ?? MacScreenViewBuilder.hardMaxTextItems
            )
        }

        // 4. Draw them, under the byte cap.
        var imageDownscale: Double?
        var imageBytes: Int?
        if let shot, let geometry {
            let placements = selection.marks.compactMap {
                geometry.placement(mark: $0.mark, frame: $0.frame)
            }
            let fitted = MacScreenViewBuilder.fitImage(maxBytes: maxImageBytes) { rung in
                screenImageRenderer.renderPNG(shot: shot, placements: placements, downscale: rung)
            }
            if let fitted {
                output["image"] = .string(fitted.data.base64EncodedString())
                output["image_format"] = .string("png")
                imageDownscale = fitted.downscale
                imageBytes = fitted.data.count
            } else {
                imageFailure = .exceedsByteCap
            }
        }
        if output["image"] == nil {
            output["image"] = .null
            output["image_unavailable_reason"] = .string(
                (imageFailure ?? .captureFailed).rawValue
            )
        }
        output["image_bytes"] = imageBytes.map { .int(Int64($0)) } ?? .null
        output["image_downscale"] = imageDownscale.map { .double($0) } ?? .null
        output["max_image_bytes"] = .int(Int64(maxImageBytes))

        if let geometry {
            output["logical_size"] = .object([
                "w": .double(geometry.bounds.w),
                "h": .double(geometry.bounds.h),
            ])
            output["origin"] = .object([
                "x": .double(geometry.bounds.x),
                "y": .double(geometry.bounds.y),
            ])
            output["scale"] = .double(geometry.reportedScale)
            output["image_pixel_size"] = .object([
                "w": .int(Int64(geometry.pixelWidth)),
                "h": .int(Int64(geometry.pixelHeight)),
            ])
        }

        // 5. Remember it, so `mark` can be resolved — and hand back its id.
        //    The id is the ONLY way to address these numbers later; an older
        //    one is refused rather than silently re-interpreted.
        let viewId = UUID().uuidString
        await screenViewStore.record(MacScreenViewSnapshot(
            viewId: viewId,
            capturedAt: capturedAt,
            scope: scope,
            bounds: geometry?.bounds ?? MacAXFrame(x: 0, y: 0, w: 0, h: 0),
            appName: app?.name,
            windowTitle: windowTitle,
            marks: selection.marks
        ))
        output["view"] = .string(viewId)
        output["captured_at"] = .string(ISO8601DateFormatter().string(from: capturedAt))
        output["view_ttl_seconds"] = .int(Int64(MacScreenViewStore.ttlSeconds))
        output["marks"] = .array(selection.marks.map { $0.toJSON(valueChars: limits.valueChars) })
        output["mark_count"] = .int(Int64(selection.marks.count))
        output["marks_omitted"] = .int(Int64(selection.omitted))
        output["marks_offscreen"] = .int(Int64(selection.offscreen))
        output["max_marks"] = .int(Int64(max(1, min(maxMarks, MacScreenViewBuilder.hardMaxMarks))))
        output["text"] = .array(text.items.map { $0.toJSON(valueChars: limits.valueChars) })
        output["text_omitted"] = .int(Int64(text.omitted))
        if let snapshot {
            output["ax_truncated"] = .bool(snapshot.truncated)
            output["ax_truncation_reasons"] = .array(snapshot.truncationReasons.map { .string($0) })
            output["ax_skipped_at_least"] = .int(Int64(snapshot.skippedAtLeast))
        }
        // ONE honest headline: anything the caller did not get to see.
        output["truncated"] = .bool(
            selection.truncated
                || text.omitted > 0
                || (snapshot?.truncated ?? false)
                || output["image"] == .null
        )
        output["how_to_read"] = .string(
            "`marks` and `text` ARE the view — they describe every control and everything the "
            + "window says, losslessly. Read them first; the image is the spatial backdrop showing "
            + "where each numbered thing sits, not something you need to decode to know what is "
            + "there. A mark with label_source \"nearby_text\" was named by inference from the text "
            + "beside it, and one with label_source \"none\" has no name the app publishes."
        )
        output["how_to_act"] = .string(
            "Act by NUMBER, not by coordinate: mac_ax_act {mark: N, view: \"\(viewId)\"} presses "
            + "the element the app's own way, mac_click {mark: N, view: \"\(viewId)\"} clicks its "
            + "centre. Coordinates are for the parts of the picture "
            + "with no marks (canvas, game, video). Marks are only valid for THIS view."
        )
        // ok reflects whether ANY perception came back. Both permissions off is
        // a real failure; either one on is a real answer.
        let ok = accessibilityTrusted || output["image"] != .null
        return MacControlResult(
            ok: ok,
            action: "view",
            output: .object(output),
            error: ok ? nil : "no_perception_available",
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `mac_attention` — explicit, bounded continuity over `mac_view`.
    ///
    /// There is no frame loop and no model call here. Start installs passive
    /// system-event observers for a bounded lifetime and takes one fused view.
    /// Next sleeps on an event continuation (or its bounded deadline), then
    /// takes exactly one more fused view. Stop tears the observers down and
    /// invalidates the last attention-scene marks.
    private func handleAttention(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let mode = (body.stringValue("mode") ?? "status").lowercased()

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
                viaSwift: true,
                httpStatus: status
            )
        }

        switch mode {
        case "start":
            let duration = Self.intValue(body, "duration_seconds")
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
            guard let sessionId = body.stringValue("session"), !sessionId.isEmpty else {
                return result(
                    ok: false,
                    output: ["active": .bool(false), "status": .string("invalid_request")],
                    error: "missing required field: session",
                    status: 400
                )
            }
            let after = Int64(Self.intValue(body, "after_sequence") ?? -1)
            let waitMs = Self.intValue(body, "wait_ms") ?? 1_500
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
            let wasActive = await attentionStore.stop()
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
                viaSwift: true,
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
            viaSwift: true,
            httpStatus: view.httpStatus
        )
    }

    static let screenRecordingNote =
        "NativeAgent does not have Screen Recording permission yet, so the picture half of the "
        + "view is missing (the accessibility legend still works). Grant it in System Settings → "
        + "Privacy & Security → Screen Recording (toggle NativeAgent on) and restart the app. "
        + "Only you can grant this — the app cannot toggle it. This is a SEPARATE permission from "
        + "Accessibility."

    /// Resolve a `{mark, view}` reference against the latest fused view.
    ///
    /// Returns nil when the call named no mark at all (the coordinate/path
    /// forms are unchanged), `.success` with the element it refers to, or
    /// `.failure` with the refusal to return.
    ///
    /// A MARK GRANTS NOTHING. By the time any injection handler calls this, the
    /// call has already presented a live, body-bound, single-use
    /// `MacInjectionCapability` at `dispatchCore` and cleared the category and
    /// active-Full-Mac gates. All this does is turn a number into the element
    /// the human was shown, which is strictly SAFER than the coordinate the
    /// model would otherwise have invented.
    private enum MarkResolution {
        /// The call named no mark at all — the coordinate/path forms apply.
        case absent
        case resolved(MacScreenViewMark)
        case refused(MacControlResult)
    }

    private func resolveMarkReference(
        action: String,
        body: [String: JSONValue]
    ) async -> MarkResolution {
        guard let mark = Self.intValue(body, "mark") else { return .absent }
        guard let viewId = body.stringValue("view") ?? body.stringValue("view_id"),
              !viewId.isEmpty else {
            return .refused(injectionRefusal(
                action: action,
                error: "missing required field: view (the view id mac_view returned with this mark)",
                status: 400,
                extra: ["mark": .int(Int64(mark))]
            ))
        }
        switch await screenViewStore.resolve(viewId: viewId, mark: mark, now: now()) {
        case .success(let hit):
            return .resolved(hit)
        case .failure(let failure):
            return .refused(injectionRefusal(
                action: action,
                error: "\(failure.rawValue): \(failure.guidance)",
                status: 409,
                extra: [
                    "mark": .int(Int64(mark)),
                    "view": .string(viewId),
                    "mark_resolution": .string(failure.rawValue),
                ]
            ))
        }
    }

    // MARK: accessibility injection (W2 — physical, W3 — semantic)
    //
    // Every handler below has already passed the three-gate pre-flight
    // (accessibility category + active Full Mac window + approval attestation).
    // They still re-check the macOS Accessibility TCC grant, because a policy
    // gate is not a system grant: without the grant CGEventPost is silently
    // swallowed by the window server and the caller would be told "typed" when
    // nothing was typed.

    private func injectionRefusal(
        action: String,
        error: String,
        status: Int? = nil,
        extra: [String: JSONValue] = [:]
    ) -> MacControlResult {
        var output: [String: JSONValue] = [
            "ok": .bool(false),
            "status": .string("failed"),
            "error": .string(error),
        ]
        for (key, value) in extra { output[key] = value }
        return MacControlResult(
            ok: false,
            action: action,
            output: .object(output),
            error: error,
            durationMs: 0,
            viaSwift: true,
            httpStatus: status
        )
    }

    /// Shared preconditions for every injection handler: the TCC grant and a
    /// working event sink. Returns a refusal result when either is missing.
    ///
    /// W2/W3-FIX 5: this used to accept
    /// `accessibilityActSource.isTrusted() || accessibilitySource.isTrusted()`,
    /// so a trusted READ seam satisfied an ACT precondition. Those are two
    /// different seams with two different capabilities — the reader can be
    /// trusted (or stubbed trusted, in a test) while the act source is not, and
    /// the disjunction let an act proceed on the reader's authority. Each
    /// injection action now demands the trust IT needs:
    ///   • `ax_act` performs AX actions through `accessibilityActSource` ⇒ that
    ///     source must be trusted. The read source's state is irrelevant.
    ///   • `keystroke` / `click` / `scroll` post CGEvents through `eventSink`,
    ///     which macOS also gates on the Accessibility grant that the act
    ///     source reports ⇒ same requirement, plus an available sink.
    /// The read source is never consulted here.
    private func injectionPreconditions(action: String, requiresSink: Bool) -> MacControlResult? {
        guard accessibilityActSource.isTrusted() else {
            return injectionRefusal(
                action: action,
                error: "accessibility_not_trusted",
                extra: ["note": .string(MacAccessibilityReader.notTrustedNote)]
            )
        }
        if requiresSink, !eventSink.isAvailable {
            return injectionRefusal(action: action, error: "event_injection_unavailable")
        }
        return nil
    }

    /// Shared refusal for an injection call that failed the approval gate.
    /// Mirrors the shape the old in-band check produced (403 + block receipt)
    /// so nothing downstream has to learn a new refusal form.
    private func injectionApprovalRefusal(
        action: String,
        reason: String,
        body: [String: JSONValue]
    ) async -> MacControlResult {
        let result = Self.refusalResult(action: action, reason: reason, now: now)
        if let provider = policyProvider, let policy = await provider.currentPolicy() {
            await emitBlockedAudit(
                action: action,
                category: macControlGateCategory(forAction: action) ?? "accessibility",
                reason: reason,
                trigger: body.stringValue("trigger").flatMap { $0.isEmpty ? nil : $0 } ?? "user",
                policy: policy,
                body: body
            )
        }
        return result
    }

    private static func doubleValue(_ body: [String: JSONValue], _ key: String) -> Double? {
        switch body[key] ?? .null {
        case .int(let n): return Double(n)
        case .double(let d) where d.isFinite: return d
        default: return nil
        }
    }

    private static func intValue(_ body: [String: JSONValue], _ key: String) -> Int? {
        switch body[key] ?? .null {
        case .int(let n): return Int(n)
        case .double(let d) where d.isFinite: return Int(d)
        default: return nil
        }
    }

    /// Effect-time human-takeover check shared by every motor sibling.
    private func attentionActionRefusal(
        action: String,
        body: [String: JSONValue]
    ) async -> MacControlResult? {
        let sessionId = body.stringValue("attention_session")
        let userSequence = Self.intValue(body, "attention_user_sequence").map(Int64.init)
        switch await attentionStore.permissionForAction(
            sessionId: sessionId,
            observedUserSequence: userSequence,
            now: now()
        ) {
        case .allowed:
            return nil
        case .refused(let reason, let current):
            let status: String
            if reason.hasPrefix("human_takeover:") {
                status = "yielded_to_user"
            } else if reason.hasPrefix("scene_changed:") {
                status = "refresh_required"
            } else {
                status = "attention_session_required"
            }
            return MacControlResult(
                ok: false,
                action: action,
                output: .object([
                    "ok": .bool(false),
                    "status": .string(status),
                    "error": .string(reason),
                    "attention": current.toJSON(),
                ]),
                error: reason,
                durationMs: 0,
                viaSwift: true,
                httpStatus: 409
            )
        }
    }

    /// `keystroke` — literal Unicode typing and/or key chords.
    ///
    /// `text` is typed first, then `keys`, so `{text:"hello", keys:"cmd+s"}`
    /// reads in the order it happens. At least one must be present.
    private func handleKeystroke(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let rawText = body.stringValue("text")
        let rawKeys = body.stringValue("keys")
        if (rawText?.isEmpty ?? true) && (rawKeys?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return injectionRefusal(
                action: "keystroke",
                error: "missing required field: text|keys",
                status: 400
            )
        }
        var text: String?
        var chords: [MacKeyChord] = []
        do {
            if let rawText, !rawText.isEmpty {
                text = try MacKeySyntax.validateText(rawText)
            }
            if let rawKeys, !rawKeys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chords = try MacKeySyntax.parseChords(rawKeys)
            }
        } catch {
            // Parse failure is a 400, and NOTHING is emitted — a half-understood
            // chord spec must never be partially executed.
            let message = (error as? MacKeySyntaxError)?.errorDescription ?? "\(error)"
            return injectionRefusal(action: "keystroke", error: message, status: 400)
        }
        if let refusal = injectionPreconditions(action: "keystroke", requiresSink: true) {
            return refusal
        }

        var keyEvents = 0
        if let text {
            for event in MacEventPlanner.typeText(text) {
                if let refusal = await attentionActionRefusal(action: "keystroke", body: body) {
                    await screenViewStore.invalidate()
                    return refusal
                }
                eventSink.post(key: event)
                keyEvents += 1
            }
        }
        for chord in chords {
            for event in MacEventPlanner.chord(chord) {
                if let refusal = await attentionActionRefusal(action: "keystroke", body: body) {
                    await screenViewStore.invalidate()
                    return refusal
                }
                eventSink.post(key: event)
                keyEvents += 1
            }
        }
        await screenViewStore.invalidate()
        return MacControlResult(
            ok: true,
            action: "keystroke",
            output: .object([
                "ok": .bool(true),
                "status": .string("typed"),
                // Character COUNT, never the characters themselves: a keystroke
                // payload routinely carries passwords and private prose, and
                // this result is persisted in the operation store.
                "text_characters": .int(Int64(text?.count ?? 0)),
                "chords": .array(chords.map { $0.toJSON() }),
                "key_events": .int(Int64(keyEvents)),
                // The window server acknowledges nothing; we emitted events, we
                // did not observe an effect.
                "verified": .bool(false),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `click` — a click at a point, or a drag between two points.
    ///
    /// Drag form: `{from:{x,y}, to:{x,y}}` (also accepts flat
    /// `from_x/from_y/to_x/to_y`). Point form: `{x, y}` plus optional
    /// `button:"left"|"right"`, `count:1…3`, `double:true`.
    private func handleClick(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        // W3.5 — the natural form: `{mark: 2, view: "…"}`. The point comes from
        // the element's own AX frame in the view she was shown, so the model
        // never computes a coordinate. The coordinate form below is preserved
        // for the pixel-only fallback (canvas, game, video).
        var markedTarget: MacScreenViewMark?
        switch await resolveMarkReference(action: "click", body: body) {
        case .refused(let refusal): return refusal
        case .resolved(let hit): markedTarget = hit
        case .absent: break
        }
        let button: MacMouseButton = {
            let raw = (body.stringValue("button") ?? "").lowercased()
            if raw == "right" { return .right }
            if case .bool(true)? = body["right"] { return .right }
            return .left
        }()

        func point(_ key: String) -> (Double, Double)? {
            if case .object(let obj)? = body[key],
               let x = Self.doubleValue(obj, "x"), let y = Self.doubleValue(obj, "y") {
                return (x, y)
            }
            if let x = Self.doubleValue(body, "\(key)_x"), let y = Self.doubleValue(body, "\(key)_y") {
                return (x, y)
            }
            return nil
        }

        // W3.5-FIX 2 — EXACTLY ONE target, named exactly one way.
        //
        // A body carrying BOTH `mark` and a coordinate/drag was silently
        // preferring the mark. That does not bypass approval (the capability
        // digest binds the whole body, so the human approved these exact
        // bytes), but it destroys exact-target semantics: the approval card and
        // the trace show a call naming two different points, and only one of
        // them happens. `ax_act` already refuses the analogous mark+path
        // conflict; this is the same rule for the same reason.
        if let markedTarget {
            let coordinateKeys = ["x", "y", "from", "to", "from_x", "from_y", "to_x", "to_y"]
            let conflicting = coordinateKeys.filter { body[$0] != nil && body[$0] != .null }
            if !conflicting.isEmpty {
                return injectionRefusal(
                    action: "click",
                    error: "ambiguous_target: this call names both mark \(markedTarget.mark) "
                        + "and coordinates (\(conflicting.sorted().joined(separator: ", "))); "
                        + "send one or the other",
                    status: 400,
                    extra: [
                        "mark": .int(Int64(markedTarget.mark)),
                        "conflicting_fields": .array(conflicting.sorted().map { .string($0) }),
                    ]
                )
            }
        }

        var events: [MacMouseEvent]
        var describe: [String: JSONValue]
        var dragStepDelayNanoseconds: UInt64 = 0
        if let markedTarget {
            let x = markedTarget.frame.x + markedTarget.frame.w / 2.0
            let y = markedTarget.frame.y + markedTarget.frame.h / 2.0
            var count = Self.intValue(body, "count") ?? 1
            if case .bool(true)? = body["double"] { count = max(count, 2) }
            count = max(1, min(count, 3))
            events = MacEventPlanner.click(x: x, y: y, button: button, count: count)
            describe = [
                "gesture": .string("click"),
                "targeted_by": .string("mark"),
                "mark": .int(Int64(markedTarget.mark)),
                // W3.5-FIX-R2 1 — the mark stores the label RAW (it must: the
                // legend redacts on serialization, not in the store). Echoing
                // it here put a secret-shaped control name back into a result
                // that rides the trace/persist/sync sinks, undoing the read
                // tool's redaction on the act call. Same standalone redactor.
                "element": .object([
                    "role": .string(markedTarget.role),
                    "label": markedTarget.label.map {
                        MacScreenViewTextRedaction.redactedLegendString(
                            $0,
                            valueChars: MacAXLimits.hardValueChars
                        )
                    } ?? .null,
                    "path": .array(markedTarget.path.map { .int(Int64($0)) }),
                ]),
                "x": .double(x),
                "y": .double(y),
                "count": .int(Int64(count)),
            ]
        } else if let from = point("from"), let to = point("to") {
            let durationMs = max(80, min(Self.intValue(body, "duration_ms") ?? 240, 2_000))
            let steps = max(4, min(60, durationMs / 16))
            events = MacEventPlanner.smoothDrag(
                fromX: from.0,
                fromY: from.1,
                toX: to.0,
                toY: to.1,
                button: button,
                steps: steps
            )
            dragStepDelayNanoseconds = UInt64(durationMs) * 1_000_000 / UInt64(steps)
            describe = [
                "gesture": .string("drag"),
                "from": .object(["x": .double(from.0), "y": .double(from.1)]),
                "to": .object(["x": .double(to.0), "y": .double(to.1)]),
                "duration_ms": .int(Int64(durationMs)),
                "drag_steps": .int(Int64(steps)),
            ]
        } else {
            guard let x = Self.doubleValue(body, "x"), let y = Self.doubleValue(body, "y") else {
                return injectionRefusal(
                    action: "click",
                    error: "missing required field: x,y (or from/to for a drag)",
                    status: 400
                )
            }
            var count = Self.intValue(body, "count") ?? 1
            if case .bool(true)? = body["double"] { count = max(count, 2) }
            count = max(1, min(count, 3))
            events = MacEventPlanner.click(x: x, y: y, button: button, count: count)
            describe = [
                "gesture": .string("click"),
                "x": .double(x),
                "y": .double(y),
                "count": .int(Int64(count)),
            ]
        }

        if let refusal = injectionPreconditions(action: "click", requiresSink: true) {
            return refusal
        }
        var pressed = false
        var lastPosted: MacMouseEvent?
        for event in events {
            if let refusal = await attentionActionRefusal(action: "click", body: body) {
                if pressed, let lastPosted {
                    // Never strand a synthesized button-down when the human
                    // takes over midway through a smooth drag.
                    eventSink.post(mouse: MacMouseEvent(
                        phase: .up,
                        button: lastPosted.button,
                        x: lastPosted.x,
                        y: lastPosted.y
                    ))
                }
                await screenViewStore.invalidate()
                return refusal
            }
            eventSink.post(mouse: event)
            lastPosted = event
            if event.phase == .down { pressed = true }
            if event.phase == .up { pressed = false }
            if dragStepDelayNanoseconds > 0,
               event.phase == .down || event.phase == .drag {
                try? await Task.sleep(nanoseconds: dragStepDelayNanoseconds)
            }
        }
        await screenViewStore.invalidate()

        describe["ok"] = .bool(true)
        describe["status"] = .string("clicked")
        describe["button"] = .string(button.rawValue)
        describe["mouse_events"] = .int(Int64(events.count))
        describe["verified"] = .bool(false)
        return MacControlResult(
            ok: true,
            action: "click",
            output: .object(describe),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `scroll` — wheel events, optionally after moving the pointer so the
    /// scroll lands on the intended view rather than wherever the cursor sat.
    private func handleScroll(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let dy = Self.intValue(body, "dy") ?? Self.intValue(body, "delta_y") ?? 0
        let dx = Self.intValue(body, "dx") ?? Self.intValue(body, "delta_x") ?? 0
        if dx == 0 && dy == 0 {
            return injectionRefusal(
                action: "scroll",
                error: "missing required field: dx|dy (a zero scroll is not an action)",
                status: 400
            )
        }
        // Bounded: a runaway delta is a denial-of-attention event.
        let clampedX = Int32(max(-10_000, min(dx, 10_000)))
        let clampedY = Int32(max(-10_000, min(dy, 10_000)))
        let unit: MacScrollUnit = (body.stringValue("units") ?? body.stringValue("unit") ?? "line")
            .lowercased() == "pixel" ? .pixel : .line
        let at: (Double, Double)? = {
            guard let x = Self.doubleValue(body, "x"), let y = Self.doubleValue(body, "y") else { return nil }
            return (x, y)
        }()

        if let refusal = injectionPreconditions(action: "scroll", requiresSink: true) {
            return refusal
        }
        if let at {
            if let refusal = await attentionActionRefusal(action: "scroll", body: body) {
                return refusal
            }
            eventSink.post(mouse: MacMouseEvent(phase: .move, button: .left, x: at.0, y: at.1))
        }
        if let refusal = await attentionActionRefusal(action: "scroll", body: body) {
            await screenViewStore.invalidate()
            return refusal
        }
        eventSink.post(scroll: MacScrollEvent(deltaX: clampedX, deltaY: clampedY, unit: unit))
        await screenViewStore.invalidate()

        var output: [String: JSONValue] = [
            "ok": .bool(true),
            "status": .string("scrolled"),
            "dx": .int(Int64(clampedX)),
            "dy": .int(Int64(clampedY)),
            "units": .string(unit.rawValue),
            "verified": .bool(false),
        ]
        if let at {
            output["x"] = .double(at.0)
            output["y"] = .double(at.1)
        }
        return MacControlResult(
            ok: true,
            action: "scroll",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `ax_act` — THE semantic act. Target an element by the `path` that
    /// `ax_tree`/`ax_find` handed out and run its own AX action, so the app
    /// executes its real handler instead of guessing at a coordinate. Falls
    /// back to a synthesized click at the element's frame centre only when the
    /// element advertises no usable action — and says which one it used.
    private func handleAXAct(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        // W3.5 — `{mark: N, view: "…"}` addresses the element by the number she
        // saw on the picture; it resolves to the SAME child-index path
        // ax_tree/ax_find hand out, so everything below is unchanged and the
        // element is still re-resolved live at act time.
        var markedTarget: MacScreenViewMark?
        switch await resolveMarkReference(action: "ax_act", body: body) {
        case .refused(let refusal): return refusal
        case .resolved(let hit): markedTarget = hit
        case .absent: break
        }
        // EXACTLY ONE target, named exactly one way. The two forms are resolved
        // in separate branches on purpose: a body that carries a `path` which
        // is not an array must be REFUSED, never quietly treated as the empty
        // path — the empty path is the window itself, so "malformed" collapsing
        // to "act on the whole window" is the wrong-target failure this
        // handler's whole validation exists to prevent.
        let rawPath: [JSONValue]
        if let markedTarget {
            if let supplied = body["path"] {
                // A mark AND a path in one call. Allowed only when they name
                // the same element; otherwise two targets were named and there
                // is no safe way to choose.
                let literal: [Int]? = {
                    guard case .array(let entries) = supplied else { return nil }
                    var out: [Int] = []
                    for entry in entries {
                        switch entry {
                        case .int(let n): out.append(Int(n))
                        case .double(let d) where d.isFinite && d == d.rounded(): out.append(Int(d))
                        default: return nil
                        }
                    }
                    return out
                }()
                if literal != markedTarget.path {
                    return injectionRefusal(
                        action: "ax_act",
                        error: "ambiguous_target: this call names both mark \(markedTarget.mark) "
                            + "and a different path; send one or the other",
                        status: 400,
                        extra: [
                            "mark": .int(Int64(markedTarget.mark)),
                            "mark_path": .array(markedTarget.path.map { .int(Int64($0)) }),
                        ]
                    )
                }
            }
            rawPath = markedTarget.path.map { .int(Int64($0)) }
        } else {
            guard case .array(let entries)? = body["path"] else {
                return injectionRefusal(
                    action: "ax_act",
                    error: "missing required field: path (from mac_ax_tree / mac_ax_find) "
                        + "or mark+view (from mac_view)",
                    status: 400
                )
            }
            rawPath = entries
        }
        var path: [Int] = []
        for entry in rawPath {
            switch entry {
            case .int(let n) where n >= 0: path.append(Int(n))
            // W2/W3-FIX 6: a JSON `1.9` used to truncate to 1 and act on a
            // DIFFERENT element than the caller named — a silent wrong-target
            // click, which for an injection action is the worst possible
            // failure mode. An index is an integer; a non-integral double is a
            // malformed request, not a rounding opportunity. `rounded()`
            // equality also rejects NaN/±inf (already excluded by isFinite) and
            // anything past Int's exact-representation range.
            case .double(let d)
                where d.isFinite && d >= 0
                    && d == d.rounded()
                    && d <= 100_000:
                path.append(Int(d))
            default:
                return injectionRefusal(
                    action: "ax_act",
                    error: "invalid path component: path must be non-negative integers",
                    status: 400
                )
            }
        }
        if path.count > MacAXLimits.hardMaxDepth {
            return injectionRefusal(
                action: "ax_act",
                error: "path deeper than the reader's depth cap (\(MacAXLimits.hardMaxDepth))",
                status: 400
            )
        }
        if let refusal = injectionPreconditions(action: "ax_act", requiresSink: false) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "ax_act", body: body) {
            return refusal
        }

        let requestedAction = body.stringValue("action")
        let value = body.stringValue("value")
        let outcome = MacAccessibilityActuator.act(
            source: accessibilityActSource,
            sink: eventSink,
            path: path,
            action: requestedAction,
            value: value
        )
        await screenViewStore.invalidate()
        let pathJSON = JSONValue.array(path.map { .int(Int64($0)) })
        switch outcome {
        case .failure(let error):
            return injectionRefusal(
                action: "ax_act",
                error: error.rawValue,
                status: 404,
                extra: ["path": pathJSON]
            )
        case .success(let result):
            // W2/W3-FIX-R2 3 — a value-carrying ax_act WROTE a string into a
            // field, and this handler re-reads that field. Echoing it back
            // through `element.value` / `post_state.value` put the written
            // secret into the tool result, and from there into the turn trace,
            // the operation store, and the approval record's resultPreview
            // (which syncs to iOS/Telegram). Redact at the source: count +
            // digest, the same shape the redacted ARGUMENT carries, so a
            // reviewer can still confirm what landed is what was approved.
            let redactValue = (value?.isEmpty == false)
            var output: [String: JSONValue] = [
                "ok": .bool(result.ok),
                "status": .string(result.ok ? "acted" : "failed"),
                "method": .string(result.method),
                "requested_action": .string(result.requestedAction),
                "outcome": .string(result.outcome.rawValue),
                "path": pathJSON,
                // W3.5-FIX-R2 1 — `redactingValue` only covers a value this
                // call WROTE. The element's own title (and a value it merely
                // READ) come from the live AX tree and were echoed raw, so an
                // ax_act on a control named after a code re-leaked it. Same
                // standalone shape redactor the legend uses.
                "element": MacScreenViewTextRedaction.redactedElementJSON(
                    result.target.toJSON(redactingValue: redactValue)
                ),
                // The post-state read is offered so the caller can CHECK
                // whether the state changed; it is not itself a claim that it
                // did (see `verificationState`).
                "post_state": result.postState.map {
                    MacScreenViewTextRedaction.redactedElementJSON(
                        $0.toJSON(redactingValue: redactValue)
                    )
                } ?? .null,
                "verified": .bool(false),
                "value_redacted": .bool(redactValue),
            ]
            output["fallback_reason"] = result.fallbackReason.map { .string($0) } ?? .null
            if let markedTarget {
                output["targeted_by"] = .string("mark")
                output["mark"] = .int(Int64(markedTarget.mark))
            }
            if let error = result.error { output["error"] = .string(error) }
            return MacControlResult(
                ok: result.ok,
                action: "ax_act",
                output: .object(output),
                error: result.error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
    }

    // MARK: nudge (W7)

    /// How far the cursor moves, in points. One point: enough for the window
    /// server to see a HID move event, small enough that it cannot drag
    /// anything anywhere even if a button were somehow already held down by a
    /// physical mouse.
    static let nudgeOffsetPoints: Double = 1

    /// `nudge` — post ONE bare mouse move. That is the entire tool.
    ///
    /// It exists for the smallest real problem in this organ: an idle Mac shows
    /// a screensaver or a slept display, and every perception tool then reports
    /// the saver instead of the screen. A human fixes that by bumping the
    /// mouse. This is that bump, and nothing else.
    ///
    /// THE STRUCTURAL GUARANTEE, and the only invariant this handler has: it
    /// emits `MacMouseEvent(phase: .move, …)` and NOTHING else. There is no
    /// `.down`, no `.up`, no `.drag`, no `post(key:)`, no `post(scroll:)` and
    /// no AX mutation anywhere on this path — a single call site, no body, no
    /// branch a caller can steer. `MacNudgeMoveOnlyTests` greps the events the
    /// sink actually received and fails on anything that is not a move.
    ///
    /// WHY IT NEEDS NO APPROVAL, when `mac_click` (which posts a move too) does:
    /// a bare move cannot click, cannot type, cannot activate whatever sits
    /// under the cursor, and cannot bypass a lock — on a locked screen the most
    /// it achieves is showing the login field, exactly like a human bumping the
    /// mouse, which is why it also needs no lock probe. It changes no app
    /// state, so there is nothing for a human to approve. It is NOT a bypass
    /// for `click` / `keystroke` / `ax_act` / `wake`: those keep their three
    /// gates in full, and `nudge` cannot do any part of what they do.
    ///
    /// It is still gated: the accessibility category plus an ACTIVE Full Mac
    /// window (`gatePreflightOutcome`), the macOS Accessibility TCC grant and a
    /// live event sink — the same floor `mac_ax_status` clears, plus the sink,
    /// because reporting "nudged" with the grant missing would be a lie: the
    /// window server silently swallows CGEventPost without it.
    private func handleNudge(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // The TCC grant and a working sink. Same check the injection handlers
        // run — a policy gate is not a system grant — reused rather than
        // copied so a future fix to it cannot miss this handler.
        if let refusal = injectionPreconditions(action: "nudge", requiresSink: true) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "nudge", body: body) {
            return refusal
        }

        // THE WHOLE FEATURE: one move event. The destination is the current
        // cursor position plus one point, so nothing about it depends on caller
        // input — `nudge` takes no parameters at all.
        let origin = Self.currentCursorPoint()
        eventSink.post(mouse: MacMouseEvent(
            phase: .move,
            button: .left,
            x: origin.x + Self.nudgeOffsetPoints,
            y: origin.y
        ))
        await screenViewStore.invalidate()

        return MacControlResult(
            ok: true,
            action: "nudge",
            output: .object([
                "nudged": .bool(true),
                "message": .string(
                    "Posted one bare mouse move (\(Int(Self.nudgeOffsetPoints)) point). This can wake a "
                        + "sleeping display or dismiss a screensaver. It clicks nothing, types nothing and "
                        + "unlocks nothing — on a locked Mac it only brings up the login field."
                ),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// Current cursor location in the CGEvent coordinate space. Read straight
    /// from CoreGraphics rather than through `sessionStateSource`: this tool
    /// does not probe the login session, and where the cursor is is not session
    /// state. `(0, 0)` off-macOS / when the read fails — the move still posts,
    /// which is the honest outcome for a tool whose only job is to emit one.
    private static func currentCursorPoint() -> (x: Double, y: Double) {
        #if canImport(CoreGraphics) && os(macOS)
        if let location = CGEvent(source: nil)?.location {
            return (Double(location.x), Double(location.y))
        }
        #endif
        return (0, 0)
    }

    // MARK: wake (W6)

    /// The default settle wait between the nudge and the re-capture. The window
    /// server needs a beat to tear the saver down; capturing at zero would
    /// photograph the thing we just dismissed and report it as the screen.
    static let wakeDefaultSettleMs = 700
    static let wakeMaxSettleMs = 3000
    /// US virtual keycode for LEFT SHIFT (0x38). A modifier on its own inserts
    /// no character in any app, which is why it is the only key this tool will
    /// press. Kept here rather than in `MacKeySyntax` on purpose: it is not part
    /// of the chord grammar and must not become spellable by a model.
    static let wakeShiftKeyCode: UInt16 = 56

    /// `wake` — dismiss a NON-LOCKED screensaver / wake a sleeping display with
    /// the smallest possible HID nudge, then hand back the fresh fused view.
    ///
    /// THE SAFETY LINE, and the reason this is one tool rather than "call
    /// mac_click then mac_view": the session is probed BEFORE anything is posted,
    /// and a locked — or unreadable — session returns a refusal with the sink
    /// untouched. It is probed AGAIN after the settle wait and before the
    /// capture, because "not locked" was only ever true at the instant it was
    /// read and a screenshot of a locked screen is exactly what must not happen.
    /// A set `CGSSessionScreenIsLocked` is refused whatever the idle password
    /// policy says; see `MacWakeGuard` for the discriminators that were tried
    /// and why a manual lock is indistinguishable from a saver from here.
    ///
    /// The result is the `view` output SHAPE (flattened, not nested) plus a
    /// `wake` block. That is deliberate: every downstream sink that already
    /// knows how to strip a base64 `image` and read a redacted legend keys off
    /// the top level, so flattening inherits mac_view's redaction and image
    /// stripping wholesale instead of opening a second, un-covered channel.
    private func handleWake(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // 1. CAN WE EVEN SEE THE SESSION? An unreadable session is not an
        //    unlocked one.
        guard sessionStateSource.isAvailable else {
            return injectionRefusal(
                action: "wake",
                error: "session_state_unavailable: this build or this Mac would not report the "
                    + "login session, and an unreadable session is not an unlocked one, so it "
                    + "will not nudge blind",
                status: 503
            )
        }
        let before = sessionStateSource.currentState()

        // 2. THE REFUSAL. Nothing has been posted at this point and nothing
        //    will be: this returns before the sink is touched.
        if let reason = MacWakeGuard.refusalReason(for: before) {
            return injectionRefusal(
                action: "wake",
                error: reason,
                status: 403,
                extra: ["session_before": before.toJSON()]
            )
        }

        // 3. The same TCC + sink preconditions every injection handler applies.
        //    Without the Accessibility grant CGEventPost is swallowed by the
        //    window server, and reporting "woken" would be a lie.
        if let refusal = injectionPreconditions(action: "wake", requiresSink: true) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            return refusal
        }

        // 4. THE NUDGE. A one-point mouse move and back is the smallest input
        //    that reaches the HID tap: it cannot type, cannot click, cannot
        //    activate anything under the cursor, and it leaves the pointer
        //    exactly where it was.
        let origin = (before.cursorX ?? 0, before.cursorY ?? 0)
        var mouseEvents = 0
        for point in [(origin.0 + 1, origin.1), origin] {
            if let refusal = await attentionActionRefusal(action: "wake", body: body) {
                await screenViewStore.invalidate()
                return refusal
            }
            eventSink.post(mouse: MacMouseEvent(
                phase: .move,
                button: .left,
                x: point.0,
                y: point.1
            ))
            mouseEvents += 1
        }
        // Optional, off by default: some display-sleep configurations answer a
        // key sooner than a move. Left-shift alone types nothing in any app.
        var keyEvents = 0
        if case .bool(true)? = body["key_tap"] {
            for down in [true, false] {
                if let refusal = await attentionActionRefusal(action: "wake", body: body) {
                    await screenViewStore.invalidate()
                    return refusal
                }
                eventSink.post(key: MacKeyEvent(
                    keyCode: Self.wakeShiftKeyCode,
                    down: down,
                    modifiers: down ? .shift : []
                ))
                keyEvents += 1
            }
        }
        await screenViewStore.invalidate()

        // 5. Let the window server tear the saver down before we photograph it.
        let settleMs = max(0, min(
            Self.intValue(body, "settle_ms") ?? Self.wakeDefaultSettleMs,
            Self.wakeMaxSettleMs
        ))
        if settleMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
        }

        // 6. RE-READ, then RE-GUARD, then re-capture. The verdict comes from what
        //    the session says afterwards — never from "I posted two events".
        let after = sessionStateSource.currentState()

        // THE SECOND HALF OF THE SAFETY LINE. The first guard proved the screen
        // was not locked BEFORE the nudge; a settle wait later that is a stale
        // fact. User can hit Ctrl-Cmd-Q, the idle timer can fire, or the display
        // can lock inside the window we just slept through — and the capture
        // below is a screenshot. So the same guard runs again on the fresh read,
        // and a screen that locked mid-call is neither photographed nor
        // described: no image, no marks, no legend, no view id.
        if let reason = MacWakeGuard.refusalReason(for: after) {
            return injectionRefusal(
                action: "wake",
                error: reason,
                status: 403,
                extra: [
                    "session_before": before.toJSON(),
                    "session_after": after.toJSON(),
                    "wake": .object([
                        "nudged": .bool(true),
                        "mouse_events": .int(Int64(mouseEvents)),
                        "key_events": .int(Int64(keyEvents)),
                        "settle_ms": .int(Int64(settleMs)),
                        "was_obstructed": .bool(before.obstructed),
                        "dismissed": .bool(false),
                        "locked_after_nudge": .bool(true),
                        "note": .string(
                            "The screen locked between the nudge and the capture, so nothing "
                            + "was photographed or read back."
                        ),
                    ]),
                ]
            )
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            return refusal
        }

        let dismissed = !after.obstructed
        let view = await handleView(body)
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            await screenViewStore.invalidate()
            return refusal
        }

        var output: [String: JSONValue]
        if case .object(let viewOutput) = view.output {
            output = viewOutput
        } else {
            output = [:]
        }
        output["wake"] = .object([
            "nudged": .bool(true),
            "mouse_events": .int(Int64(mouseEvents)),
            "key_events": .int(Int64(keyEvents)),
            "settle_ms": .int(Int64(settleMs)),
            "was_obstructed": .bool(before.obstructed),
            "dismissed": .bool(dismissed),
            "session_before": before.toJSON(),
            "session_after": after.toJSON(),
            // The orthogonal evidence that the nudge actually LANDED: a HID
            // post resets the system idle timer. Falling idle time across the
            // nudge is proof; a flat one means the events went nowhere (almost
            // always a missing Accessibility grant).
            "idle_reset": .bool({
                guard let b = before.idleSeconds, let a = after.idleSeconds else { return false }
                return a < b
            }()),
            "note": .string(
                dismissed
                    ? "The screen is awake and showing the real desktop — the view below is it."
                    : "The nudge was posted but the screen still reports a sleeping display or "
                        + "the login window. Try again with key_tap:true."
            ),
        ])
        // `verified` is OBSERVED, not asserted: it is the post-nudge session
        // re-read, which is what `verificationState` picks up.
        output["verified"] = .bool(dismissed)
        return MacControlResult(
            ok: view.ok,
            action: "wake",
            output: .object(output),
            error: view.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: spotlight

    private func handleSpotlight(_ body: [String: JSONValue]) async throws -> MacControlResult {
        let query = body.stringValue("query") ?? body.stringValue("q") ?? ""
        if query.isEmpty {
            throw MacControlError.missingField("query")
        }
        var limit = 10
        if case .int(let n) = body["limit"] ?? .null { limit = max(1, min(Int(n), 200)) }
        else if case .double(let d) = body["limit"] ?? .null { limit = max(1, min(Int(d), 200)) }
        let started = now()
        let result = try await processAdapter.run(
            executable: "/usr/bin/mdfind",
            arguments: [query],
            timeoutSeconds: 10
        )
        let lines = result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
            // Consult the fence like the file handlers do — raw mdfind hits
            // would otherwise leak paths file read/list refuse to touch.
            .filter { MacControlSensitivePathFence.reason(forPath: $0) == nil }
            .prefix(limit)
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: result.exitCode == 0 && !result.timedOut,
            action: "spotlight",
            output: .object([
                "query": .string(query),
                "results": .array(lines.map { .string($0) }),
                "count": .int(Int64(lines.count)),
                "timed_out": .bool(result.timedOut),
            ]),
            error: result.timedOut
                ? "spotlight timed out"
                : (result.exitCode == 0 ? nil : "mdfind exit \(result.exitCode) stderr=\(result.stderr.prefix(200))"),
            durationMs: durationMs,
            viaSwift: true
        )
    }

    // MARK: shell

    private func handleShell(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let command = body.stringValue("command"), !command.isEmpty else {
            throw MacControlError.missingField("command")
        }
        if let reason = MacControlShellWhitelist.validate(command) {
            throw MacControlError.shellNotWhitelisted(reason)
        }
        var timeout = 60
        if case .int(let n) = body["timeout"] ?? .null { timeout = max(1, min(Int(n), 120)) }
        else if case .double(let d) = body["timeout"] ?? .null { timeout = max(1, min(Int(d), 120)) }
        let started = now()
        let result = try await processAdapter.run(
            executable: "/bin/sh",
            arguments: ["-c", command],
            timeoutSeconds: timeout
        )
        let durationMs = Int(now().timeIntervalSince(started) * 1000)
        return MacControlResult(
            ok: result.exitCode == 0 && !result.timedOut,
            action: "shell",
            output: .object([
                "command": .string(String(command.prefix(200))),
                "stdout": .string(String(result.stdout.prefix(4000))),
                "stderr": .string(String(result.stderr.prefix(2000))),
                "exit_code": .int(Int64(result.exitCode)),
                "timed_out": .bool(result.timedOut),
            ]),
            error: result.timedOut
                ? "shell timed out"
                : (result.exitCode == 0 ? nil : "shell exit \(result.exitCode)"),
            durationMs: durationMs,
            viaSwift: true
        )
    }
}

// MARK: - Factory

public func makeMacControl(
    http: any HTTPClient = URLSessionHTTPClient(),
    policyProvider: (any MacControlPolicyProvider)? = nil,
    auditAppendPath: URL? = nil,
    operationDataRoot: URL? = nil
) -> any MacControlClient {
    let dataRoot = operationDataRoot ?? auditAppendPath?.deletingLastPathComponent()
    return SwiftNativeMacControl(
        http: http,
        policyProvider: policyProvider,
        auditAppendPath: auditAppendPath,
        operationStore: dataRoot.map { MacControlOperationStore(dataRoot: $0) }
    )
}
