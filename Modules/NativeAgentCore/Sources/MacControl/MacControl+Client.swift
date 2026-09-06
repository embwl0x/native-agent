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
    private let openTargetAdapter: OpenTargetAdapter
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
    /// native-look item 3 — the CLOSED LOOP's effect seam. Production installs
    /// a real `AXObserver` on the target app's pid, sourced on the main run
    /// loop; tests inject a fake that emits scripted notifications and counts
    /// installs/removals, so "the observer is always removed" is pinned rather
    /// than assumed. Separate from every seam above for the same reason they
    /// are separate from each other: this one only LISTENS.
    private let effectObserverSource: any MacAXEffectObserverSource
    /// W3.5 — the picture half of the fused view. Screen Recording is its OWN
    /// TCC permission; this seam only ever PREFLIGHTS it (never prompts, never
    /// toggles) and reports the answer honestly.
    private let screenCaptureSource: any MacScreenCaptureSource
    private let pointerPositionSource: any MacPointerPositionSource
    /// W3.5 — set-of-marks renderer. Injectable so the placement math and the
    /// byte budget are pinned with no window server in the loop.
    private let screenImageRenderer: any MacScreenImageRenderer
    /// W3.5 — the latest fused view, so a later `mark` resolves to a real
    /// element. A mark is a REFERENCE ONLY: every injection gate still runs.
    private let screenViewStore: MacScreenViewStore
    /// native-look item 2 — the latest look's task-scoped perceptual frame, so
    /// item 3's verbs can resolve a handle back to a path. Like a mark, a
    /// handle is a REFERENCE ONLY and grants no authority.
    private let lookFrameStore: MacLookFrameStore
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
    /// fable51 item 30 — the pasteboard seam. Separate from every seam above
    /// for the same reason they are separate from each other: nothing in it can
    /// walk a tree, post an event, or capture a pixel.
    private let pasteboardSource: any MacPasteboardSource
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
        openTargetAdapter: OpenTargetAdapter = SystemOpenTargetAdapter(),
        accessibilitySource: any MacAXElementSource = defaultMacAXElementSource(),
        eventSink: any MacEventSink = defaultMacEventSink(),
        accessibilityActSource: any MacAXActSource = defaultMacAXActSource(),
        effectObserverSource: any MacAXEffectObserverSource = defaultMacAXEffectObserverSource(),
        screenCaptureSource: any MacScreenCaptureSource = defaultMacScreenCaptureSource(),
        pointerPositionSource: any MacPointerPositionSource = defaultMacPointerPositionSource(),
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
        _ = http
        self.now = now
        self.notificationCenterAdapter = notificationCenterAdapter
        self.appleScriptAdapter = appleScriptAdapter
        self.processAdapter = processAdapter
        self.fileManagerAdapter = fileManagerAdapter
        self.appControlAdapter = appControlAdapter
        self.openTargetAdapter = openTargetAdapter
        self.accessibilitySource = accessibilitySource
        self.eventSink = eventSink
        self.accessibilityActSource = accessibilityActSource
        self.effectObserverSource = effectObserverSource
        self.screenCaptureSource = screenCaptureSource
        self.pointerPositionSource = pointerPositionSource
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

        // Perception is deliberately live and effect-free. Sending these reads
        // through the durable motor-operation lifecycle both adds filesystem
        // latency to every frame and makes an operation-id replay capable of
        // returning stale screen state. Keep the same policy preflight inside
        // `executeAction`, but reserve durable begin/transition/replay records
        // for actions that can change the world.
        // fable51 item 30 — `clipboard_read` joins the reads here for the same
        // reason: it changes nothing, so a durable operation record would add
        // filesystem latency and make a replay able to return a stale
        // clipboard. `clipboard_write` deliberately does NOT join them.
        // fable51 item 33 — `read` joins them for the same reason: it returns
        // what a document says RIGHT NOW, and a replayable operation record
        // would let a later call answer with a document that has since changed.
        if macControlAccessibilityReadActions.contains(normalized)
            || macControlClipboardReadActions.contains(normalized)
            || macControlDocumentReadActions.contains(normalized) {
            return try await executeAction(normalized, body: body)
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
        // fable51 item 33 — `read` is here too, and it is the one READ that
        // belongs in this list: the accumulate route moves the user's scroll
        // position, and a human scrolling their own document must not have it
        // yanked out from under them mid-gesture.
        if macControlAccessibilityInjectionActions.contains(normalized)
            || macControlAccessibilityNudgeActions.contains(normalized)
            || macControlDocumentReadActions.contains(normalized),
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
        case "open_target": return try await handleOpenTarget(body)
        case "spotlight":   return try await handleSpotlight(body)
        case "shell":       return try await handleShell(body)
        case "ax_status":   return handleAXStatus()
        case "ax_tree":     return handleAXTree(body)
        case "ax_find":     return try handleAXFind(body)
        // native-look item 2 — THE PERCEPTION COMPILER. Read tier like the
        // three above and for the same reason: it walks the same AX tree
        // through the same read organ and changes no UI state.
        case "look":        return await handleLook(body)
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
        // native-look item 3 — THE CLOSED LOOP. Injection like the four above
        // (it performs through the same actuator); the percept it returns
        // afterwards is evidence of the effect, not a lower tier.
        case "act":         return await handleAct(body)
        case "hand":        return await handleHand(body)
        // W6 — the nudge + re-capture. Injection like the four above (it posts
        // HID events). The nudge itself is never pre-refused (User, 2026-08-22);
        // only the capture refuses, while the saver/login layer is still up.
        case "wake":        return await handleWake(body)
        // W7 — the NUDGE. Reached through the unprivileged `dispatch` like the
        // reads above, not through `dispatchApprovedInjection`: it emits one
        // bare mouse move and nothing else.
        case "nudge":       return await handleNudge(body)
        // fable51 item 30 — THE CLIPBOARD ORGAN. The read is perception with a
        // redaction boundary; the write replaces the general pasteboard and
        // verifies itself by reading back what it put there.
        case "clipboard_read":  return handleClipboardRead(body)
        case "clipboard_write": return handleClipboardWrite(body)
        // fable51 item 29 — THE MENU BAR ORGAN. `menu` walks; `menu_press`
        // presses through the same actuator every other act uses.
        case "menu":        return handleMenu(body)
        case "menu_press":  return handleMenuPress(body)
        // fable51 item 33 — THE READ ORGAN. Extract a named document, or
        // scroll-and-accumulate the front window's text; either way it hands
        // back the whole thing and the turn's spill pager retains it.
        case "read":        return await handleRead(body)
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
        // One AX walk, plus (Chromium/Electron only) a bounded ≤4s settle and
        // exactly ONE re-walk. Nothing here waits on another process otherwise.
        case "look": return 25
        // W3.5 — one AX walk plus one ScreenCaptureKit screenshot + encode.
        // Still in-process, but the capture is the slowest read here.
        case "view": return 20
        // Event-driven wait is caller-bounded to 15s, followed by one view.
        case "attention": return 40
        // In-process CGEvent / AX act; nothing here waits on another process.
        case "keystroke", "click", "scroll", "ax_act", "hand": return 15
        // native-look item 3 — one act, a bounded ≤2s effect wait, then one AX
        // walk (which on a Chromium window may add a ≤4s settle + one re-walk).
        case "act": return 30
        // W7 — one CGEvent post, in-process, nothing awaited.
        case "nudge": return 15
        // fable51 item 30 — one in-process pasteboard read/write.
        case "clipboard_read", "clipboard_write": return 10
        // fable51 item 29 — one bounded AX menu-bar walk; one AXPress.
        case "menu": return 20
        case "menu_press": return 15
        // fable51 item 33 — up to `maxFrames` walks with a settle between each,
        // or one file read plus a PDFKit parse. The slowest read in the module
        // by design: it is the only one that reads a whole document.
        case "read": return 90
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
        case "file/read", "file/list", "spotlight", "ax_status", "ax_tree", "ax_find", "view", "look":
            return .satisfied
        // fable51 item 29 — the menu WALK is a read, like the reads above. The
        // PRESS is not: it runs the app's own handler and is reported
        // `unverified` with the injection actions below, because "I re-read the
        // item" is not proof the handler ran.
        case "menu":
            return .satisfied
        // fable51 item 30 — the clipboard READ is a read, like the reads above.
        // The WRITE never reaches here: `handleClipboardWrite` publishes its own
        // `verified` flag, decided by READING BACK what it put on the
        // pasteboard rather than by having called `setString`.
        case "clipboard_read":
            return .satisfied
        // fable51 item 33 — the read organ is a read. It scrolls, but the only
        // state it touches is the one it puts back, and the text it returns is
        // what the document said.
        case "read":
            return .satisfied
        case "notify", "file/write", "file/move", "file/trash", "focus_app", "quit_app", "applescript", "shell":
            return .unverified
        // W2/W3 injection. UNVERIFIED on purpose, including `ax_act`: the
        // handler re-reads the element afterwards and returns that post-state,
        // but "I read the element again" is not proof the app's handler ran or
        // that the intended consequence happened. Claiming `satisfied` here
        // would manufacture settlement evidence out of a second read.
        case "keystroke", "click", "scroll", "ax_act", "hand", "menu_press":
            return .unverified
        // native-look item 3 — `act` publishes `verified: false` above, so this
        // never decides it. Listed so the intent survives a refactor: the
        // closed loop OBSERVES an effect (a notification fired, the percept
        // changed) which is real evidence, but it is not proof the INTENDED
        // consequence happened — the caller judges the diff. Claiming
        // `satisfied` would manufacture settlement out of a re-look.
        case "act":
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
        // fable51 item 30: the clipboard organ carries the SAME Full Mac
        // requirement as the reads, by the same rule — the accessibility
        // category alone must not be reachable through the bridge under an
        // expired window.
        // fable51 item 33: the read organ carries the SAME Full Mac requirement,
        // by the same rule.
        if macControlAccessibilityReadActions.contains(action)
            || macControlAccessibilityNudgeActions.contains(action)
            || macControlClipboardActions.contains(action)
            || macControlDocumentReadActions.contains(action)
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
        case "open_target":   return "open_target"
        case "quit_app":      return "quit_app"
        case "keystroke":     return "keystroke"
        // No daemon ancestor (W1 Swift-native reads). The audit row still
        // wants a stable method name, so it is the action itself.
        case "ax_status":     return "ax_status"
        case "ax_tree":       return "ax_tree"
        case "ax_find":       return "ax_find"
        case "look":          return "look"
        case "view":          return "view"
        case "wake":          return "wake"
        case "nudge":         return "nudge"
        case "scroll":        return "scroll"
        case "ax_act":        return "ax_act"
        case "act":           return "act"
        case "hand":          return "hand"
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
        let receipt: NotificationPostReceipt
        do {
            receipt = try await notificationCenterAdapter.postNotificationReceipt(
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
        let receiptFields: [String: JSONValue] = [
            "submission": .string(receipt.disposition.rawValue),
            "authorization": .string(receipt.authorization.rawValue),
            "request_id": receipt.requestIdentifier.map { .string($0) } ?? .null,
            "delivery_observed": .bool(false),
        ]
        let outputFields: [String: JSONValue] = [
            "title": .string(title),
            "message": .string(message),
            "sound": sound.map { .string($0) } ?? .null,
            // `UNUserNotificationCenter.add` acknowledges only that the
            // request was accepted. It cannot prove a banner appeared,
            // sound played, or a person received it; keep the terminal
            // operation receipt explicitly unverified until a distinct
            // observer supplies that evidence.
            "receipt": .object(receiptFields),
        ]
        return MacControlResult(
            ok: true,
            action: "notify",
            output: .object(outputFields),
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
            let observedFrontmost = await (appControlAdapter as? any AppStateVerificationAdapter)?
                .isFrontmostApplication(matching: app)
            let ok = observedFrontmost == true
            let failureReason: String? = if ok {
                nil
            } else if let reason = result.activationFailureReason {
                reason
            } else if observedFrontmost == nil {
                "focus verification unavailable after activation request"
            } else {
                "activation request returned \(result.activationRequestAccepted.map(String.init) ?? String(result.activated)); target was not observed frontmost"
            }
            return MacControlResult(
                ok: ok,
                action: "focus_app",
                output: appControlOutput(
                    result,
                    status: ok ? "focused" : "focus_failed",
                    verified: ok,
                    activated: ok,
                    failureReason: failureReason
                ),
                error: failureReason,
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

    /// Launch Services acceptance is transport evidence, not settlement. The
    /// result stays explicitly unverified; the four-verb surface follows this
    /// operation with a fresh screen and speaks only what that read shows.
    private func handleOpenTarget(_ body: [String: JSONValue]) async throws -> MacControlResult {
        guard let raw = body.stringValue("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "file" || (["http", "https"].contains(scheme) && url.host != nil)) else {
            throw MacControlError.missingField("url")
        }
        let started = now()
        let accepted = await openTargetAdapter.requestOpen(url)
        return MacControlResult(
            ok: accepted,
            action: "open_target",
            output: .object([
                "status": .string(accepted ? "requested" : "request_refused"),
                "verified": .bool(false),
            ]),
            error: accepted ? nil : "Launch Services did not accept the open request",
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
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
        verified: Bool,
        activated: Bool? = nil,
        failureReason: String? = nil
    ) -> JSONValue {
        .object([
            "requested": .string(result.requestedName),
            "matched_name": result.matchedName.map { .string($0) } ?? .null,
            "bundle_identifier": result.bundleIdentifier.map { .string($0) } ?? .null,
            "process_identifier": result.processIdentifier.map { .int(Int64($0)) } ?? .null,
            "launched": .bool(result.launched),
            "activated": .bool(activated ?? result.activated),
            "activation_request_accepted": result.activationRequestAccepted.map { .bool($0) } ?? .null,
            "activation_fallback_attempted": .bool(result.activationFallbackAttempted),
            "activation_fallback_succeeded": .bool(result.activationFallbackSucceeded),
            "failure_reason": failureReason.map { .string($0) } ?? .null,
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

    // MARK: - fable51 item 29: the menu bar organ

    /// Which app's menu bar. Defaults to the frontmost, but honours `app` the
    /// same way `look` does — reading another app's menu is exactly as
    /// focus-free as reading its window, and refusing to would have made the
    /// two organs disagree about what "which app" means.
    private enum MenuTarget {
        case app(MacAXAppInfo)
        case refused(MacControlResult)
    }

    private func menuTarget(_ body: [String: JSONValue]) -> MenuTarget {
        let started = now()
        func refuse(_ code: String, _ words: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            var output: [String: JSONValue] = [
                "status": .string(code),
                "error": .string(code),
                "message": .string(words),
            ]
            for (key, value) in extra { output[key] = value }
            return MacControlResult(
                ok: false,
                action: "menu",
                output: .object(output),
                error: code,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard let requested = body.stringValue("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            guard let front = accessibilitySource.frontmostApp() else {
                return .refused(refuse(
                    "no_frontmost_app",
                    "Nothing is frontmost right now, so there is no menu bar to read."
                ))
            }
            return .app(front)
        }
        let resolution = MacBackgroundSight.resolve(
            requested,
            among: accessibilitySource.runningApps()
        )
        guard case .matched(let app) = resolution else {
            let code: String = {
                switch resolution {
                case .selfProcess: return "self_inspection_refused"
                case .ambiguous: return "app_ambiguous"
                default: return "app_not_running"
                }
            }()
            return .refused(refuse(
                code,
                MacBackgroundSight.words(for: resolution, requested: requested)
                    ?? "I couldn't find a running app called \"\(requested)\".",
                ["requested_app": .string(requested)]
            ))
        }
        return .app(app)
    }

    /// THE WALK. One bounded descent, read-only, and it never opens a menu:
    /// the AX tree publishes the items whether or not they are drawn.
    private func handleMenu(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "menu") }
        let app: MacAXAppInfo
        switch menuTarget(body) {
        case .refused(let refusal): return refusal
        case .app(let hit): app = hit
        }
        let reading = MacMenuBar.read(source: accessibilitySource, pid: app.processIdentifier)
        var output: [String: JSONValue] = [:]
        if case .object(let menuJSON) = MacMenuBar.json(reading) {
            output = menuJSON
        }
        output["trusted"] = .bool(true)
        output["app"] = app.toJSON()
        if let unavailable = reading.unavailable {
            output["message"] = .string(
                unavailable == "no_menu_bar"
                    ? "\(app.name) publishes no menu bar, so there is nothing to list."
                    : "I can't read \(app.name)'s menu bar: \(unavailable)."
            )
            return MacControlResult(
                ok: false,
                action: "menu",
                output: .object(output),
                error: unavailable,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        return MacControlResult(
            ok: true,
            action: "menu",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// THE PRESS. Walk (to resolve the NAME into an address), then AXPress
    /// through the same actuator `ax_act` uses.
    ///
    /// A DISABLED item refuses IN WORDS and presses nothing. That is the same
    /// refusal shape `act` holds: greyed out is a fact about the app's state,
    /// and pressing anyway would either do nothing (and be reported as done) or
    /// hit whatever the index chain now points at.
    private func handleMenuPress(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "menu_press") }
        func refuse(_ code: String, _ words: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            var output: [String: JSONValue] = [
                "pressed": .bool(false),
                "status": .string(code),
                "error": .string(code),
                "message": .string(words),
            ]
            for (key, value) in extra { output[key] = value }
            return MacControlResult(
                ok: false,
                action: "menu_press",
                output: .object(output),
                error: code,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard let requested = body.stringValue("path")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return refuse(
                "missing_path",
                "menu_press needs `path` — the menu path to press, like \"File › Export › PDF\"."
            )
        }
        let app: MacAXAppInfo
        switch menuTarget(body) {
        case .refused(let refusal): return refusal
        case .app(let hit): app = hit
        }
        let reading = MacMenuBar.read(source: accessibilitySource, pid: app.processIdentifier)
        if let unavailable = reading.unavailable {
            return refuse(
                unavailable,
                "\(app.name) publishes no menu bar I can press through."
            )
        }
        let resolution = MacMenuBar.resolve(requested, among: reading.items)
        guard case .matched(let item) = resolution else {
            let code: String = {
                switch resolution {
                case .disabled: return "menu_item_disabled"
                case .ambiguous: return "menu_path_ambiguous"
                default: return "menu_path_not_found"
                }
            }()
            return refuse(
                code,
                MacMenuBar.words(for: resolution, requested: requested)
                    ?? "I couldn't find \"\(requested)\" in \(app.name)'s menu bar.",
                ["requested_path": .string(requested)]
            )
        }
        // Resolved from the MENU BAR, never from a window root: a menu bar is
        // not under any window, so a window-relative resolve of this index
        // chain would land on an unrelated element inside the document.
        let target: MacAXActTarget
        switch accessibilityActSource.resolve(
            menuPath: item.path,
            inAppPid: app.processIdentifier
        ) {
        case .resolved(let hit):
            target = hit
        case .pathNotFound:
            return refuse(
                "menu_path_not_found",
                "\"\(item.display)\" was in the menu a moment ago and is not there now; "
                    + "read the menu again."
            )
        default:
            return refuse(
                "app_gone",
                "\(app.name)'s menu bar is not reachable any more."
            )
        }
        let outcome = accessibilityActSource.perform(target, action: "AXPress")
        guard outcome == .performed else {
            return refuse(
                "menu_press_refused",
                "\(app.name) refused the press on \"\(item.display)\" (\(outcome)); nothing happened.",
                ["requested_path": .string(item.display)]
            )
        }
        return MacControlResult(
            ok: true,
            action: "menu_press",
            output: .object([
                "pressed": .bool(true),
                "trusted": .bool(true),
                "app": app.toJSON(),
                "path": MacScreenViewTextRedaction.redactedLegendString(
                    item.display,
                    valueChars: MacMenuBar.maxTitleChars * MacMenuBar.maxPathDepth
                ),
                "opens_submenu": .bool(item.hasSubmenu),
                // The press ran the app's handler. Whether the INTENDED
                // consequence happened is for the next look to say, never for
                // this result to claim.
                "verified": .bool(false),
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: - fable51 item 30: the clipboard organ

    /// READ. The only channel through which pasteboard characters reach a
    /// provider, and therefore the only place the redaction boundary has to
    /// hold.
    ///
    /// Order matters: REDACT FIRST, then truncate. Truncating first could cut a
    /// secret in half and hand out the surviving half as ordinary prose, and
    /// the cut token would no longer match any shape the redactor knows.
    private func handleClipboardRead(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard let contents = pasteboardSource.read() else {
            return MacControlResult(
                ok: false,
                action: "clipboard_read",
                output: .object([
                    "available": .bool(false),
                    "note": .string("There is no pasteboard on this system, so there is nothing to read."),
                ]),
                error: "clipboard_unavailable",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let maxChars = MacClipboardRead.clampedMaxChars(Self.intValue(body, "max_chars"))
        var output: [String: JSONValue] = [
            "available": .bool(true),
            "change_count": .int(Int64(contents.changeCount)),
            "types": MacClipboardRead.typesJSON(contents.types),
            "has_non_text": .bool(MacClipboardRead.hasNonTextTypes(contents.types)),
        ]
        if let raw = contents.text {
            let redaction = MacClipboardRead.redacted(raw)
            let cut = MacClipboardRead.truncated(redaction.text, maxChars: maxChars)
            output["has_text"] = .bool(true)
            output["text"] = .string(cut.text)
            output["chars"] = .int(Int64(redaction.text.count))
            output["truncated"] = .bool(cut.truncated)
            if cut.truncated { output["returned_chars"] = .int(Int64(cut.text.count)) }
            output["redacted"] = .bool(redaction.didRedact)
            if redaction.didRedact {
                output["redactions"] = .array(redaction.redactedLines.map { line in
                    .object(["line": .int(Int64(line.line)), "reason": .string(line.reason)])
                })
            }
        } else {
            output["has_text"] = .bool(false)
            output["text"] = .null
            output["chars"] = .int(0)
            output["truncated"] = .bool(false)
            output["redacted"] = .bool(false)
        }
        return MacControlResult(
            ok: true,
            action: "clipboard_read",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// WRITE. Replaces the general pasteboard's text and then READS IT BACK:
    /// `verified` is that comparison, never the return value of the set call.
    /// The text itself is never echoed — the caller wrote it, and an echo would
    /// route it back out through a channel with no redactor on it.
    private func handleClipboardWrite(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        func refuse(_ reason: String, _ words: String) -> MacControlResult {
            MacControlResult(
                ok: false,
                action: "clipboard_write",
                output: .object(["written": .bool(false), "note": .string(words)]),
                error: reason,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard let text = body.stringValue("text") else {
            return refuse("missing_text", "clipboard_write needs `text` — the characters to put on the clipboard.")
        }
        guard text.count <= MacClipboardRead.maxWriteChars else {
            return refuse(
                "text_too_long",
                "That is \(text.count) characters; the clipboard write is bounded at "
                    + "\(MacClipboardRead.maxWriteChars)."
            )
        }
        guard pasteboardSource.write(text: text) else {
            return refuse("clipboard_write_refused", "The system refused the clipboard write; nothing changed.")
        }
        let readBack = pasteboardSource.read()
        return MacControlResult(
            ok: true,
            action: "clipboard_write",
            output: .object([
                "written": .bool(true),
                "chars": .int(Int64(text.count)),
                "verified": .bool(readBack?.text == text),
                "change_count": readBack.map { .int(Int64($0.changeCount)) } ?? .null,
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: - fable51 item 33: the read organ

    /// Milliseconds waited after a scroll before the next walk. A scroll is
    /// delivered to the app asynchronously and an app that lays out on the next
    /// runloop turn would otherwise be walked mid-scroll — which reads as "the
    /// content did not change" and ends the accumulation one screen early.
    static let documentReadSettleMilliseconds = 140

    /// READ. The whole document, in words, and never through `look`'s budgets.
    ///
    /// Two routes and it picks by asking what the thing IS (see
    /// `MacDocumentRead`'s header). The file route wins when there is a file,
    /// because a PDF's own characters beat anything scraped off a rendering of
    /// them — but a file this organ cannot parse falls THROUGH to the screen
    /// route rather than refusing, because the window is still right there and
    /// "I can see it but I refuse to read it" is not an answer a body gives.
    private func handleRead(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        func result(
            ok: Bool,
            _ output: [String: JSONValue],
            error: String? = nil
        ) -> MacControlResult {
            MacControlResult(
                ok: ok,
                action: "read",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        func refuse(_ code: String, _ words: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            var output: [String: JSONValue] = [
                "read": .bool(false),
                "status": .string(code),
                "error": .string(code),
                "message": .string(words),
            ]
            for (key, value) in extra { output[key] = value }
            return result(ok: false, output, error: code)
        }

        // fable51 item 32a/33 (gpt-5.5 review) — WHOSE WINDOW. Absent means the
        // one in front, which is all `read` has ever meant. Named means that
        // running app's front window, resolved through the SAME organ
        // `screen(app:)` resolves through and read through `windowRoot(pid:)` —
        // nothing here activates, launches or raises anything, so reading a
        // document in a background window costs User no focus.
        let requestedApp: String? = {
            guard let raw = body.stringValue("app")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }()

        // Resolved ONCE and used by both routes: the file the window names and
        // the window's own text have to come from the SAME window, or the
        // answer is a splice of two of them.
        var target: MacAXAppInfo?
        if accessibilitySource.isTrusted() {
            if let requestedApp {
                let resolution = MacBackgroundSight.resolve(
                    requestedApp,
                    among: accessibilitySource.runningApps()
                )
                guard case .matched(let app) = resolution else {
                    let code: String = {
                        switch resolution {
                        case .selfProcess: return "self_inspection_refused"
                        case .ambiguous: return "app_ambiguous"
                        default: return "app_not_running"
                        }
                    }()
                    return refuse(
                        code,
                        MacBackgroundSight.words(for: resolution, requested: requestedApp)
                            ?? "I couldn't find a running app called \"\(requestedApp)\".",
                        ["requested_app": .string(requestedApp)]
                    )
                }
                target = app
            } else {
                target = accessibilitySource.frontmostApp()
            }
        }

        // Which file, if any. An explicit `path` is the caller naming one; with
        // none, the window is ASKED whether it is showing a document.
        let rawPath = body.stringValue("path")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPath = (rawPath?.isEmpty ?? true) ? nil : rawPath
        let namedByCaller = requestedPath != nil
        var documentPath = requestedPath.map { NSString(string: $0).expandingTildeInPath }
        // gpt-5.5 review — AN AX-INFERRED PATH IS STILL A FILE READ.
        //
        // A `read` with no `path` clears only the accessibility category at the
        // tool layer, by design: "read the thing in front of me" is the same
        // authority as `look`. But the window's `AXDocument` then handed a
        // FILESYSTEM PATH to `extractDocument(at:)`, which opened the whole file
        // off disk — so a call that never named a path got a file read that the
        // file policy never saw, and a named path could not have got. The fence
        // is not about who typed the path; it is about opening a file. So the
        // inferred path clears the SAME file policy an explicit one clears, and
        // when it does not, the file route is simply not taken: the window is
        // right there, and its own text is what the accessibility category is
        // actually the authority over.
        var declinedInferredPath: (path: String, reason: String)?
        if documentPath == nil, let target,
           let inferred = accessibilitySource.frontmostDocumentPath(pid: target.processIdentifier) {
            // User, 2026-09-06: the TURN's file-access mode outranks the Mac
            // file policy here. Under fileAccess=none the chat gate refuses a
            // pathful `read`; without this the pathless one still opened the
            // front window's document, which is the same file read by another
            // name. AX text only, and the receipt says which path was declined.
            if MacControlTurnFileAccess.deniesFileReads {
                declinedInferredPath = (path: inferred, reason: "file_access_none")
            } else if let reason = await fileClearanceReason(forPath: inferred, body: body) {
                declinedInferredPath = (path: inferred, reason: reason)
            } else {
                documentPath = inferred
            }
        }

        // ROUTE (a): EXTRACT.
        if let path = documentPath {
            switch extractDocument(at: path) {
            case .success(let extracted):
                let redaction = MacClipboardRead.redacted(extracted.text)
                var output: [String: JSONValue] = [
                    "read": .bool(true),
                    "source": .string("file"),
                    "path": .string(path),
                    "named_by": .string(namedByCaller ? "caller" : "front_window"),
                    "chars": .int(Int64(redaction.text.count)),
                    "truncated": .bool(extracted.truncated),
                    "text": .string(redaction.text),
                ]
                if let target, !namedByCaller { output["app"] = target.toJSON() }
                if let pages = extracted.pages { output["document_pages"] = .int(Int64(pages)) }
                Self.attachRedaction(redaction, to: &output)
                return result(ok: true, output)
            case .failure(let failure):
                // The CALLER named this file: their question was about the
                // file, so the answer is about the file.
                if namedByCaller {
                    return refuse(
                        failure.rawValue,
                        MacDocumentRead.words(for: failure, path: path),
                        ["path": .string(path)]
                    )
                }
                // WE inferred it from the window. The window is still there and
                // still readable, so fall through and read THAT, saying which
                // file we could not parse and why.
                return await readFromScreen(
                    started: started,
                    body: body,
                    app: target,
                    fellBackFrom: (path: path, reason: failure.rawValue),
                    declinedInferredPath: nil
                )
            }
        }

        // ROUTE (b): ACCUMULATE.
        return await readFromScreen(
            started: started,
            body: body,
            app: target,
            fellBackFrom: nil,
            declinedInferredPath: declinedInferredPath
        )
    }

    /// The file-policy clearance an AX-INFERRED document path must pass before
    /// it may be opened, reported as a reason string or `nil` for cleared.
    ///
    /// Deliberately the same two layers `gatePreflightOutcome` runs for an
    /// EXPLICIT `path` (`macControlFilePolicyPathKeys(forAction: "read")`), in
    /// the same order: the `file_ops` category gate, then the workspace-root
    /// file policy for this specific path. It lives HERE rather than at the
    /// tool layer because the path does not exist yet when the tool layer runs
    /// — the window has not been asked. And a nil provider proceeds, matching
    /// the pre-flight's own convention for direct library callers and tests.
    private func fileClearanceReason(
        forPath path: String,
        body: [String: JSONValue]
    ) async -> String? {
        guard let provider = policyProvider else { return nil }
        guard let policy = await provider.currentPolicy() else {
            return "mac_control_policy_unavailable"
        }
        let trigger = body.stringValue("trigger").flatMap { $0.isEmpty ? nil : $0 } ?? "user"
        let decision = MacControlGate.gate(policy, category: "file_ops", trigger: trigger)
        guard decision.allowed else { return decision.reason }
        return MacControlGate.fileReason(policy, forPaths: [path], now: now())
    }

    /// Open the file and turn it into characters. Split out so the fall-through
    /// above reads as one decision instead of a nest.
    private func extractDocument(
        at path: String
    ) -> Result<MacDocumentRead.Extracted, MacDocumentRead.ExtractionFailure> {
        // THE SAME FENCE `file/read` runs, before and after resolving symlinks,
        // and it runs FIRST. "It is a document" is not an exemption: a
        // credentials file is a text file, and an organ that reads text files
        // would otherwise be the one door in the module that walks around this.
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            _ = reason
            return .failure(.sensitivePath)
        }
        let kind = MacDocumentRead.kind(forPath: path)
        if case .unsupported = kind { return .failure(.unsupportedType) }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            _ = reason
            return .failure(.sensitivePath)
        }
        let data: Data
        do {
            data = try fileManagerAdapter.readData(
                at: url,
                maxBytes: MacDocumentRead.maxFileBytes
            )
        } catch {
            return .failure(.unreadableDocument)
        }
        return MacDocumentRead.extract(data: data, kind: kind)
    }

    /// THE ACCUMULATE ROUTE. Walk the frontmost scroll container's text, scroll
    /// one viewport (minus a deliberate overlap band), walk again, merge on the
    /// seam, and stop the moment a frame adds nothing.
    ///
    /// WHAT IT EMITS, exhaustively: one `.move` to aim the wheel at the
    /// container's centre, and vertical `.scroll` events. No key, no button, no
    /// AX action, no attribute write. That emission set is the whole reason this
    /// verb is graded a read, and `MacDocumentReadTests` greps the sink to keep
    /// it true.
    ///
    /// AND IT PUTS THE SCROLL BACK. The user's document is left where it was
    /// found: the same number of steps upward, then one more walk to CHECK —
    /// `scroll_restored` is that comparison against the first frame, never the
    /// fact that inverse events were posted.
    private func readFromScreen(
        started: Date,
        body: [String: JSONValue],
        app requestedTarget: MacAXAppInfo?,
        fellBackFrom: (path: String, reason: String)?,
        declinedInferredPath: (path: String, reason: String)?
    ) async -> MacControlResult {
        func result(ok: Bool, _ output: [String: JSONValue], error: String? = nil) -> MacControlResult {
            var output = output
            if let fellBackFrom {
                output["fell_back_from"] = .object([
                    "path": .string(fellBackFrom.path),
                    "reason": .string(fellBackFrom.reason),
                ])
            }
            // The file route was AVAILABLE and was not taken, because opening
            // that file is file access this call does not hold. Said out loud:
            // a silently downgraded read is a read the caller mistakes for the
            // document.
            if let declinedInferredPath {
                output["file_route_declined"] = .object([
                    "path": .string(declinedInferredPath.path),
                    "reason": .string(declinedInferredPath.reason),
                    "words": .string(
                        MacDocumentRead.filePolicyDeclinedWords(path: declinedInferredPath.path)
                    ),
                ])
            }
            return MacControlResult(
                ok: ok,
                action: "read",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        func refuse(_ code: String, _ words: String) -> MacControlResult {
            result(
                ok: false,
                [
                    "read": .bool(false),
                    "source": .string("screen"),
                    "status": .string(code),
                    "error": .string(code),
                    "message": .string(words),
                ],
                error: code
            )
        }

        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "read") }
        guard let app = requestedTarget else {
            return refuse("no_window", MacDocumentRead.noWindowWords)
        }
        // `windowRoot(pid:)` and NOT `frontmostWindowRoot()`: with `app` named,
        // the window this reads must be that app's, whether or not it is the one
        // in front — and asking by pid is what makes the read work without
        // activating anything.
        guard let window = accessibilitySource.windowRoot(pid: app.processIdentifier) else {
            return refuse("no_window", MacDocumentRead.noWindowWords)
        }

        // gpt-5.5 review — THE CLOCK. See `MacDocumentRead`'s "The clock" note:
        // this organ runs outside the operation store's deadline path on
        // purpose, and it is the heaviest AX caller in the module, so it carries
        // its own two bounds. The per-call one is scoped to THIS app's element
        // and put back on the way out; the wall-clock one is checked between
        // frames below.
        let deadline = now().addingTimeInterval(MacDocumentRead.deadlineSeconds)
        #if canImport(ApplicationServices) && os(macOS)
        if accessibilitySource is SystemMacAXElementSource {
            SystemMacAXElementSource.setMessagingTimeout(
                pid: app.processIdentifier,
                seconds: MacDocumentRead.axMessagingTimeoutSeconds
            )
        }
        defer {
            if accessibilitySource is SystemMacAXElementSource {
                // 0 restores the system default — the bound belonged to this
                // read, not to the app.
                SystemMacAXElementSource.setMessagingTimeout(pid: app.processIdentifier, seconds: 0)
            }
        }
        #endif

        // The READ TARGET: the most specific scrollable/readable container the
        // window offers, falling back to the window itself. A window that IS
        // the text area answers at the first role.
        var container = window
        var containerRole = accessibilitySource.attributes(of: window)?.role ?? "AXWindow"
        for role in MacDocumentRead.containerRoles {
            if let hit = MacAccessibilityReader.findFirst(
                role: role,
                source: accessibilitySource,
                root: window
            ).hit {
                container = hit.ref
                containerRole = role
                break
            }
        }
        let containerFrame = accessibilitySource.attributes(of: container)?.frame
        let scrollContainer = container
        let takeover = MacDocumentReadTakeover()
        let observation = attentionEventSource.start { _ in takeover.mark() }
        defer { observation.stop() }
        func stopReason() async -> String? {
            if Task.isCancelled { return "cancelled" }
            if takeover.occurred { return "yielded_to_user" }
            if let refusal = await attentionActionRefusal(action: "read", body: body) {
                return refusal.error ?? "yielded_to_user"
            }
            // Recheck after the actor hop, immediately before the emission.
            if Task.isCancelled { return "cancelled" }
            if takeover.occurred { return "yielded_to_user" }
            guard let frame = containerFrame,
                  accessibilitySource.documentScrollTargetIsCurrent(
                    window: window, container: scrollContainer, frame: frame, pid: app.processIdentifier
                  ) else { return "scroll_target_changed" }
            return nil
        }

        var accumulator = MacDocumentRead.Accumulator()
        let firstFrame = MacDocumentRead.frameLines(source: accessibilitySource, root: container)
        if firstFrame.lines.isEmpty {
            if firstFrame.secureNodes > 0 {
                return refuse("secure_content", MacDocumentRead.secureContentWords)
            }
            // The clock, not the window: an app that ate the deadline before
            // answering with a single line is UNRESPONSIVE, which is a
            // different fact from a window that publishes no text — and
            // reporting the second when the first is true sends the caller off
            // to `screen` for a window that will not answer that either.
            if now() >= deadline {
                return refuse(
                    MacDocumentRead.timedOutReason,
                    MacDocumentRead.timedOutWords(app: app.name)
                )
            }
            return refuse("no_readable_text", MacDocumentRead.emptyScreenWords)
        }
        _ = accumulator.absorb(firstFrame.lines)

        // Can we move the viewport at all? Answer honestly rather than
        // returning one screenful as if it were the document.
        let canScroll = eventSink.isAvailable && (containerFrame?.h ?? 0) > 0
        var framesRead = 1
        var steps = 0
        var reachedEnd = false
        var truncationReason: String?

        if canScroll, let frame = containerFrame {
            let delta = MacDocumentRead.scrollStepPoints(viewportHeight: frame.h)
            let centreX = frame.x + frame.w / 2
            let centreY = frame.y + frame.h / 2
            truncationReason = await stopReason()
            if truncationReason == nil {
                eventSink.post(mouse: MacMouseEvent(phase: .move, button: .left, x: centreX, y: centreY))
            }
            while framesRead < MacDocumentRead.maxFrames {
                if truncationReason != nil { break }
                if let reason = await stopReason() { truncationReason = reason; break }
                // THE WALL CLOCK, checked BEFORE the next scroll rather than
                // after it: a step already taken has to be put back, and there
                // is no point buying one more frame from an app that has
                // already spent the budget. Breaking here (rather than
                // returning) is deliberate — the scroll restoration below is
                // owed to User's document whether the read finished or not.
                if now() >= deadline {
                    truncationReason = MacDocumentRead.deadlineTruncationReason
                    break
                }
                // `down` moves the content up, which is what a person means by
                // scrolling down — the same sign convention `act` uses.
                eventSink.post(scroll: MacScrollEvent(deltaX: 0, deltaY: -delta, unit: .pixel))
                steps += 1
                await Self.settleForDocumentRead()
                if let reason = await stopReason() { truncationReason = reason; break }
                let next = MacDocumentRead.frameLines(source: accessibilitySource, root: container)
                framesRead += 1
                let absorbed = accumulator.absorb(next.lines)
                if case .nothingNew = absorbed {
                    reachedEnd = true
                    break
                }
                if accumulator.characters >= MacDocumentRead.maxAccumulatedChars {
                    truncationReason = "char_cap"
                    break
                }
            }
            if !reachedEnd && truncationReason == nil && framesRead >= MacDocumentRead.maxFrames {
                truncationReason = "frame_cap"
            }
        }

        // PUT IT BACK, then CHECK. Restoration is a claim, so it is measured.
        var restored: Bool?
        if steps > 0, let frame = containerFrame {
            let delta = MacDocumentRead.scrollStepPoints(viewportHeight: frame.h)
            var safelyRestored = true
            for _ in 0..<steps {
                if let reason = await stopReason() {
                    truncationReason = reason
                    safelyRestored = false
                    break
                }
                eventSink.post(scroll: MacScrollEvent(deltaX: 0, deltaY: delta, unit: .pixel))
            }
            if safelyRestored { await Self.settleForDocumentRead() }
            let finalStop = await stopReason()
            restored = safelyRestored && finalStop == nil && MacDocumentRead
                .frameLines(source: accessibilitySource, root: container)
                .lines == firstFrame.lines
        }

        let redaction = MacClipboardRead.redacted(accumulator.text)
        var output: [String: JSONValue] = [
            "read": .bool(true),
            "source": .string("screen"),
            "app": app.toJSON(),
            "container_role": .string(containerRole),
            "frames": .int(Int64(framesRead)),
            "scroll_steps": .int(Int64(steps)),
            "reached_end": .bool(reachedEnd),
            "truncated": .bool(truncationReason != nil || firstFrame.truncated),
            "gaps": .bool(accumulator.sawGap),
            "chars": .int(Int64(redaction.text.count)),
            "text": .string(redaction.text),
        ]
        if let truncationReason { output["truncation_reason"] = .string(truncationReason) }
        if let restored { output["scroll_restored"] = .bool(restored) }
        if !canScroll {
            output["scrollable"] = .bool(false)
            output["message"] = .string(MacDocumentRead.scrollUnavailableWords)
        }
        // The clock wins the message when it bit: "this is the beginning, not
        // the document" is the thing the caller most needs to hear, and it is
        // the only truncation reason that is about the APP rather than about a
        // cap this organ chose.
        if truncationReason == MacDocumentRead.deadlineTruncationReason {
            output["timed_out"] = .bool(true)
            output["message"] = .string(MacDocumentRead.deadlineWords(app: app.name))
        }
        if accumulator.sawGap {
            output["gap_note"] = .string(
                "Two screenfuls shared no line, so I cannot promise nothing fell between them."
            )
        }
        Self.attachRedaction(redaction, to: &output)
        return result(ok: true, output)
    }

    private static func settleForDocumentRead() async {
        try? await Task.sleep(nanoseconds: UInt64(documentReadSettleMilliseconds) * 1_000_000)
    }

    /// The redaction channel, identical on both routes: a blanked line is
    /// REDACTION and says so, never a short document.
    private static func attachRedaction(
        _ redaction: MacClipboardRead.Redaction,
        to output: inout [String: JSONValue]
    ) {
        output["redacted"] = .bool(redaction.didRedact)
        guard redaction.didRedact else { return }
        output["redactions"] = .array(redaction.redactedLines.map { line in
            .object(["line": .int(Int64(line.line)), "reason": .string(line.reason)])
        })
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

    /// One read EPOCH: the root, its walk, and the focused element's path
    /// anchored to THAT root — never a focus fetched later against whatever
    /// window is frontmost by then (gpt-5.5 BLOCKING 2026-08-22: a focus path
    /// from a different tree that happens to exist in the old snapshot makes a
    /// look lie about where the cursor is). If the focus is not under this
    /// root, `focusPath` is nil and the percept says "focus unknown".
    /// - Parameter pid: when given, the window is taken from THAT process
    ///   instead of from whatever is frontmost — `mac_act`'s identity guard
    ///   (B3) must re-read the app the frame came from, or a background act
    ///   would be refused as drift the moment another app took focus.
    private func axSnapshot(
        limits: MacAXLimits,
        pid: Int32? = nil
    ) -> MacAnchoredRead {
        anchoredSnapshot(limits: limits, pid: pid, window: nil)
    }

    /// One vocabulary for the self-refusal across every read tool.
    static let selfInspectionError = "self_inspection_unsupported"
    static let selfInspectionNote =
        "the target is NativeAgent's own window, and reading our own UI over AX "
        + "deadlocks the app (in-process AppKit re-entry) — self-inspection via AX "
        + "is refused; look at another app's window instead"

    private func selfInspectionResult(action: String, started: Date) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "trusted": .bool(true),
                "status": .string(Self.selfInspectionError),
                "error": .string(Self.selfInspectionError),
                "message": .string(Self.selfInspectionNote),
            ]),
            error: Self.selfInspectionError,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// The outcome of a WINDOW-ANCHORED read (gpt-5.5 round-3 B1/B2).
    ///
    /// "No window" is three different facts and the caller has to tell them
    /// apart: the app is gone, the app is there but the window she looked at is
    /// not, or several windows are equally plausible and picking one would be a
    /// coin flip.
    enum MacAnchoredRead {
        case read(MacAXRead)
        case appGone
        case windowGone
        case windowDrifted(String)
        /// The target is NativeAgent's own process. An AX walk of our own tree
        /// re-enters AppKit in-process (P1 deadlock, sample 2026-08-28:
        /// `AXUIElementCopyActionNames` on our own toolbar ran
        /// `+[NSToolbarView defaultMenu]` → `-[NSOperation waitUntilFinished]`
        /// on a background cooperative thread while the main thread was parked
        /// in SwiftUI's update lock — mutual wait, force-kill to recover).
        /// AX perception is for OTHER processes; the walk is refused before a
        /// single element is read.
        case selfProcess
    }

    /// One read epoch, optionally anchored to a NAMED WINDOW of a named process.
    ///
    /// - `pid` nil ⇒ the frontmost window of the frontmost app (`mac_ax_tree`,
    ///   `mac_ax_find`, the first look).
    /// - `pid` given, `window` nil ⇒ that process's first window, as before.
    /// - `pid` AND `window` given ⇒ the window whose composite identity matches,
    ///   or a refusal. Never "focused, else main, else first" inside the pid:
    ///   with two windows of one app, a focus change between the look and the
    ///   act silently re-points the read at the other one, and the pid claim
    ///   still passes (round-2 B2 was necessary, not sufficient).
    func anchoredSnapshot(
        limits: MacAXLimits,
        pid: Int32?,
        window: MacAXWindowIdentity?
    ) -> MacAnchoredRead {
        // See `MacAnchoredRead.selfProcess` — refusing here, before any element
        // is resolved, is what keeps the in-process AppKit re-entry deadlock
        // structurally unreachable from every snapshot caller.
        if pid == getpid() { return .selfProcess }
        let root: MacAXElementRef
        var identity: MacAXWindowIdentity?
        if let pid {
            let candidates = accessibilitySource.windowRoots(pid: pid)
            guard !candidates.isEmpty else { return .appGone }
            if let window {
                switch MacAXWindowIdentity.match(
                    window,
                    among: candidates.map { (handle: $0, identity: $0.identity) }
                ) {
                case .matched(let hit, _):
                    root = hit.ref
                    identity = hit.identity
                case .gone:
                    return .windowGone
                case .ambiguous(let reason):
                    return .windowDrifted(reason)
                }
            } else {
                root = candidates[0].ref
                identity = candidates[0].identity
            }
        } else {
            if let front = accessibilitySource.frontmostApp(),
               front.processIdentifier == getpid() {
                return .selfProcess
            }
            guard let frontmost = accessibilitySource.frontmostWindowRoot() else { return .appGone }
            root = frontmost
            // The frontmost read still names its window, so the FRAME it mints
            // can be re-found later — that is what makes the first look
            // anchorable at all. The window's INDEX is unknown on this path
            // (`frontmostWindowRoot()` answers with a window, not a position),
            // and `nil` is how the identity says so: an index it guessed at
            // would score a wrong candidate up.
            if let app = accessibilitySource.frontmostApp(),
               let attributes = accessibilitySource.attributes(of: root) {
                identity = MacAXWindowIdentity(
                    pid: app.processIdentifier,
                    index: nil,
                    role: attributes.role,
                    subrole: attributes.subrole,
                    title: attributes.title,
                    frame: attributes.frame
                )
            }
        }
        let snapshot = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: root,
            limits: limits
        )
        let focusPath = accessibilitySource.focusedElementPath(relativeTo: root)
        return .read(MacAXRead(
            snapshot: snapshot,
            // S7 — a pid-anchored read reports THAT process, never
            // `frontmostApp()`. When the source cannot name it, the pid itself
            // is still the truth and stays carried (the frame's whole anchor
            // hangs off it); the NAME is not invented from another app's.
            app: pid.map { anchored in
                accessibilitySource.appInfo(pid: anchored)
                    ?? MacAXAppInfo(
                        name: "pid \(anchored)",
                        bundleIdentifier: nil,
                        processIdentifier: anchored
                    )
            } ?? accessibilitySource.frontmostApp(),
            rootTitle: snapshot.nodes.first?.attributes.title,
            focusPath: focusPath,
            root: root,
            windowIdentity: identity
        ))
    }

    /// Agent round 2, her #1-ranked gap — PAGE-FIRST perception for a
    /// Chromium/Electron window.
    ///
    /// The ordinary walk starts at the window and spends its 400 nodes and 12
    /// levels on the toolbar and the bookmarks bar, hitting `depth_cap` before
    /// it reaches the `AXWebArea` at all: her Chrome look was blind to the page
    /// she was looking at. So when the frontmost window is chromium-family and
    /// a web area can be FOUND (bounded, read-only, same seam), the percept is
    /// compiled from the PAGE, and the browser chrome collapses to one line.
    ///
    /// Paths stay WINDOW-RELATIVE: the page walk is re-based onto the web
    /// area's own path, because `mac_act` resolves a child-index chain from the
    /// window root and a page-relative path would address a different element
    /// entirely.
    private func pageScoped(
        _ windowRead: MacAXRead,
        limits: MacAXLimits,
        scope: MacLookScope
    ) -> (read: MacAXRead, seam: [String: JSONValue]) {
        var seam: [String: JSONValue] = [:]
        let chromiumFamily = MacChromiumAccessibility.looksChromium(
            bundleId: windowRead.app?.bundleIdentifier,
            snapshot: windowRead.snapshot
        ) || MacChromiumAccessibility.hasWebArea(windowRead.snapshot)
        guard scope != .chrome, chromiumFamily else {
            seam["scope"] = .string(scope == .page && !chromiumFamily ? "chrome" : scope.rawValue)
            if scope == .page, !chromiumFamily {
                seam["scope_reason"] = .string("not_a_chromium_window")
            }
            return (windowRead, seam)
        }
        let search = MacAccessibilityReader.findFirst(
            role: "AXWebArea",
            source: accessibilitySource,
            root: windowRead.root
        )
        guard let web = search.hit else {
            // gpt-5.5 round-3 S5 — the fallback to chrome scope is right; the
            // REASON was not. A deep or wide Chromium shell can spend the
            // 160-node search budget before reaching the page, and reporting
            // that as `no_web_area_found` claims the page does not exist on the
            // authority of a search that never got there.
            seam["scope"] = .string("chrome")
            if let reason = search.truncationReason {
                seam["scope_reason"] = .string("web_area_search_truncated")
                seam["web_area_search_limit"] = .string(reason)
                seam["web_area_search_budget"] = .object([
                    "max_depth": .int(Int64(MacAccessibilityReader.findFirstMaxDepth)),
                    "node_budget": .int(Int64(MacAccessibilityReader.findFirstNodeBudget)),
                ])
                seam["scope_note"] = .string(
                    "the search for the page ran out of \(reason == "node_cap" ? "nodes" : "depth") "
                    + "before finding it — this is the browser chrome, and the page may still be "
                    + "there unseen"
                )
            } else {
                seam["scope_reason"] = .string("no_web_area_found")
            }
            return (windowRead, seam)
        }
        if scope == .both {
            // The whole window in ONE walk, page included as far as the budget
            // reaches. Named honestly: the page COMPETES with the chrome for
            // the node budget here, which is exactly the failure `page` exists
            // to avoid.
            seam["scope"] = .string("both")
            seam["web_area_path"] = .array(web.path.map { .int(Int64($0)) })
            seam["scope_note"] = .string(
                "the page shares the node budget with the browser chrome in this scope — use "
                + "scope:\"page\" to spend the whole budget on the page"
            )
            return (windowRead, seam)
        }
        let pageWalk = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: web.ref,
            limits: limits
        )
        // Re-base every path onto the web area's own path from the window root.
        let rebased = MacAXTreeSnapshot(
            nodes: pageWalk.nodes.map { MacAXNode(attributes: $0.attributes, path: web.path + $0.path) },
            truncated: pageWalk.truncated,
            truncationReasons: pageWalk.truncationReasons,
            skippedAtLeast: pageWalk.skippedAtLeast
        )
        let pageFocus = accessibilitySource.focusedElementPath(relativeTo: web.ref).map { web.path + $0 }
        let chromeControls = windowRead.snapshot.nodes.filter { node in
            MacPerceptionCompiler.isInteractive(node.attributes)
                && !node.path.starts(with: web.path)
        }.count
        seam["scope"] = .string("page")
        seam["web_area_path"] = .array(web.path.map { .int(Int64($0)) })
        seam["chrome"] = .string(
            "browser chrome: toolbar + bookmarks bar, \(chromeControls) control(s) — "
            + "call mac_look {scope: \"chrome\"} to address them"
        )
        seam["chrome_controls"] = .int(Int64(chromeControls))
        return (
            MacAXRead(
                snapshot: rebased,
                app: windowRead.app,
                // The WINDOW's title, not the web area's: it is what names the
                // window in every other channel, and dropping it here would
                // make the page look like it belonged to nothing.
                rootTitle: windowRead.rootTitle,
                focusPath: pageFocus,
                root: web.ref,
                // The page walk is still a walk OF THAT WINDOW — the frame it
                // mints has to be re-findable, and the web area is not a window.
                windowIdentity: windowRead.windowIdentity
            ),
            seam
        )
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
        let anchored = axSnapshot(limits: limits)
        if case .selfProcess = anchored {
            return selfInspectionResult(action: "ax_tree", started: started)
        }
        guard case .read(let read) = anchored else {
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

    // MARK: - native-look item 2: `look`

    /// The Chromium/Electron live seam. Runs BEFORE the walk that matters.
    ///
    /// Returns the snapshot to compile from. Order:
    ///   1. one ordinary walk;
    ///   2. if the frontmost app looks Chromium-family (known bundle id, or a
    ///      web-less shell-sized window), set both enhanced-AX flags on the APP
    ///      element and read them back;
    ///   3. if the first walk found no `AXWebArea`, poll every 500 ms for up to
    ///      4 s and re-walk EXACTLY ONCE more.
    ///
    /// The flag is left set (see `MacChromiumAccessibility` for the lifetime
    /// rule) and cleared lazily here when the frontmost app changed or the last
    /// frame expired — never by a background timer.
    ///
    /// - Parameters anchorPid/anchorWindow: gpt-5.5 round-3 B2. The POST-ACT
    ///   read must be of the window the act happened in, not of whatever is
    ///   frontmost by then: a correct background act followed by a frontmost
    ///   read describes — and then STORES AS THE NEW FRAME — a different app's
    ///   window entirely. When they are given, every walk here (including the
    ///   Chromium settle re-walk) targets that window, and the outcome carries
    ///   the anchor failure instead of silently reading something else.
    private func lookSnapshot(
        limits: MacAXLimits,
        scope: MacLookScope = .page,
        anchorPid: Int32? = nil,
        anchorWindow: MacAXWindowIdentity? = nil
    ) async -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
        var seam: [String: JSONValue] = [
            "chromium_family": .bool(false),
            "enhanced_ax_set": .bool(false),
            "rewalked": .bool(false),
        ]
        func anchoredRead() -> MacAnchoredRead {
            anchoredSnapshot(limits: limits, pid: anchorPid, window: anchorWindow)
        }
        let firstAnchor = anchoredRead()
        // A self-process target is a refusal on BOTH the anchored and the
        // unanchored path — the caller needs the reason, not a generic
        // "no window" (the walk was refused, not absent).
        if case .selfProcess = firstAnchor { return (nil, seam, firstAnchor) }
        var read: MacAXRead? = {
            if case .read(let hit) = firstAnchor { return hit }
            return nil
        }()
        // Only the ANCHORED call reports an anchor failure; an unanchored look
        // has no window to have lost.
        let anchorFailure: MacAnchoredRead? = {
            guard anchorPid != nil || anchorWindow != nil else { return nil }
            if case .read = firstAnchor { return nil }
            return firstAnchor
        }()
        if anchorFailure != nil { return (nil, seam, anchorFailure) }

        /// A2 — the page-first descent, applied to whatever walk we end up
        /// with. Outside the live-source guard below on purpose: the ENHANCED-AX
        /// flag needs a real AX app element, but finding the web area and
        /// walking from it is ordinary reading that any source can answer, which
        /// is also what makes it testable against a synthetic Chromium tree.
        func scoped(
            _ candidate: (read: MacAXRead?, seam: [String: JSONValue])
        ) -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
            guard let value = candidate.read else { return (nil, candidate.seam, nil) }
            let outcome = pageScoped(value, limits: limits, scope: scope)
            var merged = candidate.seam
            for (key, item) in outcome.seam { merged[key] = item }
            return (outcome.read, merged, nil)
        }

        #if canImport(ApplicationServices) && os(macOS)
        // The seam only exists for the LIVE source. A synthetic/unavailable
        // source has no app element to flag, and pretending otherwise would be
        // a stub that reports work it did not do.
        guard accessibilitySource is SystemMacAXElementSource else { return scoped((read, seam)) }
        // B2 — the ANCHOR's pid wins. Flagging (and later clearing) enhanced-AX
        // on whatever is frontmost while reading an anchored background window
        // would mutate a third app's accessibility state.
        let pid = anchorPid
            ?? read?.app?.processIdentifier
            ?? accessibilitySource.frontmostApp()?.processIdentifier
        // Lazy clear: the previous app's flag stops being the frame's flag the
        // moment the frontmost app changes or the frame dies.
        let previous = await MacChromiumAccessibilityState.shared.current()
        let frameExpired = await lookFrameStore.isExpired(now: now())
        if let previous, previous != pid || frameExpired {
            SystemMacAXElementSource.setEnhancedAccessibility(pid: previous, enabled: false)
            await MacChromiumAccessibilityState.shared.note(pid: nil)
            seam["enhanced_ax_cleared_pid"] = .int(Int64(previous))
        }

        guard let pid,
              MacChromiumAccessibility.looksChromium(
                bundleId: read?.app?.bundleIdentifier,
                snapshot: read?.snapshot
              )
        else { return scoped((read, seam)) }

        seam["chromium_family"] = .bool(true)
        // Chrome's setter returns kAXErrorCannotComplete and the flag STILL
        // takes effect, so the status is discarded and the READ-BACK is the
        // evidence. A false read-back is reported, not treated as fatal.
        let readsBack = SystemMacAXElementSource.setEnhancedAccessibility(pid: pid, enabled: true)
        seam["enhanced_ax_set"] = .bool(readsBack)
        await MacChromiumAccessibilityState.shared.note(pid: pid)

        if !MacChromiumAccessibility.hasWebArea(read?.snapshot) {
            let deadline = now().addingTimeInterval(MacChromiumAccessibility.settleSeconds)
            while now() < deadline {
                try? await Task.sleep(
                    nanoseconds: UInt64(MacChromiumAccessibility.pollSeconds * 1_000_000_000)
                )
                if case .read(let candidate) = anchoredRead(),
                   MacChromiumAccessibility.hasWebArea(candidate.snapshot) {
                    read = candidate
                    seam["rewalked"] = .bool(true)
                    break
                }
            }
            if seam["rewalked"] != .bool(true) {
                // Exactly one re-walk even when no web area ever appeared, so a
                // slow-but-enhanced tree is not missed and the caller learns the
                // settle produced nothing.
                if case .read(let candidate) = anchoredRead() {
                    read = candidate
                }
                seam["rewalked"] = .bool(true)
                seam["web_area_after_settle"] = .bool(MacChromiumAccessibility.hasWebArea(read?.snapshot))
            }
        }
        #endif
        return scoped((read, seam))
    }

    /// `mac_look` — the perception compiler's tool surface.
    ///
    /// Three grades of attention over ONE walk. `stare` is DELEGATED to
    /// `handleAXTree` rather than reimplemented, so the full-tree payload can
    /// never drift from `mac_ax_tree`'s.
    private func handleLook(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let grade = (body.stringValue("grade") ?? "look").lowercased()
        guard ["glance", "look", "stare"].contains(grade) else {
            return MacControlResult(
                ok: false,
                action: "look",
                output: .object([
                    "error": .string("unknown_grade"),
                    "grade": .string(grade),
                    "message": .string("grade must be one of: glance, look, stare"),
                ]),
                error: "unknown_grade",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "look") }

        // fable51 item 32a — BACKGROUND SIGHT. `app` names a running app whose
        // front window is read WITHOUT activating it: the anchor
        // `lookSnapshot` has always accepted, finally reachable by a caller.
        // Nothing on this path focuses, launches or raises anything.
        var anchorPid: Int32?
        var anchoredApp: MacAXAppInfo?
        if let requested = body.stringValue("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard grade != "stare" else {
                return MacControlResult(
                    ok: false,
                    action: "look",
                    output: .object([
                        "error": .string("background_stare_unsupported"),
                        "message": .string(
                            "A background window can be read at glance or look; stare is the "
                            + "frontmost raw tree only."
                        ),
                    ]),
                    error: "background_stare_unsupported",
                    durationMs: Int(now().timeIntervalSince(started) * 1000),
                    viaSwift: true
                )
            }
            let resolution = MacBackgroundSight.resolve(
                requested,
                among: accessibilitySource.runningApps()
            )
            guard case .matched(let app) = resolution else {
                let words = MacBackgroundSight.words(for: resolution, requested: requested)
                    ?? "I couldn't find a running app called \"\(requested)\"."
                let code: String = {
                    switch resolution {
                    case .selfProcess: return "self_inspection_refused"
                    case .ambiguous: return "app_ambiguous"
                    default: return "app_not_running"
                    }
                }()
                return MacControlResult(
                    ok: false,
                    action: "look",
                    output: .object([
                        "trusted": .bool(true),
                        "grade": .string(grade),
                        "requested_app": .string(requested),
                        "status": .string(code),
                        "error": .string(code),
                        "message": .string(words),
                    ]),
                    error: code,
                    durationMs: Int(now().timeIntervalSince(started) * 1000),
                    viaSwift: true
                )
            }
            anchorPid = app.processIdentifier
            anchoredApp = app
        }

        if grade == "stare" {
            // The SAME payload mac_ax_tree returns, from the same handler.
            let tree = handleAXTree(body)
            var output: [String: JSONValue] = [:]
            if case .object(let object) = tree.output { output = object }
            output["grade"] = .string("stare")
            return MacControlResult(
                ok: tree.ok,
                action: "look",
                output: .object(output),
                error: tree.error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }

        guard let scope = MacLookScope.parse(body.stringValue("scope")) else {
            return MacControlResult(
                ok: false,
                action: "look",
                output: .object([
                    "error": .string("unknown_scope"),
                    "scope": body["scope"] ?? .null,
                    "message": .string("scope must be one of: page, chrome, both"),
                ]),
                error: "unknown_scope",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let limits = Self.axLimits(from: body)
        let (read, seam, anchor) = await lookSnapshot(
            limits: limits,
            scope: scope,
            anchorPid: anchorPid
        )
        if case .selfProcess? = anchor {
            return selfInspectionResult(action: "look", started: started)
        }
        guard let read else {
            // An anchored read that found nothing is a DIFFERENT fact from "no
            // frontmost window": the app is running but has no readable window
            // (minimized, or all windows closed). Saying the frontmost thing
            // would describe a window that was never asked about.
            let status = anchoredApp == nil ? "no_frontmost_window" : "no_window_in_app"
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "status": .string(status),
                "error": .string(status),
            ]
            if let anchoredApp {
                output["requested_app"] = .string(anchoredApp.name)
                output["message"] = .string(
                    "\(anchoredApp.name) is running but has no window I can read right now "
                    + "(it may be minimized or have every window closed)."
                )
            }
            return MacControlResult(
                ok: false,
                action: "look",
                output: .object(output),
                error: status,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }

        let percept = MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            app: read.app,
            windowTitle: read.rootTitle,
            // Same read epoch as the walk, anchored to the walked root.
            focusPath: read.focusPath,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances
        )

        // Render FIRST, so the frame mints handles only for the rows she will
        // actually see (the byte budget may trim the tail) — "handles valid for
        // this frame_id" means the handles in THIS payload. A glance shows no
        // rows, so it mints every affordance and says how many are addressable.
        let capturedAt = now()
        let frameId = UUID().uuidString

        /// Everything except the byte accounting, so the S5 loop below can
        /// serialize the COMPLETE object — envelope, `how_to_read` and all —
        /// rather than a percept plus a guessed reserve.
        func envelopeJSON(_ rendering: MacLookPercept.LookRendering?) -> [String: JSONValue] {
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "frame_id": .string(frameId),
                "captured_at": .string(ISO8601DateFormatter().string(from: capturedAt)),
                "frame_ttl_seconds": .int(Int64(MacLookFrameStore.ttlSeconds)),
                "seam": .object(seam),
                // fable51 item 32a — WHOSE window this is, and whether it is in
                // front. Both grades publish it because the caller's renderer
                // must not print "in front" over a background read: an
                // unanchored look is frontmost by construction, an anchored one
                // is only frontmost by coincidence.
                "front": .bool(
                    anchoredApp.map {
                        accessibilitySource.frontmostApp()?.processIdentifier == $0.processIdentifier
                    } ?? true
                ),
                "anchored": .bool(anchoredApp != nil),
                // Agent round 2 — `max_nodes`/`max_depth` read as "silently
                // ignored" because nothing in the payload said what they
                // resolved to. They are honored and CLAMPED (a caller may only
                // lower them); now the payload says so out loud.
                "limits": .object([
                    "max_nodes": .int(Int64(limits.maxNodes)),
                    "max_depth": .int(Int64(limits.maxDepth)),
                    "hard_max_nodes": .int(Int64(MacAXLimits.hardMaxNodes)),
                    "hard_max_depth": .int(Int64(MacAXLimits.hardMaxDepth)),
                ]),
            ]
            // fable51 item 32b (gpt-5.5 review) — THE WINDOW'S OWN RECTANGLE.
            // Both grades publish it because a caller that has to decide
            // whether raising this window would cover a point elsewhere on the
            // screen cannot answer that from the elements read INSIDE it: a
            // title bar, a toolbar and a blank body publish no element and are
            // still the window. The cross-app drag's coverage refusal turns on
            // this; absent when the walk could not name a window, which the
            // caller reads as "unknown", never as "empty".
            if let windowFrame = read.windowIdentity?.frame {
                output["window_frame"] = windowFrame.toJSON()
            }
            if grade == "glance" {
                output["glance"] = .string(percept.glanceLine())
                output["addressable_handles"] = .int(Int64(percept.affordances.count))
                output["how_to_read"] = .string(
                    "One distilled line. Call mac_look {grade: \"look\"} for the addressable "
                    + "affordances (\(percept.affordances.count) labeled control(s) in this frame), "
                    + "or {grade: \"stare\"} for the full AX tree."
                )
            } else if let rendering {
                if case .object(let lookObject) = rendering.json {
                    for (key, value) in lookObject { output[key] = value }
                }
                output["glance"] = .string(percept.glanceLine())
                output["percept_bytes"] = .int(Int64(rendering.bytes))
                output["how_to_read"] = .string(
                    "`affordances` are the things you can act on, each with a stable `handle` for "
                    + "THIS frame_id and its `path` as the fallback. `unlabeled` counts the "
                    + "interactive controls the app publishes no name for — they exist, they are "
                    + "just unnamed. `readouts` are the read-only values on screen (a total, a "
                    + "display, a status line) — what you can READ without touching anything. "
                    + "Handles are valid only for the latest frame; take another look "
                    + "if the screen may have changed."
                )
            }
            return output
        }

        func serializedSize(_ object: [String: JSONValue]) -> Int {
            (try? JSONValue.object(object).serializedData(pretty: false).count) ?? 0
        }

        var rendering: MacLookPercept.LookRendering? = grade == "look" ? percept.lookJSON() : nil
        var output = envelopeJSON(rendering)
        if grade == "look" {
            // gpt-5.5 round-2 S5 — the EXACT final cap. The old code held back a
            // fixed 768-byte reserve for the envelope and then measured; a
            // window with a long title and a fat `seam` blew straight through
            // `lookByteBudget` and the payload said `bytes: 6600` as if that
            // were fine. Now the COMPLETE object (including its own `bytes`
            // field, hence the slack) is serialized, and rows are trimmed until
            // it really fits.
            var reserve = MacPerceptionCompiler.lookEnvelopeReserve
            var attempts = 0
            while attempts < 8 {
                var candidate = output
                candidate["bytes"] = .int(Int64(MacPerceptionCompiler.lookByteBudget))
                let size = serializedSize(candidate)
                if size <= MacPerceptionCompiler.lookByteBudget { break }
                let overshoot = size - MacPerceptionCompiler.lookByteBudget
                reserve += overshoot + 64
                let next = percept.lookJSON(envelopeReserve: reserve)
                // The trimmer has nothing left to give: stop rather than spin.
                if next.bytes >= (rendering?.bytes ?? Int.max) { rendering = next; output = envelopeJSON(next); break }
                rendering = next
                output = envelopeJSON(next)
                attempts += 1
            }
        }

        let renderedRows: Int? = rendering.map { rendering in
            if case .object(let object) = rendering.json,
               case .array(let rows)? = object["affordances"] { return rows.count }
            return 0
        }

        // The frame is minted for BOTH structured grades: a glance that named a
        // control she then cannot address would be a tease, and item 3's verbs
        // resolve handles through exactly this store.
        await lookFrameStore.record(MacLookFrame.from(
            percept: percept,
            frameId: frameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            rendered: renderedRows,
            // B1 — WHICH window this look was of. Without it `mac_act` can only
            // re-find the app, and picks "focused, else main, else first"
            // inside it.
            windowIdentity: read.windowIdentity,
            // Recorded so the NEXT act can tell "the window changed" from "the
            // recompile ran under different bounds and lost rows".
            caps: MacLookCompileCaps(
                truncated: percept.truncated,
                maxAffordances: Self.intValue(body, "max_affordances")
                    ?? MacPerceptionCompiler.maxAffordances,
                maxNodes: limits.maxNodes,
                maxDepth: limits.maxDepth
            )
        ))

        if grade == "look" {
            // `bytes` is the WHOLE payload she receives, measured with the
            // field itself in place — the number is the truth, not an estimate.
            var measured = output
            // Fixpoint, because the number's own digits are part of the
            // payload: write the measured size, re-measure, repeat until it
            // stops moving (two passes in practice, three at a digit boundary).
            measured["bytes"] = .int(0)
            var claimed = serializedSize(measured)
            for _ in 0..<4 {
                measured["bytes"] = .int(Int64(claimed))
                let actual = serializedSize(measured)
                if actual == claimed { break }
                claimed = actual
            }
            output["bytes"] = .int(Int64(claimed))
            let exact = serializedSize(output)
            if exact > MacPerceptionCompiler.lookByteBudget {
                // Never silently over budget: an envelope alone can exceed it
                // (a pathological window title), and a caller sizing its context
                // must be told rather than surprised.
                output["byte_budget_exceeded"] = .bool(true)
                output["byte_budget"] = .int(Int64(MacPerceptionCompiler.lookByteBudget))
            }
        }
        return MacControlResult(
            ok: true,
            action: "look",
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
        let anchored = axSnapshot(limits: limits)
        if case .selfProcess = anchored {
            return selfInspectionResult(action: "ax_find", started: started)
        }
        guard case .read(let read) = anchored else {
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
        let viewStartedNs = DispatchTime.now().uptimeNanoseconds
        func cancelledResult() -> MacControlResult {
            MacControlResult(
                ok: false, action: "view",
                output: .object([
                    "view": .null, "view_current": .bool(false), "image": .null,
                    "view_note": .string("This screen request was cancelled; no new view was published."),
                ]),
                error: "view_capture_cancelled",
                durationMs: Int(now().timeIntervalSince(started) * 1000), viaSwift: true
            )
        }
        guard !Task.isCancelled else { return cancelledResult() }
        let captureTicket = await screenViewStore.beginCapture()
        func cancelCapture() async -> MacControlResult {
            await screenViewStore.cancelCapture(captureTicket)
            return cancelledResult()
        }
        guard !Task.isCancelled else { return await cancelCapture() }
        func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
            Int64((end &- start) / 1_000_000)
        }
        // The four-verb semantic screen consumes the same frozen capture as
        // mac_view, but its visual compiler must see the world rather than the
        // human-facing numbered ink we draw on top of it. This is an internal
        // rendering choice only: geometry, AX marks, redaction, permissions,
        // view storage, and the public result contract remain unchanged.
        let semanticRawFrame = body["semantic_raw_frame"] == .bool(true)
        let semanticFocusVisualSurface = body["semantic_focus_visual_surface"] == .bool(true)
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
        let axSnapshotStartedNs = DispatchTime.now().uptimeNanoseconds
        var windowRect: MacAXFrame?
        var app: MacAXAppInfo?
        var windowTitle: String?
        var snapshot: MacAXTreeSnapshot?
        var axSelfRefused = false
        if accessibilityTrusted {
            switch axSnapshot(limits: limits) {
            case .read(let read):
                snapshot = read.snapshot
                app = read.app
                windowTitle = read.rootTitle
                windowRect = read.snapshot.nodes.first?.attributes.frame
            case .selfProcess:
                // The view degrades to pixels-only, like an untrusted AX read:
                // the capture is still honest, only the tree is refused.
                axSelfRefused = true
            case .appGone, .windowGone, .windowDrifted:
                break
            }
        }
        let transientMenus = app.map {
            MacTransientMenus.read(source: accessibilitySource, pid: $0.processIdentifier)
        } ?? []
        let axSnapshotFinishedNs = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return await cancelCapture() }
        let captureRect: MacAXFrame? = (scope == .fullScreen) ? nil
            : MacTransientMenus.captureFrame(window: windowRect, menus: transientMenus)
        let capturedAt = now()
        let screenCaptureStartedNs = DispatchTime.now().uptimeNanoseconds
        let capture = await screenCaptureSource.capture(rect: captureRect)
        guard !Task.isCancelled else { return await cancelCapture() }
        let screenCaptureFinishedNs = DispatchTime.now().uptimeNanoseconds
        let observedPointer = pointerPositionSource.currentPosition()
        let fusionGapMs = Int(abs(now().timeIntervalSince(capturedAt)) * 1000)

        var output: [String: JSONValue] = [
            "accessibility_trusted": .bool(accessibilityTrusted),
            "screen_recording_trusted": .bool(screenTrusted),
            "scope": .string(scope.rawValue),
            "app": app?.toJSON() ?? .null,
            "transient_menus": MacTransientMenus.json(transientMenus),
            "pointer": observedPointer?.json ?? .null,
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
            "ax_snapshot_ms": .int(elapsedMilliseconds(
                from: axSnapshotStartedNs, to: axSnapshotFinishedNs
            )),
            "screen_capture_ms": .int(elapsedMilliseconds(
                from: screenCaptureStartedNs, to: screenCaptureFinishedNs
            )),
        ]
        if !accessibilityTrusted {
            output["accessibility_note"] = .string(MacAccessibilityReader.notTrustedNote)
        }
        if axSelfRefused {
            output["accessibility_note"] = .string(Self.selfInspectionNote)
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
            guard let rect = captureRect ?? windowRect, rect.w > 0, rect.h > 0 else { return nil }
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
        let sceneSelectionStartedNs = DispatchTime.now().uptimeNanoseconds
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
        let sceneSelectionFinishedNs = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return await cancelCapture() }

        // 4. Draw them, under the byte cap. Pixel-first semantic perception
        // gets the dominant canvas/image cropped from the native capture BEFORE
        // PNG fitting. Otherwise a high-entropy moving canvas spends the whole
        // window's byte budget before OCR ever sees its small status text.
        var imageDownscale: Double?
        var imageBytes: Int?
        let imageRenderStartedNs = DispatchTime.now().uptimeNanoseconds
        if let shot, let geometry {
            let semanticFocusFrame = semanticFocusVisualSurface
                ? snapshot.flatMap {
                    MacScreenViewBuilder.dominantVisualSurface(nodes: $0.nodes, geometry: geometry)
                }
                : nil
            #if canImport(CoreGraphics)
            let renderShot = semanticFocusFrame.flatMap { shot.cropped(to: $0) } ?? shot
            #else
            let renderShot = shot
            #endif
            let renderGeometry = MacScreenViewGeometry(shot: renderShot)
            let placements = semanticRawFrame
                ? []
                : selection.marks.compactMap {
                    renderGeometry.placement(mark: $0.mark, frame: $0.frame)
                }
            let fitted = MacScreenViewBuilder.fitImage(maxBytes: maxImageBytes) { rung in
                guard !Task.isCancelled else { return nil }
                return screenImageRenderer.renderPNG(shot: renderShot, placements: placements, downscale: rung)
            }
            guard !Task.isCancelled else { return await cancelCapture() }
            if let fitted {
                output["image"] = .string(fitted.data.base64EncodedString())
                output["image_format"] = .string("png")
                output["image_annotations"] = .bool(!semanticRawFrame)
                imageDownscale = fitted.downscale
                imageBytes = fitted.data.count
                output["image_origin"] = .object([
                    "x": .double(renderGeometry.bounds.x),
                    "y": .double(renderGeometry.bounds.y),
                ])
                output["image_logical_size"] = .object([
                    "w": .double(renderGeometry.bounds.w),
                    "h": .double(renderGeometry.bounds.h),
                ])
                output["image_pixel_size"] = .object([
                    "w": .int(Int64(renderGeometry.pixelWidth)),
                    "h": .int(Int64(renderGeometry.pixelHeight)),
                ])
                output["semantic_focus_frame"] = semanticFocusFrame.map { frame in
                    .object([
                        "x": .double(frame.x), "y": .double(frame.y),
                        "w": .double(frame.w), "h": .double(frame.h),
                    ])
                } ?? .null
            } else {
                imageFailure = .exceedsByteCap
            }
        }
        let imageRenderFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["image_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderStartedNs, to: imageRenderFinishedNs
        ))
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
            if output["image_pixel_size"] == nil {
                output["image_pixel_size"] = .object([
                    "w": .int(Int64(geometry.pixelWidth)),
                    "h": .int(Int64(geometry.pixelHeight)),
                ])
            }
        }

        // 5. Remember it, so `mark` can be resolved — and hand back its id.
        //    The id is the ONLY way to address these numbers later; an older
        //    one is refused rather than silently re-interpreted.
        guard !Task.isCancelled else { return await cancelCapture() }
        let viewId = UUID().uuidString
        let viewCurrent = await screenViewStore.record(MacScreenViewSnapshot(
            viewId: viewId,
            capturedAt: capturedAt,
            scope: scope,
            bounds: geometry?.bounds ?? MacAXFrame(x: 0, y: 0, w: 0, h: 0),
            appName: app?.name,
            windowTitle: windowTitle,
            marks: selection.marks
        ), captureTicket: captureTicket)
        if !viewCurrent && Task.isCancelled { return await cancelCapture() }
        output["view"] = viewCurrent ? .string(viewId) : .null
        output["view_current"] = .bool(viewCurrent)
        if !viewCurrent {
            output["view_note"] = .string("This capture was superseded or invalidated while in flight. Its image and legend are diagnostic only; take a fresh view before acting.")
        }
        output["captured_at"] = .string(ISO8601DateFormatter().string(from: capturedAt))
        // Motion perception needs subsecond frame spacing. Keep the legacy
        // human timestamp, but never round the machine observation clock.
        output["captured_at_epoch_seconds"] = .double(capturedAt.timeIntervalSince1970)
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
        let viewFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["scene_selection_ms"] = .int(elapsedMilliseconds(
            from: sceneSelectionStartedNs, to: sceneSelectionFinishedNs
        ))
        output["post_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderFinishedNs, to: viewFinishedNs
        ))
        output["view_total_ms"] = .int(elapsedMilliseconds(
            from: viewStartedNs, to: viewFinishedNs
        ))
        // ok reflects whether ANY perception came back. Both permissions off is
        // a real failure; either one on is a real answer.
        let ok = viewCurrent && (accessibilityTrusted || output["image"] != .null)
        return MacControlResult(
            ok: ok,
            action: "view",
            output: .object(output),
            error: ok ? nil : (viewCurrent ? "no_perception_available" : "view_capture_superseded"),
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
    // (accessibility category + active Full Mac window + body-bound injection
    // capability, supplied by admitted YOLO or an exact approved replay).
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

    static func intValue(_ body: [String: JSONValue], _ key: String) -> Int? {
        switch body[key] ?? .null {
        case .int(let n): return Int(exactly: n)
        // Finiteness alone does not imply Int representability. Preserve the
        // existing truncation, then reject values outside the integer range.
        // Double(Int.max) itself rounds UP, so a <= bound check is unsafe.
        case .double(let d) where d.isFinite: return Int(exactly: d.rounded(.towardZero))
        default: return nil
        }
    }

    static func handWaitMilliseconds(seconds: Double?) -> Int {
        let finiteSeconds = seconds.flatMap { $0.isFinite ? $0 : nil } ?? 0.6
        // Clamp while still floating point, before multiplication or Int
        // conversion can overflow. The existing hand range stays 0...10s.
        return Int(max(0, min(finiteSeconds, 10)) * 1000)
    }

    static func handDragMilliseconds(seconds: Double?) -> Int {
        guard let seconds, seconds.isFinite, seconds > 0 else { return 240 }
        return Int(max(0.08, min(seconds, 2)) * 1000)
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
        // SECURE KEYBOARD ENTRY (sweep item 8). The sink is available and
        // `CGEvent.post` will report nothing wrong — the window server just
        // never delivers synthesized keys while secure input is on, so every
        // character below would vanish and the receipt would say `typed`.
        // Preflighted once, before a single event, and refused in words.
        if let refusal = MacActClosedLoop.secureInputRefusal(
            active: eventSink.secureKeyboardEntryActive
        ) {
            return injectionRefusal(
                action: "keystroke",
                error: refusal.reason,
                extra: ["note": .string(refusal.note), "key_events": .int(0)]
            )
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
        // ax_act resolves against the FRONTMOST app; when that is ourselves
        // the act source's own fence would refuse as path-not-found, but the
        // reason belongs in the payload — same vocabulary as the read tools.
        if accessibilitySource.frontmostApp()?.processIdentifier == getpid() {
            return injectionRefusal(
                action: "ax_act",
                error: Self.selfInspectionError,
                status: 409,
                extra: ["guidance": .string(Self.selfInspectionNote)]
            )
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

    // MARK: act — the CLOSED LOOP (native-look item 3)

    /// The physical tier behind the model-facing `act`. The caller already
    /// resolved a fresh named/ordinal target; this owner validates a bounded
    /// gesture, plans it through `MacHandRepertoire`, and posts the balanced
    /// sequence through the same gated event sink as click/keystroke/scroll.
    private func handleHand(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        if let refusal = injectionPreconditions(action: "hand", requiresSink: true) { return refusal }
        if let refusal = await attentionActionRefusal(action: "hand", body: body) { return refusal }
        guard let gesture = body.stringValue("gesture")?.lowercased(), !gesture.isEmpty else {
            return injectionRefusal(action: "hand", error: "missing required field: gesture", status: 400)
        }
        let button: MacHandButton
        if body["button"] != nil {
            guard let raw = body.stringValue("button")?.lowercased(),
                  let parsed = MacHandButton(rawValue: raw), parsed != .middle,
                  ["click", "double_click", "hold", "drag"].contains(gesture) else {
                return injectionRefusal(action: "hand", error: "invalid mouse button for gesture", status: 400)
            }
            button = parsed
        } else {
            button = .left
        }

        func point(_ xKey: String = "x", _ yKey: String = "y") -> CGPoint? {
            guard let x = Self.doubleValue(body, xKey), let y = Self.doubleValue(body, yKey),
                  x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else { return nil }
            return CGPoint(x: x, y: y)
        }
        let waitMs = Self.handWaitMilliseconds(seconds: Self.doubleValue(body, "seconds"))
        var dragTravelMs: Int?
        var plan: [MacHandStep]
        do {
            switch gesture {
            case "click", "double_click", "click_type":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "gesture needs finite x/y", status: 400)
                }
                let count = gesture == "double_click" ? 2 : 1
                var steps = try MacHandRepertoire.click(button: button, at: at, count: count)
                if gesture == "click_type" {
                    guard let text = body.stringValue("text"), !text.isEmpty else {
                        return injectionRefusal(action: "hand", error: "click_type needs text", status: 400)
                    }
                    _ = try MacKeySyntax.validateText(text)
                    steps += MacHandRepertoire.type(text: text)
                }
                plan = steps
            case "hover":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "hover needs finite x/y", status: 400)
                }
                plan = MacHandRepertoire.hover(at: at, dwellMs: waitMs)
            case "move":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "move needs finite x/y", status: 400)
                }
                plan = MacHandRepertoire.move(to: at)
            case "hold":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "hold needs finite x/y", status: 400)
                }
                plan = try MacHandRepertoire.pressAndHold(button: button, at: at, holdMs: waitMs)
            case "drag":
                guard let start = point(), let end = point("to_x", "to_y") else {
                    return injectionRefusal(action: "hand", error: "drag needs finite x/y and to_x/to_y", status: 400)
                }
                // Named four-verb drags publish travel_seconds. Preserve the
                // legacy low-level seconds-as-endpoint-dwell contract otherwise.
                if body["travel_seconds"] != nil {
                    dragTravelMs = Self.handDragMilliseconds(seconds: Self.doubleValue(body, "travel_seconds"))
                }
                plan = try MacHandRepertoire.drag(
                    button: button,
                    from: start,
                    to: end,
                    steps: dragTravelMs.map { max(4, min(60, $0 / 16)) } ?? 18,
                    holdMs: dragTravelMs == nil ? min(waitMs, 1_500) : 0,
                    travelMs: dragTravelMs ?? 0
                )
            case "scroll":
                guard let at = point() else {
                    return injectionRefusal(action: "hand", error: "scroll needs finite x/y", status: 400)
                }
                let dy = max(-120, min(Self.intValue(body, "dy") ?? -6, 120))
                let dx = max(-120, min(Self.intValue(body, "dx") ?? 0, 120))
                plan = MacHandRepertoire.move(to: at)
                    + MacHandRepertoire.scroll(dx: Int32(dx), dy: Int32(dy), unit: .line)
            case "key":
                guard let keys = body.stringValue("keys") else {
                    return injectionRefusal(action: "hand", error: "key needs keys", status: 400)
                }
                plan = try MacKeySyntax.parseChords(keys).flatMap(MacHandRepertoire.chord)
            case "hold_key":
                guard let keys = body.stringValue("keys") else {
                    return injectionRefusal(action: "hand", error: "hold_key needs a held key set", status: 400)
                }
                let held = try MacKeySyntax.parseHeldKeys(keys)
                plan = try MacHandRepertoire.hold(
                    modifiers: held.modifiers,
                    keys: held.keys
                ) { [.wait(milliseconds: waitMs)] }
            default:
                return injectionRefusal(
                    action: "hand",
                    error: "unknown gesture: \(gesture)",
                    status: 400
                )
            }

            if let rawHolding = body.stringValue("holding")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !rawHolding.isEmpty {
                // Pointer hold + held keys is one balanced coordinated gesture.
                // Only nesting a second KEY hold conflicts with the outer set.
                guard gesture != "hold_key" else {
                    return injectionRefusal(
                        action: "hand",
                        error: "holding cannot wrap another keyboard hold gesture",
                        status: 400
                    )
                }
                let held = try MacKeySyntax.parseHeldKeys(rawHolding)
                let inner = plan
                plan = try MacHandRepertoire.hold(modifiers: held.modifiers, keys: held.keys) { inner }
            }
        } catch {
            return injectionRefusal(action: "hand", error: "invalid gesture: \(error)", status: 400)
        }

        guard !plan.isEmpty, MacHandRepertoire.isBalanced(plan) else {
            return injectionRefusal(action: "hand", error: "gesture plan was empty or unbalanced", status: 400)
        }

        // A composed four-verb physical act may own both fresh observations.
        // In that lane this hand reports emission only, never verification;
        // all injection/attention/cancellation gates below remain unchanged.
        let defersVisualVerification = body["defer_visual_verification"] == .bool(true)
        // Capture evidence inside the same canonical operation. Browser scroll
        // and Page Down often change pixels while the accessibility document
        // remains structurally identical, so the fused image participates in
        // the comparison instead of relying on AX notifications alone.
        func visibleEvidence(_ result: MacControlResult) -> [String: JSONValue]? {
            guard result.ok, case .object(let output) = result.output else { return nil }
            return [
                "app": output["app"] ?? .null,
                "window_title": output["window_title"] ?? .null,
                "marks": output["marks"] ?? .null,
                "text": output["text"] ?? .null,
                "image": output["image"] ?? .null,
            ]
        }
        var heldKeys: [UInt16] = []
        var heldButtons: [MacMouseButton] = []
        var lastPoint = CGPoint.zero
        var emittedEvents = 0
        @discardableResult func recoverNeutral() -> Int {
            let released = heldKeys.count + heldButtons.count
            for key in heldKeys.reversed() {
                eventSink.post(key: MacKeyEvent(keyCode: key, down: false))
            }
            for button in heldButtons.reversed() {
                eventSink.post(mouse: MacMouseEvent(
                    phase: .up, button: button, x: lastPoint.x, y: lastPoint.y
                ))
            }
            heldKeys.removeAll()
            heldButtons.removeAll()
            return released
        }
        func interruptedResult() -> MacControlResult {
            let recoveryEvents = recoverNeutral()
            return MacControlResult(
                ok: false,
                action: "hand",
                output: .object([
                    "status": .string("interrupted"),
                    "gesture": .string(gesture),
                    "steps": .int(Int64(plan.count)),
                    "requested_events_emitted": .int(Int64(emittedEvents)),
                    "recovery_events_emitted": .int(Int64(recoveryEvents)),
                    "effects_may_have_occurred": .bool(emittedEvents > 0),
                    "verified": .bool(false),
                    "hand_neutral": .bool(heldKeys.isEmpty && heldButtons.isEmpty),
                    "guidance": .string("Cancellation stopped further input. Already emitted input was not undone; observe the current screen before any further action."),
                ]),
                error: "gesture_cancelled",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true,
                verification: .unverified
            )
        }
        if Task.isCancelled { return interruptedResult() }

        // A targeted wheel gesture first moves the pointer into the named
        // region. That hover can change pixels by itself; it is positioning,
        // not proof that the subsequent scroll moved anything. Establish the
        // evidence baseline only after that leading move so a hover highlight
        // can never turn an inert scroll into a verified one.
        var executionPlan = plan
        if gesture == "scroll", case .mouse(let event)? = executionPlan.first {
            if let refusal = await attentionActionRefusal(action: "hand", body: body) {
                return refusal
            }
            if Task.isCancelled { return interruptedResult() }
            lastPoint = CGPoint(x: event.x, y: event.y)
            eventSink.post(mouse: event)
            emittedEvents += 1
            executionPlan.removeFirst()
        }

        if Task.isCancelled { return interruptedResult() }

        let beforeView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ]))

        for step in executionPlan {
            if Task.isCancelled { return interruptedResult() }
            if let refusal = await attentionActionRefusal(action: "hand", body: body) {
                recoverNeutral()
                return refusal
            }
            if Task.isCancelled { return interruptedResult() }
            switch step {
            case .key(let event):
                eventSink.post(key: event)
                emittedEvents += 1
                if event.down { heldKeys.append(event.keyCode) }
                else { heldKeys.removeAll { $0 == event.keyCode } }
            case .mouse(let event):
                lastPoint = CGPoint(x: event.x, y: event.y)
                eventSink.post(mouse: event)
                emittedEvents += 1
                if event.phase == .down { heldButtons.append(event.button) }
                else if event.phase == .up { heldButtons.removeAll { $0 == event.button } }
            case .scroll(let event):
                eventSink.post(scroll: event)
                emittedEvents += 1
            case .wait(let milliseconds):
                if milliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                }
            }
        }

        if Task.isCancelled { return interruptedResult() }

        let afterView = defersVisualVerification ? nil : visibleEvidence(await handleView([
            "max_marks": .int(60),
            "max_text_items": .int(80),
        ]))
        if Task.isCancelled { return interruptedResult() }
        let visibleChanged = beforeView != nil && afterView != nil && beforeView != afterView

        return MacControlResult(
            ok: true,
            action: "hand",
            output: .object([
                "status": .string(visibleChanged ? "emitted_observed" : "emitted_unobserved"),
                "gesture": .string(gesture),
                "steps": .int(Int64(plan.count)),
                "visible_changed": .bool(visibleChanged),
                "verified": .bool(visibleChanged),
                "visual_verification_deferred": .bool(defersVisualVerification),
                "drag_travel_ms": dragTravelMs.map { .int(Int64($0)) } ?? .null,
                "holding": body["holding"] ?? .null,
                "button": body["button"] ?? .null,
                "hand_neutral": .bool(heldKeys.isEmpty && heldButtons.isEmpty),
                "verification_evidence": visibleChanged
                    ? .string("fresh_fused_view_change")
                    : .null,
            ]),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// What one verb's mechanism did, before the effect is measured.
    private struct MacActPerformed {
        var ok: Bool
        /// `ax_action` | `ax_set_value` | `cgevent_click_fallback` |
        /// `keystroke_injection` | `cgevent_scroll_fallback` | `none`
        var method: String
        var requestedAction: String
        var fallbackReason: String?
        var error: String?
        /// The element the verb actually acted ON. For `dismiss` this is the
        /// modal's button, not the handle she named.
        var target: MacAXActTarget
        var postState: MacAXActTarget?
        var actedHandle: String
        var extra: [String: JSONValue] = [:]
    }

    /// `act` — perceive-act-verify in ONE call.
    ///
    /// The whole point of native-look item 3: today a computer-use step costs
    /// three model turns (look, act, look again) and only the middle one is a
    /// decision. This installs an AXObserver on the target app BEFORE it acts,
    /// performs the verb, waits for the first notification plus an 80 ms quiet
    /// window, re-compiles the look percept and DIFFS it against the frame she
    /// acted from — and returns what changed, plus a NEW frame, in the same
    /// result. The model never has to look again to learn whether it landed.
    ///
    /// GATES: identical to `ax_act`. It is in
    /// `macControlAccessibilityInjectionActions`, so `dispatchCore` demands a
    /// body-bound single-use `MacInjectionCapability`; `gatePreflightOutcome`
    /// demands the accessibility category and an ACTIVE Full Mac window; and
    /// `injectionPreconditions` demands the macOS TCC grant. A handle grants NO
    /// authority — it only names a better target for an act that already
    /// cleared every one of those.
    private func handleAct(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        // 1. THE REQUEST. Every malformed field is refused, never defaulted:
        //    an act aimed at a guessed target is the failure this whole tool
        //    exists to prevent.
        guard let rawVerb = body.stringValue("verb")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVerb.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: verb (one of \(MacActVerb.allCases.map(\.rawValue).joined(separator: ", ")))",
                status: 400
            )
        }
        guard let verb = MacActVerb(rawValue: rawVerb.lowercased()) else {
            return injectionRefusal(
                action: "act",
                error: "unknown_verb: \(rawVerb) is not one of "
                    + MacActVerb.allCases.map(\.rawValue).joined(separator: ", "),
                status: 400
            )
        }
        guard let handle = body.stringValue("handle")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: handle (from the latest mac_look)",
                status: 400
            )
        }
        guard let frameId = body.stringValue("frame_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !frameId.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "missing required field: frame_id (the frame_id mac_look returned with that handle)",
                status: 400
            )
        }
        let text = body.stringValue("text")
        if verb == .type, (text ?? "").isEmpty {
            return injectionRefusal(
                action: "act",
                error: "missing required field: text (verb \"type\" needs the characters to type)",
                status: 400
            )
        }
        let direction: MacActScrollDirection = {
            guard let raw = body.stringValue("direction")?.lowercased() else { return .down }
            return MacActScrollDirection(rawValue: raw) ?? .down
        }()
        if verb == .scroll, let raw = body.stringValue("direction")?.lowercased(),
           MacActScrollDirection(rawValue: raw) == nil {
            return injectionRefusal(
                action: "act",
                error: "unknown_direction: \(raw) — direction must be up or down",
                status: 400
            )
        }
        let waitMs = MacActClosedLoop.clampedWaitMs(Self.intValue(body, "wait_ms"))

        // 2. HANDLE → PATH, through the frame store and its own failure
        //    vocabulary. Each failure names what to do next, because "that
        //    didn't work" with no reason is what sends a model into a retry
        //    loop against a screen that has moved on.
        let resolved = await lookFrameStore.resolve(handle: handle, frameId: frameId, now: started)
        let entry: MacLookFrameEntry
        switch resolved {
        case .failure(let failure):
            return injectionRefusal(
                action: "act",
                error: failure.rawValue,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "frame_id": .string(frameId),
                    "guidance": .string(failure.guidance),
                ]
            )
        case .success(let hit):
            entry = hit
        }
        guard let frame = await lookFrameStore.frame(frameId: frameId) else {
            return injectionRefusal(
                action: "act",
                error: MacLookFrameStore.ResolveFailure.noFrame.rawValue,
                status: 409,
                extra: ["guidance": .string(MacLookFrameStore.ResolveFailure.noFrame.guidance)]
            )
        }

        // 3. THE SAME GATES `ax_act` clears. The TCC grant, then the human's
        //    physical priority.
        if let refusal = injectionPreconditions(action: "act", requiresSink: false) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "act", body: body) {
            return refusal
        }

        // 4. LIVE RESOLVE — through the ACTUATOR's resolver, never a second
        //    one, and ANCHORED TO THE FRAME'S PID (gpt-5.5 round-2 B2).
        //
        //    The old resolve walked `NSWorkspace.frontmostApplication` while the
        //    effect observer went on the FRAME's pid: if anything stole front
        //    between the look and the act, the same path/role/label could name a
        //    plausible control in the WRONG app and the verb fired there, with
        //    an observer watching an app that never moved. The pid she looked at
        //    is the only app this may touch.
        guard let framePid = frame.pid else {
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "reason": .string("frame_recorded_no_pid"),
                    "guidance": .string(
                        "this frame recorded no process id, so the act cannot be anchored to the app "
                        + "you looked at — call mac_look again"
                    ),
                ]
            )
        }
        // 4a½. A frame that names OUR OWN process (only possible from a store
        //      populated before the self-inspection fence shipped) must refuse
        //      BEFORE `windows(pid:)` or any other actuator call starts an AX
        //      transaction against ourselves — see `MacAnchoredRead.selfProcess`.
        if framePid == getpid() {
            await lookFrameStore.invalidate()
            return injectionRefusal(
                action: "act",
                error: Self.selfInspectionError,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "reason": .string("cannot_act_on_own_process"),
                    "guidance": .string(
                        "this frame points at NativeAgent's own window, which AX must never touch — "
                        + "the frame is discarded; call mac_look at another app's window"
                    ),
                ]
            )
        }
        // 4b. …AND TO THE FRAME'S WINDOW (gpt-5.5 round-3 B1).
        //
        //     The pid anchor was necessary and not sufficient: inside the right
        //     app the resolve still took "focused, else main, else first", so
        //     two windows of one app plus a focus change between the look and
        //     the act put the verb in the WRONG window while every pid check
        //     passed. The window she looked at is matched by an identity that
        //     outlives the element handle — pid + role/subrole + title + rect +
        //     window index — and no match, or an ambiguous one, REFUSES.
        let actWindows = accessibilityActSource.windows(pid: framePid)
        guard !actWindows.isEmpty else {
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "reason": .string("app_publishes_no_window"),
                    "guidance": .string(
                        "the app this frame was captured from publishes no window any more — nothing "
                        + "was acted on; call mac_look again"
                    ),
                ]
            )
        }
        let actWindow: MacAXWindowRef
        if let recorded = frame.windowIdentity {
            switch MacAXWindowIdentity.match(
                recorded,
                among: actWindows.map { (handle: $0, identity: $0.identity) }
            ) {
            case .matched(let hit, _):
                actWindow = hit
            case .gone:
                return injectionRefusal(
                    action: "act",
                    error: "frame_window_gone",
                    status: 409,
                    extra: [
                        "handle": .string(handle),
                        "pid": .int(Int64(framePid)),
                        "window": recorded.toJSON(),
                        "windows_now": .int(Int64(actWindows.count)),
                        "guidance": .string(
                            "the window you looked at is not there any more (it closed, or the app "
                            + "replaced it) — NOTHING was acted on; call mac_look at whatever is up now"
                        ),
                    ]
                )
            case .ambiguous(let reason):
                return injectionRefusal(
                    action: "act",
                    error: "window_drifted",
                    status: 409,
                    extra: [
                        "handle": .string(handle),
                        "pid": .int(Int64(framePid)),
                        "drifted_on": .string(reason),
                        "window": recorded.toJSON(),
                        "windows_now": .int(Int64(actWindows.count)),
                        "guidance": .string(
                            "this app now has more than one window that could be the one you looked at, "
                            + "and acting on the wrong one is not recoverable — NOTHING was acted on; "
                            + "call mac_look to re-anchor"
                        ),
                    ]
                )
            }
        } else {
            // A frame recorded before the window anchor existed, or by a source
            // that cannot name a window. The pid anchor still holds and the act
            // proceeds; it is not silently claimed to be window-anchored.
            actWindow = actWindows[0]
        }

        let target: MacAXActTarget
        switch accessibilityActSource.resolve(path: entry.path, inWindow: actWindow) {
        case .resolved(let hit):
            target = hit
        case .windowGone:
            return injectionRefusal(
                action: "act",
                error: "frame_window_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string(
                        "the window you looked at went away between matching it and resolving that "
                        + "handle — NOTHING was acted on; call mac_look again"
                    ),
                ]
            )
        case .windowDrifted(let reason):
            return injectionRefusal(
                action: "act",
                error: "window_drifted",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "drifted_on": .string(reason),
                    "guidance": .string(
                        "that app's windows can no longer be told apart — NOTHING was acted on; call "
                        + "mac_look to re-anchor"
                    ),
                ]
            )
        case .appGone:
            return injectionRefusal(
                action: "act",
                error: "frame_app_gone",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "app": frame.appName.map { .string($0) } ?? .null,
                    "guidance": .string(
                        "the app this frame was captured from is no longer running (or publishes no "
                        + "window any more) — nothing was acted on; call mac_look again"
                    ),
                ]
            )
        case .pathNotFound:
            return injectionRefusal(
                action: "act",
                error: MacAccessibilityActuator.Failure.pathNotFound.rawValue,
                status: 404,
                extra: [
                    "handle": .string(handle),
                    "path": .array(entry.path.map { .int(Int64($0)) }),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string("the element that handle named is gone — call mac_look again"),
                ]
            )
        }

        // 5. THE DRIFT GUARD. Between the look and the act the app may have
        //    rebuilt the window, and a child-index path would then address a
        //    DIFFERENT control. Pressing it would be "press Save" pressing
        //    "Delete". Never act on something she did not name.
        if let reason = MacActClosedLoop.driftReason(
            expectedRole: entry.role,
            expectedLabel: entry.label,
            liveRole: target.role,
            liveTitle: target.title,
            liveValue: target.value
        ) {
            return injectionRefusal(
                action: "act",
                error: "handle_drifted",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "drifted_on": .string(reason),
                    "expected": .object([
                        "role": .string(entry.role),
                        "label": entry.label.map {
                            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
                        } ?? .null,
                    ]),
                    "found": .object([
                        "role": .string(target.role),
                        "label": (target.title ?? target.value).map {
                            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
                        } ?? .null,
                    ]),
                    "guidance": .string(
                        "that handle no longer names the control it did — the window changed; call mac_look again"
                    ),
                ]
            )
        }

        // 5b. THE IDENTITY RE-CHECK (gpt-5.5 round-2 B3 / Agent #3b).
        //
        //     Role+label alone passes the worst realistic drift: two buttons
        //     both labeled "Send", the one above disappears, and the handle she
        //     named now addresses the OTHER one — same role, same label, wrong
        //     control. So the live window is RE-COMPILED through the same
        //     walker and the same compiler the look used, and the element at
        //     her path must still render the SAME handle. For a handle that was
        //     position-derived to begin with (`ambiguous`), the rendered handle
        //     is by construction unable to tell the siblings apart, so the
        //     recorded frame RECT must match too.
        let identityLimits = Self.axLimits(from: body)
        // B1 — re-read the FRAME'S WINDOW, not the app's focused one. Comparing
        // the handle against a walk of the app's other window is a drift check
        // that verifies the wrong tree: it either passes by luck or refuses
        // every act while the real target sits there untouched.
        let identityAnchor = anchoredSnapshot(
            limits: identityLimits,
            pid: framePid,
            window: frame.windowIdentity
        )
        let identityRead: MacAXRead
        switch identityAnchor {
        case .read(let hit):
            identityRead = hit
        case .appGone, .windowGone, .windowDrifted, .selfProcess:
            // Nothing to verify against and nothing to act on: the frame is
            // dead, so it must stop resolving handles as well.
            await lookFrameStore.invalidate()
            let (error, reason): (String, String) = {
                switch identityAnchor {
                case .windowGone: return ("frame_window_gone", "window_gone_before_verify")
                case .windowDrifted(let why): return ("window_drifted", why)
                case .selfProcess: return (Self.selfInspectionError, "cannot_act_on_own_process")
                default: return ("frame_app_gone", "no_window_to_verify_against")
                }
            }()
            return injectionRefusal(
                action: "act",
                error: error,
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "reason": .string(reason),
                    "guidance": .string(
                        "there is no window to re-check that handle against — NOTHING was acted on; "
                        + "call mac_look again"
                    ),
                ]
            )
        }
        // The SAME scoping the look ran under, or a page handle would be
        // compared against a window walk that never reaches the page and every
        // act on a web control would refuse as drift.
        let identityScoped = pageScoped(
            identityRead,
            limits: identityLimits,
            scope: MacLookScope.parse(body.stringValue("scope")) ?? .page
        ).read
        let identityPercept = MacPerceptionCompiler.compile(
            snapshot: identityScoped.snapshot,
            app: identityScoped.app,
            windowTitle: identityScoped.rootTitle,
            focusPath: identityScoped.focusPath,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances
        )
        // The live element is looked up in the SAME channels the frame entry
        // could have been minted from — affordances at that path, else the
        // recompiled FOCUS when the focus sits there. An unlabeled focused
        // control (Notes' empty note body) is never an affordance, so an
        // affordance-only lookup refused every act on it as `element_absent`.
        if let drift = MacActClosedLoop.identityDrift(
            entry: entry,
            live: MacActClosedLoop.liveIdentity(entry: entry, percept: identityPercept)
        ) {
            return injectionRefusal(
                action: "act",
                error: "handle_drifted",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "drifted_on": .string(drift.on),
                    "expected": .object([
                        "role": .string(entry.role),
                        "handle": .string(entry.handle),
                        "label": entry.labelJSON ?? entry.label.map {
                            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
                        } ?? .null,
                    ]),
                    "found": drift.found,
                    "guidance": .string(
                        "the control at that position is no longer the one that handle named — the "
                        + "window changed under you; call mac_look again"
                    ),
                ]
            )
        }

        // 6. ARM THE OBSERVER *BEFORE* ACTING. A loop that installs after the
        //    act races the effect and loses on a fast app (the spike measured
        //    30 ms). The guard removes it on EVERY exit — success, error,
        //    timeout, or an unwinding cancellation.
        //
        //    NO OBSERVER, NO ACT (gpt-5.5 round-2 B2). The closed loop's whole
        //    promise is that she never has to re-look to learn whether the act
        //    landed; firing a verb with nothing watching the app is a blind
        //    press wearing the loop's costume. `none_observed` (the app fired
        //    nothing) stays a real, reported outcome — this is the different
        //    case where the subscription itself could not be made.
        // 6b. THE KEY-WINDOW GATE (Agent round 7, envelope 173E1B08).
        //
        //     Every anchor up to here constrains where we READ and where we
        //     perform AX ACTIONS. None of them constrains a CGEvent: the window
        //     server delivers synthesized input to whatever is KEY. With Chrome
        //     frontmost and a Finder frame, `open`'s select-then-⌘↓ posted the
        //     chord into Chrome and the envelope still said `acted`.
        //
        //     Computed HERE (one pair of AX reads, before anything is performed)
        //     and handed to `performAct`, which consults it at each site that
        //     would synthesize input — and ONLY there. A verb that carries out
        //     through pure AX (`AXPress`, `AXSetValue`) targets its element
        //     directly, steals no focus and reaches no other app, and acting on
        //     a background window that way is an established capability with a
        //     test behind it (`pidAnchoredRead_neverReportsTheFrontmostAppsIdentity`).
        //     Gating those too would have traded a real bug for a real
        //     regression.
        let focusedWindowNow = accessibilityActSource.focusedWindow(pid: framePid)
        let inputRefusal = MacActClosedLoop.keyWindowRefusal(
            framePid: framePid,
            frontmostPid: accessibilitySource.frontmostApp()?.processIdentifier,
            frontmostName: accessibilitySource.frontmostApp()?.name,
            // `actWindow` is the window this frame was already matched to, so
            // the key question is plain handle equality against the focused one
            // — and since round 9 the live source mints ONE handle per element,
            // so that equality answers about the window rather than about two
            // counter values (`SystemMacAXActSource.mint`).
            frameWindowHandle: actWindow.handle,
            focusedWindowHandle: focusedWindowNow?.handle,
            frameWindowTitle: actWindow.identity.title,
            focusedWindowTitle: focusedWindowNow?.identity.title,
            appWindowCount: focusedWindowNow == nil ? actWindows.count : nil
        )

        let collector = MacAXEffectCollector()
        let observerGuard = MacAXEffectObserverGuard(
            effectObserverSource.install(
                pid: framePid,
                kinds: MacActClosedLoop.notificationKinds,
                onNotification: { [collector] notification in collector.record(notification) }
            )
        )
        defer { observerGuard.stop() }
        let observerInstalled = observerGuard.isInstalled
        guard observerInstalled else {
            return injectionRefusal(
                action: "act",
                error: "observer_unavailable",
                status: 409,
                extra: [
                    "handle": .string(handle),
                    "pid": .int(Int64(framePid)),
                    "guidance": .string(
                        "no accessibility notification could be subscribed on that app, so the effect "
                        + "of this act could not be observed — NOTHING WAS ACTED ON. Check that the app "
                        + "is still running and try mac_look again."
                    ),
                ]
            )
        }

        // 7. PERFORM.
        let performedAt = now()
        let performed = performAct(
            verb: verb,
            handle: handle,
            entry: entry,
            frame: frame,
            framePid: framePid,
            actWindow: actWindow,
            target: target,
            text: text,
            direction: direction,
            inputRefusal: inputRefusal
        )
        await screenViewStore.invalidate()

        guard let performed else {
            // Only reachable for a verb whose mechanism does not exist on this
            // element — reported by name, never as a silent no-op.
            return injectionRefusal(
                action: "act",
                error: verb == .dismiss ? "no_dismiss_target" : "verb_not_supported_on_element",
                status: 409,
                extra: [
                    "verb": .string(verb.rawValue),
                    "handle": .string(handle),
                    "element": .object([
                        "role": .string(target.role),
                        "actions": .array(target.actions.map { .string($0) }),
                    ]),
                    "guidance": .string(
                        verb == .dismiss
                            ? "no modal with a Cancel/Close/Dismiss/Done/OK button in this frame, and the "
                                + "element advertises no AXCancel — look again, or act on a specific handle"
                            : "this element exposes no mechanism for that verb"
                    ),
                ]
            )
        }

        // 8. WAIT FOR THE EFFECT. Nothing arriving inside wait_ms is a REAL
        //    outcome, not a failure: it means this app published no
        //    notification, which the caller needs to know.
        let clock = now
        // A NAVIGATION verb is watched until the surface actually transitions,
        // not until the first notification of any kind (Agent round 7, envelope
        // 4E998341: the selection fired in milliseconds, the loop stopped
        // watching, and Finder's retitle — the signal `navigated` is DEFINED by
        // — arrived after the recompile had already read the old title). An
        // explicit `wait_ms` from the caller still wins; this only raises the
        // DEFAULT, and it is a deadline, not a sleep.
        let navigationVerb = MacActClosedLoop.navigationVerbs.contains(verb)
        let effectWaitMs = navigationVerb && Self.intValue(body, "wait_ms") == nil
            ? MacActClosedLoop.clampedWaitMs(MacActClosedLoop.navigationWaitMs)
            : waitMs
        let wait = await MacActClosedLoop.waitForEffect(
            collector: collector,
            waitMs: effectWaitMs,
            startedAt: performedAt,
            clock: { clock() },
            until: navigationVerb ? MacActClosedLoop.navigationNotificationKinds : []
        )
        observerGuard.stop()

        // 9. RE-COMPILE the same look percept and DIFF it against the frame.
        let limits = Self.axLimits(from: body)
        // B2 — the post-act read is of the FRAME'S WINDOW, never of whatever is
        // frontmost by now. The act itself was already pid+window anchored; a
        // frontmost re-read would then describe another app's window as "what
        // changed" AND store it as the new frame, so the next verb would act
        // from a description of something she never looked at.
        let (read, seam, postAnchor) = await lookSnapshot(
            limits: limits,
            scope: MacLookScope.parse(body.stringValue("scope")) ?? .page,
            anchorPid: framePid,
            anchorWindow: frame.windowIdentity
        )
        let redactValue = verb == .type
                // Did `open` land on an ancestor of the handle she named? `acted_on`
        // is set by performAct only for the open verb, and only it knows.
        let actRedirected: Bool = {
            guard case .object(let actedOn)? = performed.extra["acted_on"],
                  case .bool(true)? = actedOn["redirected"] else { return false }
            return true
        }()
var effect: [String: JSONValue] = [
            "observed": .bool(wait.observed),
            "observer_installed": .bool(observerInstalled),
            "wait_ms": .int(Int64(waitMs)),
            "notifications": .array(wait.notifications.map { .string($0) }),
            "notification_count": .int(Int64(wait.notificationCount)),
            "acted_element": .object([
                "handle": .string(performed.actedHandle),
                // REDIRECT-AWARE (gpt-5.5 round-5 review). `open` can act on an
                // ANCESTOR of the handle, and then the frame entry's label and
                // value belong to a DIFFERENT element than the one described
                // here — "handle = filename cell, before = row" was readable as
                // the row being named `.agents`. When the act was redirected the
                // entry's label/value are withheld and the element speaks for
                // itself; `acted_on` carries the redirect, and the redaction
                // verdict stays the conservative one either way.
                "before": Self.actedElementJSON(
                    performed.target,
                    redactingValue: redactValue || (actRedirected && entry.secret),
                    labelJSON: actRedirected ? nil : entry.labelJSON,
                    valueJSON: actRedirected ? nil : entry.valueJSON
                ),
                // The post-act read carries NO compile context, so a value the
                // look hid would come back in the clear here. The frame's own
                // verdict decides: secret before ⇒ secret after, digest only.
                "after": performed.postState.map {
                    Self.actedElementJSON(
                        $0,
                        redactingValue: redactValue || entry.secret,
                        labelJSON: (entry.secret && !actRedirected) ? entry.labelJSON : nil
                    )
                } ?? .null,
            ]),
        ]
        if let firstMs = wait.firstNotificationMs {
            effect["first_notification_ms"] = .int(Int64(firstMs))
        }
        if wait.dropped > 0 { effect["notifications_dropped"] = .int(Int64(wait.dropped)) }
        // An observer that could not be installed never gets here: B2 refuses
        // the act outright rather than pressing with nothing watching. The only
        // remaining "no evidence" case is the honest one — the app fired
        // nothing inside wait_ms, which is itself an answer.
        if !wait.observed {
            effect["reason"] = .string("none_observed")
        }

        var output: [String: JSONValue] = [
            "ok": .bool(performed.ok),
            // Agent acceptance round 2, Finder `open` — the event WAS delivered
            // (AXOpen refused, the CGEvent double-click fallback ran) and the
            // app published nothing, the title did not move and the glance was
            // identical. Reporting that as `acted` calls an unobserved act a
            // success. `ok`/`performed` keep their meaning — the event went out;
            // the STATUS says whether anything was seen to happen. `verified`
            // stays false either way: observation is evidence, not settlement.
            // Round 4, Finder `open`: one AXRowCountChanged was enough to call
            // an act that navigated NOWHERE `acted`. The classifier below is
            // the single place that verdict is made; this seeds it with the
            // no-diff-yet answer (correct for the window-died early return
            // just past this point) and the post-diff recompute overrides it
            // once there is a percept to weigh.
            "status": .string(MacActClosedLoop.classify(
                performedOK: performed.ok,
                verb: verb,
                notificationObserved: wait.observed,
                diff: nil
            ).status),
            "verb": .string(verb.rawValue),
            "handle": .string(handle),
            "performed": .bool(performed.ok),
            "method": .string(performed.method),
            "requested_action": .string(performed.requestedAction),
            "path": .array(entry.path.map { .int(Int64($0)) }),
            "seam": .object(seam),
            // The closed loop OBSERVES; it does not claim the intended
            // consequence happened. `effect.observed` is the evidence, and it
            // is the caller's to judge — same honesty line `ax_act` holds.
            "verified": .bool(false),
            "value_redacted": .bool(redactValue),
        ]
        output["fallback_reason"] = performed.fallbackReason.map { .string($0) } ?? .null
        // Agent acceptance round 1, finding B — the act is NOT refused for an
        // ordinal handle (that would make Finder unusable), but a caller must be
        // able to see that it acted on a POSITION rather than on an identity.
        if entry.ambiguous {
            output["handle_ambiguous"] = .bool(true)
            output["handle_ambiguity"] = .string(
                "that handle was a position-derived ordinal among identical elements — it names "
                + "whatever now sits at that position; re-look if the container may have reordered"
            )
        }
        for (key, value) in performed.extra { output[key] = value }
        if let error = performed.error { output["error"] = .string(error) }

        guard let read else {
            // The window went away under the act (she closed it, or dismissed
            // the last sheet, or the act itself closed it). That is a real
            // outcome and the frame must die with it — a handle from a window
            // that no longer exists must never resolve.
            //
            // B2 — and it is NAMED. "no_frontmost_window" was the only answer
            // when the post-act read was frontmost-anchored; an anchored read
            // can distinguish the app exiting from the window closing from two
            // windows now being indistinguishable, and the caller acts
            // differently on each.
            await lookFrameStore.invalidate()
            let (percept, note): (String, String) = {
                switch postAnchor {
                case .appGone?:
                    return (
                        "frame_app_gone",
                        "the act ran, but the app you looked at no longer publishes a window — the old "
                        + "frame is discarded; call mac_look when it is back"
                    )
                case .windowGone?:
                    return (
                        "frame_window_gone",
                        "the act ran, and the window you looked at is gone (it closed, or the act closed "
                        + "it) — the old frame is discarded; call mac_look at whatever is up now"
                    )
                case .windowDrifted(let reason)?:
                    return (
                        "window_drifted:\(reason)",
                        "the act ran, but that app now has more than one window that could be the one "
                        + "you looked at, so nothing was re-read — the old frame is discarded; call "
                        + "mac_look to re-anchor"
                    )
                case .selfProcess?:
                    return (
                        Self.selfInspectionError,
                        "the act ran, but the target now resolves to NativeAgent's own process, which "
                        + "AX must not re-read — the old frame is discarded; call mac_look at another "
                        + "app's window"
                    )
                case .read?, nil:
                    return (
                        "no_frontmost_window",
                        "the act ran, but there is no window to look at afterwards — the old frame is "
                        + "discarded; call mac_look when a window is up again"
                    )
                }
            }()
            effect["percept"] = .string(percept)
            output["effect"] = .object(effect)
            output["frame_id"] = .null
            output["frame_invalidated"] = .bool(true)
            output["glance"] = .null
            output["how_to_read"] = .string(note)
            return MacControlResult(
                ok: performed.ok,
                action: "act",
                output: .object(output),
                error: performed.error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }

        let after = MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            app: read.app,
            windowTitle: read.rootTitle,
            // Same read epoch as the post-act walk, anchored to its root.
            focusPath: read.focusPath,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances
        )
        // The bounds THIS compile ran under, so the diff can say whether its
        // added/removed census is comparable with the look's (Agent round 2:
        // 29 added / 1 removed was a capped recompile, not navigation).
        let afterCaps = MacLookCompileCaps(
            truncated: after.truncated,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances,
            maxNodes: limits.maxNodes,
            maxDepth: limits.maxDepth
        )
        let diff = MacActClosedLoop.diff(
            before: frame,
            after: after,
            afterWindowTitle: read.rootTitle,
            afterCaps: afterCaps
        )
        for (key, value) in Self.effectDiffJSON(diff, valueChars: limits.valueChars) {
            effect[key] = value
        }
        // THE VERDICT, now that there is evidence to weigh. A navigation verb
        // whose window did not move is `acted_unobserved` even though the app
        // published something — see `MacActClosedLoop.classify`.
        let classification = MacActClosedLoop.classify(
            performedOK: performed.ok,
            verb: verb,
            notificationObserved: wait.observed,
            diff: diff,
            // The label she NAMED — Finder retitles to the opened folder, so
            // this is what the destination is checked against.
            intendedTarget: entry.label,
            // VERB-SEMANTIC for `type`: the text we tried to land, the acted
            // element's value BEFORE (from the pre-act resolve — without it, a
            // pre-existing substring reads as a landed edit), and what the
            // field reads back after. Compared in memory only — none of these
            // are ever echoed into a payload, so a secret stays a secret.
            // A secure field reads back a MASK — a non-empty string that can
            // never contain the typed text — so comparing against it would
            // call a landed edit "not in field". The SAME breadth the look
            // lane uses to redact (role + label hints; subrole is not carried
            // on MacAXActTarget) gates it to the honest `edit_unverifiable`
            // branch instead.
            typedText: verb == .type ? body.stringValue("text") : nil,
            valueBefore: MacScreenViewBuilder.isSecretField(
                role: performed.target.role, subrole: nil, label: entry.label
            ) ? nil : performed.target.value,
            valueAfter: MacScreenViewBuilder.isSecretField(
                role: performed.target.role, subrole: nil, label: entry.label
            ) ? nil : performed.postState?.value
        )
        output["status"] = .string(classification.status)
        if let reason = classification.reason {
            output["status_reason"] = .string(reason)
            // Same value as the `none_observed` written above when nothing was
            // published, so this is a no-op there rather than a clobber. A
            // `failed` classification carries no reason and writes nothing —
            // an earlier `none_observed` on a failed act is still TRUE (the app
            // published nothing) and stays.
            effect["reason"] = .string(reason)
        }
        if let note = classification.note { output["status_note"] = .string(note) }
        // Agent round 2 — a Finder view switch dropped 222 notifications and
        // showed 10 of 44 additions. A truncated list of a bulk change is not a
        // description of it, so past the cap the payload also carries a
        // SEMANTIC summary: what appeared and vanished by role, and what the
        // focus is now inside.
        if diff.addedTotal > MacActClosedLoop.maxDiffRows || wait.dropped > 0 {
            effect["summary"] = Self.denseEffectSummaryJSON(
                diff: diff,
                after: after,
                snapshot: read.snapshot,
                valueChars: limits.valueChars
            )
        }
        output["effect"] = .object(effect)

        // 10. A NEW FRAME, so the next verb continues from the state the act
        //     produced instead of from a description of the screen before it.
        let capturedAt = now()
        let newFrameId = UUID().uuidString
        await lookFrameStore.record(MacLookFrame.from(
            percept: after,
            frameId: newFrameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            // The new frame is anchored to the window the ACT happened in —
            // the same window the read above was anchored to, re-read fresh so
            // a moved or retitled window carries its new identity forward.
            windowIdentity: read.windowIdentity ?? frame.windowIdentity,
            caps: afterCaps
        ))
        output["frame_id"] = .string(newFrameId)
        output["captured_at"] = .string(ISO8601DateFormatter().string(from: capturedAt))
        output["frame_ttl_seconds"] = .int(Int64(MacLookFrameStore.ttlSeconds))
        // The ACT's glance leads with the readout THIS act moved, not with the
        // top-ranked one (Agent round 2: Equals produced "42" and the glance
        // still opened with the expression "7×6", so she had to re-look for the
        // one number she pressed Equals to get). `mac_look`'s ranking is
        // untouched — a look has no act to describe.
        output["glance"] = .string(after.glanceLine(leading: Self.actedReadout(diff: diff, after: after)))
        output["how_to_read"] = .string(
            "`effect` is what changed: the notifications the app fired, the acted element before/after, "
            + "`readouts_changed` (the read-only values — a total, a display, a status line — that moved, "
            + "which is where the ANSWER to what you just did usually is), and "
            + "the affordances added/removed/changed by handle. `frame_id` is a FRESH frame compiled after "
            + "the act — keep acting on handles from it. Handles from the previous frame are dead. You do "
            + "NOT need to call mac_look to find out whether this landed."
        )

        return MacControlResult(
            ok: performed.ok,
            action: "act",
            output: .object(output),
            error: performed.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// The readout THIS act moved: the first one that CHANGED, else the first
    /// one it ADDED, else nil (nothing moved ⇒ the glance falls back to the
    /// ranked readout, which is the honest description of a screen the act did
    /// not change).
    ///
    /// Resolved back to the post-act percept's own `MacLookReadout` so the
    /// glance prints COMPILE-TIME-redacted text — a diff row's text re-rendered
    /// here would have no node context and could print what the look withheld.
    private static func actedReadout(
        diff: MacActClosedLoop.EffectDiff,
        after: MacLookPercept
    ) -> MacLookReadout? {
        func lookup(path: [Int], role: String) -> MacLookReadout? {
            after.readouts.first { $0.path == path && $0.role == role }
        }
        if let changed = diff.readoutsChanged.first,
           let readout = lookup(path: changed.path, role: changed.role) {
            return readout
        }
        if let added = diff.readoutsAdded.first,
           let readout = lookup(path: added.path, role: added.role) {
            return readout
        }
        return nil
    }

    /// Redacted before/after snapshot of the element the verb acted on.
    /// - Parameters:
    ///   - labelJSON/valueJSON: gpt-5.5 round-2 B4 — the text as a COMPILE saw
    ///     it, with the enclosing-caption context (the group titled "CVV" two
    ///     rows up) that a re-redaction of the stored string cannot recover.
    ///     `acted_element` is the third way a hidden value could leave, after
    ///     `changed` and `affordances_removed`.
    private static func actedElementJSON(
        _ target: MacAXActTarget,
        redactingValue: Bool,
        labelJSON: JSONValue? = nil,
        valueJSON: JSONValue? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["role": .string(target.role)]
        object["label"] = labelJSON ?? (target.title ?? target.value).map {
            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
        } ?? .null
        if redactingValue {
            object["value"] = target.value.map { MacInjectionResultRedaction.redactedSecret($0) } ?? .null
        } else if let valueJSON {
            object["value"] = valueJSON
        } else {
            object["value"] = target.value.map {
                MacScreenViewTextRedaction.redactedLegendString(
                    $0,
                    valueChars: MacAXLimits.hardValueChars,
                    under: target.title
                )
            } ?? .null
        }
        object["enabled"] = .bool(target.enabled)
        return .object(object)
    }

    /// Agent round 2 — the semantic summary of a BULK change.
    ///
    /// Alongside (never instead of) the capped lists: counts by role, so "44
    /// added" is legible as "40 AXRow, 3 AXButton, 1 AXImage", and the container
    /// the focus now sits in with its first children named, which is what
    /// "Finder switched to list view" actually looks like from the inside.
    private static func denseEffectSummaryJSON(
        diff: MacActClosedLoop.EffectDiff,
        after: MacLookPercept,
        snapshot: MacAXTreeSnapshot,
        valueChars: Int
    ) -> JSONValue {
        func census(_ byRole: [String: Int]) -> JSONValue {
            .object(byRole.mapValues { .int(Int64($0)) })
        }
        var summary: [String: JSONValue] = [
            "added_by_role": census(diff.addedByRole),
            "removed_by_role": census(diff.removedByRole),
        ]
        // gpt-5.5 round-3 B4 — the summary describes nodes the percept does not
        // carry as affordances (the focus container, its first children), and
        // it was redacting their RAW attributes with the standalone shape test
        // only. That test cannot see the group titled "CVV" two rows up, so a
        // child labeled with a card code sailed through `first_children` while
        // the affordance list correctly withheld it. This is the SAME
        // full-context pass the compile ran, over the same snapshot: the
        // summary can no longer disagree with the percept it summarizes.
        let redactedText = MacPerceptionCompiler.redactedNodeTextMap(snapshot)
        if let focusPath = after.focus?.path, !focusPath.isEmpty {
            let containerPath = Array(focusPath.dropLast())
            let children = snapshot.nodes.filter { $0.path.count == containerPath.count + 1
                && Array($0.path.dropLast()) == containerPath }
            let container = snapshot.nodes.first { $0.path == containerPath }
            var block: [String: JSONValue] = [
                "role": container.map { .string($0.attributes.role) } ?? .null,
                "child_count": .int(Int64(children.count)),
                "path": .array(containerPath.map { .int(Int64($0)) }),
            ]
            block["label"] = container?.attributes.title == nil
                ? .null
                : (redactedText[containerPath] ?? MacInjectionResultRedaction.redactedSecret(
                    container?.attributes.title ?? ""
                ))
            block["first_children"] = .array(
                children.prefix(10).map { child in
                    guard (child.attributes.title ?? child.attributes.value) != nil else {
                        return .string(child.attributes.role)
                    }
                    // Fail closed: a node the map has no verdict for is a node
                    // nothing judged in context, and the context-free second
                    // opinion is the hole itself.
                    return redactedText[child.path]
                        ?? MacInjectionResultRedaction.redactedSecret(
                            child.attributes.title ?? child.attributes.value ?? ""
                        )
                }
            )
            summary["new_focus_container"] = .object(block)
        }
        return .object(summary)
    }

    private static func effectDiffJSON(
        _ diff: MacActClosedLoop.EffectDiff,
        valueChars: Int
    ) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "affordances_added": .array(diff.added.map { $0.toJSON(valueChars: valueChars) }),
            "affordances_removed": .array(diff.removed.map { entry in
                .object([
                    "handle": .string(entry.handle),
                    "role": .string(entry.role),
                    // B4: the entry's COMPILE-TIME redaction, not a fresh
                    // context-free pass over the stored string.
                    "label": entry.labelJSON ?? entry.label.map {
                        MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                    } ?? .null,
                ])
            }),
            "changed": .array(diff.changed.map { $0.toJSON(valueChars: valueChars) }),
            "affordances_added_total": .int(Int64(diff.addedTotal)),
            "affordances_removed_total": .int(Int64(diff.removedTotal)),
            "changed_total": .int(Int64(diff.changedTotal)),
            "focus_changed": .bool(diff.focusChanged),
            // `window_changed` NAMES ITS EVIDENCE (Agent round 2). It is exactly
            // `!change_reasons.isEmpty`, so a true with nothing behind it cannot
            // be emitted.
            "window_changed": .bool(diff.windowChanged),
            "change_reasons": .array(diff.changeReasons.map { .string($0) }),
            // …and when the two compiles ran under different bounds, the
            // added/removed census is EXCLUDED from those reasons and the
            // payload says so rather than dropping it silently.
            "diff_comparable": .bool(diff.diffComparable),
            // Agent acceptance round 1, finding A — the READ-ONLY values that
            // moved. Pressing Equals changes no affordance label; without this
            // the answer she acted for was nowhere in the result.
            "readouts_changed": .array(diff.readoutsChanged.map { $0.toJSON(valueChars: valueChars) }),
            "readouts_changed_total": .int(Int64(diff.readoutsChangedTotal)),
            "readouts_added_total": .int(Int64(diff.readoutsAddedTotal)),
            "readouts_removed_total": .int(Int64(diff.readoutsRemovedTotal)),
            // The ROWS, not just the totals: `readouts_added_total: 2` does not
            // contain "42", and that number was the whole reason she acted.
            "readouts_added": .array(diff.readoutsAdded.map { $0.toJSON(valueChars: valueChars) }),
            "readouts_removed": .array(diff.readoutsRemoved.map { $0.toJSON(valueChars: valueChars) }),
        ]
        if let reason = diff.diffIncomparableReason {
            out["diff_incomparable_reason"] = .string(reason)
            out["diff_incomparable_note"] = .string(
                "the affordances added/removed census is NOT counted as evidence of change here — "
                + "the two compiles did not see the same window. The rows are still listed; the "
                + "identity-keyed channels (changed, focus, modal, window title, readouts) are unaffected."
            )
        }
        if diff.focusChanged {
            var focus: [String: JSONValue] = [:]
            focus["handle"] = diff.focusHandleAfter.map { .string($0) } ?? .null
            focus["role"] = diff.focusRoleAfter.map { .string($0) } ?? .null
            focus["label"] = diff.focusLabelJSONAfter ?? diff.focusLabelAfter.map {
                MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
            } ?? .null
            out["focus_changed_to"] = .object(focus)
        }
        if diff.modalAppeared || diff.modalDisappeared {
            out["modal"] = .object([
                "appeared": .bool(diff.modalAppeared),
                "disappeared": .bool(diff.modalDisappeared),
                "label": diff.modalLabelAfter.map {
                    MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                } ?? .null,
            ])
        }
        if diff.windowTitleChanged {
            out["window_title"] = diff.windowTitleAfter.map {
                MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
            } ?? .null
        }
        return out
    }

    /// Plan and run ONE verb. Every mechanism here is an EXISTING one:
    /// `MacAccessibilityActuator.act` (which owns the AXPress → synthesized
    /// click fallback), the actuator's own `perform`, and `MacEventPlanner` +
    /// the event sink (the same path `mac_keystroke` / `mac_scroll` use).
    /// Nothing new posts events and nothing new mutates AX.
    ///
    /// Returns nil when the element exposes NO mechanism for the verb — the
    /// caller turns that into a named refusal, never a silent no-op.
    /// Did the pointer end where it started? Computed from the two READS, so a
    /// nudge that failed to return the cursor cannot report success — and a
    /// null (either position unreadable) stays null rather than collapsing to
    /// `true`.
    ///
    /// SUB-PIXEL tolerance, not one pixel. The nudge's displacement IS one
    /// pixel, so a 1.0 slack would call "moved one pixel and stayed there" a
    /// successful restore — the precise failure this exists to catch. Only
    /// float noise is forgiven; any real displacement, including the user's own
    /// hand during the settle wait, reads `false`, which is the truth.
    static func pointerRestoredJSON(before: MacSessionState, after: MacSessionState) -> JSONValue {
        guard let bx = before.cursorX, let by = before.cursorY,
              let ax = after.cursorX, let ay = after.cursorY else { return .null }
        return .bool(abs(ax - bx) < 0.5 && abs(ay - by) < 0.5)
    }

    private func performAct(
        verb: MacActVerb,
        handle: String,
        entry: MacLookFrameEntry,
        frame: MacLookFrame,
        /// B2 — the pid the frame was captured from. Every resolve this function
        /// still has to make (the dismiss button) is anchored to it, so no verb
        /// can reach into whatever app is frontmost by now.
        framePid: Int32,
        /// B1 — and to the WINDOW the frame was captured from. The dismiss
        /// button is looked up by path, and a path resolved in the app's other
        /// window presses whatever sits at that position there.
        actWindow: MacAXWindowRef,
        target: MacAXActTarget,
        text: String?,
        direction: MacActScrollDirection,
        /// Round 7 — non-nil when the frame's window is NOT key, i.e. when any
        /// synthesized event would land somewhere other than the window she
        /// looked at. Consulted at every posting site; pure-AX paths ignore it.
        inputRefusal: MacActClosedLoop.KeyWindowRefusal?
    ) -> MacActPerformed? {
        /// Every synthesized-input site calls this FIRST. Non-nil ⇒ return it:
        /// nothing posted, nothing selected, nothing pressed. The AX paths above
        /// each site are untouched — this gates the window server, not the API.
        /// Has this call already INVOKED an actuation on the app?
        ///
        /// Agent round 8, envelope 70DA30C4 — the lying receipt. `AXOpen` on a
        /// .json filename LAUNCHED Xcode (the same envelope carries
        /// `AXWindowCreated` at 139 ms and the file was on screen), and the
        /// AX call still reported a status other than `.performed`, so step 1
        /// fell through. The chord branch then re-read the frontmost app, saw
        /// XCODE — the window the act had just opened — and returned
        /// `window_not_key, performed: false, method: none, posted_events: 0`.
        /// A successful open reported as "nothing was posted".
        ///
        /// AN AX ACTION'S RETURN STATUS IS NOT EVIDENCE THAT IT DID NOTHING.
        /// Once an action has been delivered, a later focus change is EVIDENCE
        /// OF SUCCESS, not grounds for a pre-emission refusal. So the gate is
        /// strictly pre-actuation: after this flips, `refuseInput` may still
        /// stop us POSTING (an event into the wrong app is never right), but it
        /// may never again describe the call as having done nothing.
        /// The ENTRY-TIME verdict, mutable because a successful raise makes it
        /// obsolete. Its own doc calls a stale verdict "a memory, not a gate" —
        /// so once we have RAISED the window and a fresh read says it is key,
        /// the memory must not veto the live fact.
        var entryRefusal = inputRefusal
        /// One raise per call. A second attempt after the first failed to take
        /// would be a retry loop against the window server, and the window
        /// server wins.
        var raiseAttempted = false
        var didActuate = false
        var actuationsAttempted: [String] = []
        func noteActuation(_ action: String) {
            didActuate = true
            if !actuationsAttempted.contains(action) { actuationsAttempted.append(action) }
        }

        // ROUND 9, envelope 62D093EB — THE LEDGER MUST COVER EVERY MUTATION.
        //
        // Round 8 bought the rule "an AX action's return status is not evidence
        // that it did nothing" and paid for it with `noteActuation`. It was then
        // applied to the actuation sites the round-8 receipt happened to name,
        // and the FIRST actuation in `open` — the handle's own `AXOpen`, which
        // runs above the verb gate — was left outside the ledger. Agent's
        // round-9 Finder receipt is the same lie by the same mechanism: that
        // AXOpen navigated window-a into TargetFolder (title change, sentinel
        // visible, 34 notifications) and returned something other than
        // `.performed`, so the code fell through to the gate, `didActuate` was
        // still false, and the envelope said `performed: false, posted_events:
        // 0` about an act that had already happened.
        //
        // The defence is structural, not another remembered call site: every AX
        // mutation this function makes goes through one of these wrappers, and
        // each ledgers BEFORE it reads a status. Adding an AX mutation without
        // a wrapper is now the visible thing to review for.
        func ledgeredPerform(_ actTarget: MacAXActTarget, action: String) -> MacAXActOutcome {
            noteActuation(action)
            return accessibilityActSource.perform(actTarget, action: action)
        }
        func ledgeredSetSelected(_ actTarget: MacAXActTarget) -> MacAXActOutcome {
            noteActuation("AXSelected")
            return accessibilityActSource.setSelected(actTarget)
        }
        func ledgeredSetFocused(_ actTarget: MacAXActTarget) -> MacAXActOutcome {
            noteActuation("AXFocused")
            return accessibilityActSource.setFocused(actTarget)
        }
        func ledgeredActuatorAct(
            action: String?,
            value: String?,
            resolved: MacAXActTarget
        ) -> Result<MacAccessibilityActuator.ActResult, MacAccessibilityActuator.Failure> {
            noteActuation(value != nil ? "AXSetValue" : (action ?? MacAccessibilityActuator.defaultAction))
            return MacAccessibilityActuator.act(
                source: accessibilityActSource,
                sink: eventSink,
                path: [],
                action: action,
                value: value,
                resolved: resolved
            )
        }

        /// The LIVE key-window verdict — one pair of AX reads, both windows
        /// named. Round 9 second finding: the two call sites below each built
        /// this by hand, called `frontmostApp()` twice, and passed
        /// `focusedWindowTitle: nil`, so every wrong-window refusal Agent ever
        /// received said "key: untitled" no matter what the key window was
        /// actually called. The refusal names the window she has to deal with;
        /// it cannot be a placeholder.
        func liveKeyWindowRefusal() -> MacActClosedLoop.KeyWindowRefusal? {
            let frontmost = accessibilitySource.frontmostApp()
            let focused = accessibilityActSource.focusedWindow(pid: framePid)
            return MacActClosedLoop.keyWindowRefusal(
                framePid: framePid,
                frontmostPid: frontmost?.processIdentifier,
                frontmostName: frontmost?.name,
                frameWindowHandle: actWindow.handle,
                focusedWindowHandle: focused?.handle,
                frameWindowTitle: actWindow.identity.title,
                focusedWindowTitle: focused?.identity.title,
                // Counted ONLY when the focused window could not be named —
                // that is the single branch that consults it, and enumerating
                // an app's windows is several AX round-trips at a gate that
                // runs more than once per act.
                appWindowCount: focused == nil
                    ? accessibilityActSource.windows(pid: framePid).count
                    : nil
            )
        }

        func refuseInput(_ requestedAction: String) -> MacActPerformed? {
            // RE-READ at the emission boundary, never trust the entry-time
            // verdict alone (gpt-5.5 round-7 BLOCKING). Between the gate in
            // `handleAct` and this line the verb has done real AX work — an
            // AXOpen attempt, an ancestor re-resolve — and the front can move
            // under it. The residual race is one AX read wide and no lock can
            // close it (the window server owns focus), but a stale verdict from
            // hundreds of milliseconds ago is not a gate, it is a memory.
            let live = liveKeyWindowRefusal()
            guard var inputRefusal = live ?? entryRefusal else { return nil }

            // HANDS, NOT HOMEWORK (User, 2026-08-22: "a live screen with hands
            // she can use"). The window she is acting in is not key. Every
            // previous round answered that by refusing and telling her to bring
            // it forward and look again — bookkeeping handed back to the caller
            // for something this tool can simply DO. So do it: raise THAT
            // window (AXRaise + activate, since either alone leaves the wrong
            // thing key), then re-ask. Only a raise that fails to make it key
            // is a refusal.
            //
            // Not attempted once an actuation has been delivered: raising after
            // the fact cannot un-deliver it, and the honest report of what
            // already happened (below) is the right answer there.
            /// Did the raise actually LAND? Agent's 7FCDC92E receipt is what
            /// this exists for. Two live measurements, background process,
            /// Chrome frontmost, 2026-08-22:
            ///
            ///   * `NSRunningApplication.activate()` returns `true` and the
            ///     front does not move. The Bool is a receipt for the REQUEST.
            ///   * activation, when it is honoured at all, is ASYNCHRONOUS —
            ///     the call returns before the window server has moved
            ///     anything.
            ///
            /// So one read immediately after the raise decides nothing, and it
            /// can decide it in the dangerous direction: a single matching
            /// answer cleared the gate and a coordinate click went out while
            /// Chrome still owned the screen. The verdict has to HOLD — two
            /// consecutive clear reads — and it is given a bounded budget to
            /// become true rather than being asked once and abandoned.
            func raiseSettled() -> Bool {
                /// ~500 ms of budget in 20 ms steps. Deliberately short: this
                /// blocks the act, and an app switch the window server has not
                /// made in half a second is not being made.
                let reads = 25
                let stepSeconds = 0.02
                /// One matching read is the optimistic answer; two in a row is
                /// a state.
                let clearReadsRequired = 2
                var consecutiveClear = 0
                for attempt in 0..<reads {
                    if attempt > 0 { Thread.sleep(forTimeInterval: stepSeconds) }
                    if liveKeyWindowRefusal() == nil {
                        consecutiveClear += 1
                        if consecutiveClear >= clearReadsRequired { return true }
                    } else {
                        // A flicker back is a failed switch, not progress.
                        consecutiveClear = 0
                    }
                }
                return false
            }

            if !didActuate, !raiseAttempted {
                raiseAttempted = true
                let outcome = accessibilityActSource.raise(actWindow)
                if outcome == .performed, raiseSettled() {
                    // It is key now. Retire the stale entry verdict so the NEXT
                    // gate call in this same act (step 1 and the chord branch
                    // each consult it) does not refuse on a fact that stopped
                    // being true when we raised the window.
                    entryRefusal = nil
                    return nil
                }
                // Raise did not take. Say so in the refusal rather than
                // repeating advice she already followed.
                inputRefusal = MacActClosedLoop.KeyWindowRefusal(
                    reason: inputRefusal.reason,
                    note: inputRefusal.note
                        + " This call also tried to RAISE that window itself (raise outcome: "
                        + "\(outcome.rawValue)) and then WAITED up to half a second for the window "
                        + "server to honour it; the window never became key and stayed key, so the "
                        + "block is real rather than a matter of ordering. A raise that reports "
                        + "success and does not move the front is what an activation request looks "
                        + "like from a background process — the front app itself has to yield."
                        // The one raise failure with a fixable cause, when the
                        // source knows it: a missing Automation grant. Silence
                        // here would report "could not raise" for "you were
                        // never allowed to."
                        + (accessibilityActSource.raiseDiagnostic.map { " \($0)" } ?? "")
                )
            }
            // ALREADY ACTUATED. We still refuse to POST — an event into the app
            // that is key now is never what she asked for — but the envelope
            // must describe what this call actually did. `performed: false` and
            // "nothing was posted" here would be the round-8 lie.
            guard !didActuate else {
                return MacActPerformed(
                    ok: true,
                    method: "ax_action",
                    requestedAction: requestedAction,
                    fallbackReason: "key_window_changed_after_actuation",
                    error: nil,
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "actuations_attempted": .array(actuationsAttempted.map { .string($0) }),
                        "key_window_changed_after_actuation": .bool(true),
                        "guidance": .string(
                            "an accessibility action was DELIVERED to the element and the key window "
                            + "was not (or is no longer) the one this frame describes — which is also "
                            + "what a successful open or launch looks like from here. No synthesized "
                            + "event was posted (that would have gone to the key window). Read "
                            + "`effect` for what was actually observed; this call does not claim the "
                            + "result is what you asked for, only that something was delivered."
                        ),
                    ]
                )
            }
            return MacActPerformed(
                ok: false,
                method: "none",
                requestedAction: requestedAction,
                fallbackReason: inputRefusal.reason,
                error: inputRefusal.reason,
                target: target,
                postState: nil,
                actedHandle: handle,
                extra: [
                    "posted_events": .int(0),
                    "guidance": .string(inputRefusal.note),
                ]
            )
        }

        func summarize(
            _ result: MacAccessibilityActuator.ActResult,
            target: MacAXActTarget,
            actedHandle: String,
            extra: [String: JSONValue] = [:]
        ) -> MacActPerformed {
            MacActPerformed(
                ok: result.ok,
                method: result.method,
                requestedAction: result.requestedAction,
                fallbackReason: result.fallbackReason,
                error: result.error,
                target: target,
                postState: result.postState,
                actedHandle: actedHandle,
                extra: extra
            )
        }

        /// AXPress with the actuator's own synthesized-click fallback — the
        /// shared mechanism behind click / select / toggle, and behind the
        /// dismiss button once it has been found.
        func press(_ pressTarget: MacAXActTarget, actedHandle: String, extra: [String: JSONValue] = [:]) -> MacActPerformed? {
            // AXPress itself is pure AX and stays ungated — acting on a
            // background window that way is an established capability. But the
            // actuator's own SYNTHESIZED-CLICK fallback is window-server input,
            // and until round 9 it was the one CGEvent emitter in this file the
            // key-window gate never saw. Gate it where it happens.
            var gateRefusal: MacActPerformed?
            let outcome = MacAccessibilityActuator.act(
                source: accessibilityActSource,
                sink: eventSink,
                path: [],
                action: MacAccessibilityActuator.defaultAction,
                value: nil,
                resolved: pressTarget,
                syntheticFallbackGate: { reason in
                    // `ax_action_*` means the AX action was DELIVERED and only
                    // its status disappointed us — round 8's rule. Ledger it
                    // before the gate can describe this call as having done
                    // nothing.
                    // …but NOT `invalidTarget`, which the actuator returns
                    // when the element handle no longer resolves — that path
                    // returns BEFORE AXUIElementPerformAction, so nothing was
                    // delivered and ledgering it would let a refusal claim an
                    // actuation that never happened (gpt-5.5 round-9 BLOCKING).
                    if reason.hasPrefix("ax_action_"), reason != "ax_action_invalidTarget" {
                        noteActuation(MacAccessibilityActuator.defaultAction)
                    }
                    if let refusal = refuseInput(MacAccessibilityActuator.defaultAction) {
                        gateRefusal = refusal
                        return false
                    }
                    return true
                }
            )
            if let gateRefusal { return gateRefusal }
            switch outcome {
            case .failure:
                return nil
            case .success(let result):
                return summarize(result, target: pressTarget, actedHandle: actedHandle, extra: extra)
            }
        }

        switch verb {
        case .click, .select, .toggle:
            // One mechanism, three intentions. AXPress runs the app's OWN
            // handler — which is what "select this row" and "toggle this
            // checkbox" mean to the app — and the actuator falls back to a
            // synthesized click at the element's frame centre when the control
            // advertises no action, saying which one fired.
            return press(target, actedHandle: handle)

        case .open:
            // Agent round 2 — navigating Finder by handle needs the DOUBLE
            // click, and there was no verb for it. `AXOpen` is the semantic
            // form; when the element does not advertise it, the fallback is the
            // EXISTING click injection path with a click count of two. No new
            // event poster, no new AX mutator.
            //
            // Round 4, finding 1(a) — and this is what made Finder `open` a
            // no-op: the verb was aimed at the handle SHE HELD. Her handle was
            // the filename `AXTextField` (a cell); AXOpen was refused there and
            // the double-click landed on the text, which is Finder's RENAME
            // gesture. Resolve to the element that actually opens FIRST, then
            // run the same two mechanisms against it.
            // ORDER IS THE FIX. Try the handle's own AXOpen FIRST — and only
            // escalate when it did not PERFORM. Her cell advertised AXOpen and
            // refused it (`fallback_reason=ax_action_refused`), so a redirect
            // gated on "does not advertise AXOpen" would never have fired for
            // the case it was written for. Advertising is not doing.
            //
            // ROUND 9: THE GATE IS HERE, ABOVE THE FIRST ACTUATION. It used to
            // sit below this attempt, under a comment claiming it ran "BEFORE
            // THE FIRST ACTUATION" — it did not, and the handle's own AXOpen
            // therefore fired on a window that was not key AND outside the
            // actuation ledger. Both halves of Agent's round-9 receipt come
            // from those two lines of distance.
            if let refusal = refuseInput("AXOpen") { return refusal }

            if target.actions.contains("AXOpen"),
               ledgeredPerform(target, action: "AXOpen") == .performed {
                return MacActPerformed(
                    ok: true,
                    method: "ax_action",
                    requestedAction: "AXOpen",
                    fallbackReason: nil,
                    error: nil,
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: ["acted_on": MacActClosedLoop.OpenTargetResolution(
                        path: entry.path,
                        hops: 0,
                        role: target.role,
                        advertisesOpen: true,
                        reason: "handle_opened"
                    ).toJSON()]
                )
            }
            // The handle would not open. Climb to the element that will.
            let openPlan = MacActClosedLoop.planOpenFallback(
                path: entry.path
            ) { ancestorPath in
                // The SAME window-anchored resolve the act itself used, so the
                // walk cannot reach another window or another app.
                guard case .resolved(let hit) = accessibilityActSource.resolve(
                    path: ancestorPath, inWindow: actWindow
                ) else { return nil }
                return (role: hit.role, actions: hit.actions)
            }

            /// Re-resolve a chosen ancestor and prove it is STILL what the walk
            /// chose. The named handle's drift guard ran before this function;
            /// an ancestor we climbed to has no guard of its own, so it gets one
            /// here. Nil ⇒ do not act on it.
            enum LiveAncestor {
                case live(MacAXActTarget)
                /// The path no longer resolves at all.
                case vanished
                /// It resolves, but is not the thing the walk chose.
                case drifted(found: String)

                var target: MacAXActTarget? {
                    if case .live(let hit) = self { return hit }
                    return nil
                }
                var refusalReason: String? {
                    switch self {
                    case .live: return nil
                    case .vanished: return "openable_ancestor_vanished"
                    case .drifted: return "openable_ancestor_drifted"
                    }
                }
            }
            func liveAncestor(_ choice: MacActClosedLoop.OpenTargetResolution) -> LiveAncestor {
                guard case .resolved(let hit) = accessibilityActSource.resolve(
                    path: choice.path, inWindow: actWindow
                ) else { return .vanished }
                guard hit.role == choice.role else { return .drifted(found: hit.role) }
                return .live(hit)
            }

            // RE-CHECK before the escalated attempt. The whole-verb gate now
            // runs above the handle's own AXOpen (Agent round 8: "emission gate
            // strictly before selection/event"; round 9: it has to be above the
            // FIRST one, not the second). This call is the emission-boundary
            // re-read the fallback path is entitled to — and if the first
            // AXOpen already delivered, the ledger makes this report what
            // happened instead of claiming nothing did.
            if let refusal = refuseInput("AXOpen") { return refusal }

            // 1. THE SEMANTIC PATH, any role. `AXUIElementPerformAction` does
            //    what the app says it does; it cannot land somewhere else, so a
            //    cell is a fine target for it.
            if let semantic = openPlan.semantic, let live = liveAncestor(semantic).target {
                // NOTE THE ATTEMPT BEFORE READING THE STATUS. Round 8 proved the
                // status is not a verdict on the effect: this exact call opened
                // a .json in Xcode and did NOT come back `.performed`.
                let semanticOutcome: MacAXActOutcome? = live.actions.contains("AXOpen")
                    ? ledgeredPerform(live, action: "AXOpen")
                    : nil
                if semanticOutcome == .performed {
                    return MacActPerformed(
                        ok: true,
                        method: "ax_action",
                        requestedAction: "AXOpen",
                        fallbackReason: nil,
                        error: nil,
                        target: live,
                        postState: accessibilityActSource.reread(live),
                        actedHandle: handle,
                        extra: ["acted_on": semantic.toJSON()]
                    )
                }
            }

            // 2. THE CLICK PATH, ROWS ONLY. A synthesized double-click is a
            //    POSITION on User's screen. The semantic candidate above is NOT
            //    reused here: if a cell's AXOpen refused, double-clicking that
            //    same cell is the rename gesture — the original bug by a new
            //    route (gpt-5.5 round-5 review, second pass).
            var openTarget = target
            var openResolutionReported = MacActClosedLoop.OpenTargetResolution(
                path: entry.path,
                hops: 0,
                role: target.role,
                advertisesOpen: target.actions.contains("AXOpen"),
                reason: openPlan.click == nil && openPlan.semantic == nil
                    ? "no_openable_ancestor"
                    : "fell_back_to_handle"
            )
            if let click = openPlan.click {
                let live = liveAncestor(click)
                guard let hit = live.target else {
                    // REFUSE, never revert. Falling back to the handle here
                    // would re-run the exact rename gesture this resolution
                    // exists to avoid, on a window that just changed under us.
                    // Nothing is performed and nothing is posted.
                    let reason = live.refusalReason ?? "openable_ancestor_vanished"
                    // NOT `acted_on` — nothing was performed and nothing was
                    // posted. It names what the redirect was AIMING at when the
                    // window moved under it (gpt-5.5 round-5, third pass).
                    var extra: [String: JSONValue] = ["attempted_on": click.toJSON()]
                    if case .drifted(let found) = live {
                        extra["openable_ancestor_drift"] = .object([
                            "expected_role": .string(click.role),
                            "found_role": .string(found),
                        ])
                    }
                    return MacActPerformed(
                        ok: false,
                        method: "none",
                        requestedAction: "AXOpen",
                        fallbackReason: reason,
                        error: reason,
                        target: target,
                        postState: accessibilityActSource.reread(target),
                        actedHandle: handle,
                        extra: extra
                    )
                }
                openTarget = hit
                openResolutionReported = click
            }
            // ALWAYS reported, redirect or not: an act that lands somewhere
            // other than the handle she named must never be silent.
            let openTargetJSON = openResolutionReported.toJSON()

            // 3. SELECT + THE APP'S OPEN COMMAND — the only mechanism round 6
            //    measured as actually navigating. Finder advertises AXOpen on
            //    the filename and returns kAXErrorActionUnsupported for it,
            //    AXConfirm reports success and does nothing, and a synthesized
            //    double-click is inert at BOTH the row centre and the filename.
            //    Selecting the row and pressing the app's Open chord works.
            //    Only fires for apps whose chord is PROVEN (see the table).
            if let chord = MacActClosedLoop.openCommandChord(forBundleId: frame.bundleId),
               eventSink.isAvailable {
                // ONLY a live, still-verified ROW may be selected-and-opened.
                // gpt-5.5 round-7 review: `?? target` let a Finder element with
                // settable AXSelected but NO openable row ancestor reach the
                // chord — Cmd-Down would then open whatever Finder had selected,
                // which is not what the caller named. No row ⇒ no chord.
                // Before the SELECTION, not just before the chord: selecting a
                // row is a visible mutation whose only purpose is to feed a
                // chord we are about to refuse to post. Zero input means zero
                // side effects.
                if let refusal = refuseInput("AXOpen") { return refusal }
                let selectTarget = openPlan.click.flatMap { liveAncestor($0).target }
                let selectable = selectTarget.map {
                    MacActClosedLoop.openableAncestorRoles.contains($0.role)
                } ?? false
                let selected = selectable && selectTarget != nil
                    ? ledgeredSetSelected(selectTarget!)
                    : MacAXActOutcome.unsupported
                if let selectTarget, selected == .performed {
                    // THE EMISSION BOUNDARY IS THE POST, NOT THE PRE-SELECTION
                    // CHECK (gpt-5.5 round-9 BLOCKING). Selecting the row is
                    // itself a mutation that can move focus, and an external
                    // race has the same window it always has. Re-ask here, one
                    // line above the chord — and because the selection IS in
                    // the ledger, a refusal at this point reports what was
                    // already done instead of claiming nothing was.
                    if let refusal = refuseInput("AXOpen") { return refusal }
                    for event in MacEventPlanner.chord(chord) { eventSink.post(key: event) }
                    return MacActPerformed(
                        ok: true,
                        method: "select_and_open_command",
                        requestedAction: "AXOpen",
                        fallbackReason: "ax_open_unsupported_by_app",
                        error: nil,
                        target: selectTarget,
                        postState: accessibilityActSource.reread(selectTarget),
                        actedHandle: handle,
                        extra: [
                            "acted_on": openTargetJSON,
                            "open_command": .string(chord.source),
                            "selected_role": .string(selectTarget.role),
                        ]
                    )
                }
            }

            let openFallbackReason = openTarget.actions.contains("AXOpen")
                ? "ax_action_refused"
                : "element_does_not_advertise_AXOpen"
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "AXOpen",
                    fallbackReason: openFallbackReason,
                    error: "event_injection_unavailable",
                    target: openTarget,
                    postState: accessibilityActSource.reread(openTarget),
                    actedHandle: handle,
                    extra: ["attempted_on": openTargetJSON]
                )
            }
            guard let centre = openTarget.centre else {
                // No frame, no honest place to double-click. Refused by name
                // rather than clicking the screen corner.
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "AXOpen",
                    fallbackReason: openFallbackReason,
                    error: "no_ax_open_and_no_frame",
                    target: openTarget,
                    postState: accessibilityActSource.reread(openTarget),
                    actedHandle: handle,
                    extra: ["attempted_on": openTargetJSON]
                )
            }
            if let refusal = refuseInput("AXOpen") { return refusal }
            for event in MacEventPlanner.click(x: centre.x, y: centre.y, button: .left, count: 2) {
                eventSink.post(mouse: event)
            }
            return MacActPerformed(
                ok: true,
                method: "cgevent_double_click_fallback",
                requestedAction: "AXOpen",
                fallbackReason: openFallbackReason,
                error: nil,
                target: openTarget,
                postState: accessibilityActSource.reread(openTarget),
                actedHandle: handle,
                extra: ["click_count": .int(2), "acted_on": openTargetJSON]
            )

        case .type:
            guard let text, !text.isEmpty else { return nil }
            // Editable elements ONLY. Below this line the fallback focuses the
            // control and injects keystrokes, and the old way of "focusing" it
            // was AXPress — which on a button is ACTIVATION: `type` aimed at
            // Mail's Send pressed Send. A verb that cannot be carried out is
            // refused by name (`verb_not_supported_on_element`), never
            // approximated with a different act.
            guard MacActClosedLoop.canType(role: target.role) else { return nil }
            // A PASSWORD FIELD IS A BOUNDARY, NOT A MECHANISM FAILURE (sweep
            // item 8). AXSetValue would happily fill one, and the keystroke
            // fallback below would post into a void — macOS has secure
            // keyboard entry on whenever such a field holds focus. Both
            // answers are wrong for the same reason: the credential is User's
            // to type. Refuse here, above every actuation, in words.
            if let refusal = MacActClosedLoop.secureFieldRefusal(role: target.role) {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "type",
                    fallbackReason: refusal.reason,
                    error: refusal.reason,
                    target: target,
                    postState: nil,
                    actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "guidance": .string(refusal.note),
                    ]
                )
            }
            // AXSetValue first: that is how you fill a field without
            // simulating 40 keystrokes, and it cannot be intercepted by
            // whatever else has focus.
            let setOutcome = ledgeredActuatorAct(action: nil, value: text, resolved: target)
            if case .success(let result) = setOutcome, result.ok {
                return summarize(result, target: target, actedHandle: handle)
            }
            // Not settable (a web input, a terminal, a rich-text view). Focus
            // it the app's own way, then use the EXISTING keystroke injection
            // path — the same planner + sink `mac_keystroke` runs through.
            // Focus WITHOUT invoking the handler. Even on an editable role,
            // AXPress runs the app's own action (a search field's press can
            // submit); AXFocused is the attribute that means "the cursor is
            // here" and nothing else.
            let focusOutcome = ledgeredSetFocused(target)
            let focusMethod = focusOutcome == .performed ? "ax_focus" : "none"
            guard focusOutcome == .performed else {
                // No focus, no honest keystroke target: typing now would land
                // wherever the focus already was. Report instead of scattering
                // text across the app.
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "type",
                    fallbackReason: "value_not_settable",
                    error: "focus_not_settable",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: ["focus_method": .string(focusMethod)]
                )
            }
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "type",
                    fallbackReason: "value_not_settable",
                    error: "event_injection_unavailable",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: ["focus_method": .string(focusMethod)]
                )
            }
            // The keystroke fallback: AXSetValue could not carry this, so the
            // characters go through the window server and land wherever the key
            // window is. Refuse rather than type into another app.
            //
            // SECURE KEYBOARD ENTRY FIRST (sweep item 8), because it is a pure
            // read and the key-window gate below can RAISE a window — no point
            // moving User's screen around for keystrokes that cannot be
            // delivered to anything.
            if let refusal = MacActClosedLoop.secureInputRefusal(
                active: eventSink.secureKeyboardEntryActive
            ) {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "type",
                    fallbackReason: refusal.reason,
                    error: refusal.reason,
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle,
                    extra: [
                        "posted_events": .int(0),
                        "focus_method": .string(focusMethod),
                        "guidance": .string(refusal.note),
                    ]
                )
            }
            if let refusal = refuseInput("type") { return refusal }
            for event in MacEventPlanner.typeText(text) {
                eventSink.post(key: event)
            }
            return MacActPerformed(
                ok: true,
                method: "keystroke_injection",
                requestedAction: "type",
                fallbackReason: "value_not_settable",
                error: nil,
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: [
                    "focus_method": .string(focusMethod),
                    "text_character_count": .int(Int64(text.count)),
                ]
            )

        case .dismiss:
            // The modal's OWN Cancel/Close/Dismiss/Done/OK button, found in the
            // CURRENT frame and scoped by path prefix to the modal — a window
            // behind a sheet often has its own "Close", and pressing that would
            // act on the wrong surface entirely.
            if let dismissEntry = MacActClosedLoop.dismissTarget(in: frame),
               case .resolved(let dismissTarget) = accessibilityActSource.resolve(
                   path: dismissEntry.path,
                   inWindow: actWindow
               ),
               MacActClosedLoop.driftReason(
                   expectedRole: dismissEntry.role,
                   expectedLabel: dismissEntry.label,
                   liveRole: dismissTarget.role,
                   liveTitle: dismissTarget.title,
                   liveValue: dismissTarget.value
               ) == nil {
                return press(
                    dismissTarget,
                    actedHandle: dismissEntry.handle,
                    extra: [
                        "dismiss_target": .object([
                            "handle": .string(dismissEntry.handle),
                            "label": dismissEntry.label.map {
                                MacScreenViewTextRedaction.redactedLegendString(
                                    $0,
                                    valueChars: MacAXLimits.hardValueChars
                                )
                            } ?? .null,
                        ]),
                    ]
                )
            }
            // No button: the element's own AXCancel, if it advertises one.
            guard target.actions.contains("AXCancel") else { return nil }
            let outcome = ledgeredPerform(target, action: "AXCancel")
            return MacActPerformed(
                ok: outcome == .performed,
                method: outcome == .performed ? "ax_action" : "none",
                requestedAction: "AXCancel",
                fallbackReason: "no_dismiss_button_in_frame",
                error: outcome == .performed ? nil : "ax_action_\(outcome.rawValue)",
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle
            )

        case .scroll:
            // AXScrollToVisible is the semantic form and needs no coordinates.
            if target.actions.contains("AXScrollToVisible") {
                let outcome = ledgeredPerform(target, action: "AXScrollToVisible")
                if outcome == .performed {
                    return MacActPerformed(
                        ok: true,
                        method: "ax_action",
                        requestedAction: "AXScrollToVisible",
                        fallbackReason: nil,
                        error: nil,
                        target: target,
                        postState: accessibilityActSource.reread(target),
                        actedHandle: handle
                    )
                }
            }
            // Otherwise the EXISTING wheel path, aimed at the element's centre
            // so the scroll lands on the intended view rather than wherever the
            // cursor happened to sit.
            guard eventSink.isAvailable else {
                return MacActPerformed(
                    ok: false,
                    method: "none",
                    requestedAction: "scroll",
                    fallbackReason: "element_does_not_advertise_AXScrollToVisible",
                    error: "event_injection_unavailable",
                    target: target,
                    postState: accessibilityActSource.reread(target),
                    actedHandle: handle
                )
            }
            if let refusal = refuseInput("scroll") { return refusal }
            if let centre = target.centre {
                eventSink.post(mouse: MacMouseEvent(phase: .move, button: .left, x: centre.x, y: centre.y))
            }
            // `down` moves the CONTENT up, which is what a human means by
            // scrolling down. Three lines: one notch of a physical wheel.
            let deltaY: Int32 = direction == .down ? -3 : 3
            eventSink.post(scroll: MacScrollEvent(deltaX: 0, deltaY: deltaY, unit: .line))
            return MacActPerformed(
                ok: true,
                method: "cgevent_scroll_fallback",
                requestedAction: "scroll",
                fallbackReason: "element_does_not_advertise_AXScrollToVisible",
                error: nil,
                target: target,
                postState: accessibilityActSource.reread(target),
                actedHandle: handle,
                extra: [
                    "direction": .string(direction.rawValue),
                    "dy": .int(Int64(deltaY)),
                ]
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

    /// `wake` — dismiss a screensaver / wake a sleeping display with
    /// the smallest possible HID nudge, then hand back the fresh fused view.
    ///
    /// THE SAFETY LINE, and the reason this is one tool rather than "call
    /// mac_click then mac_view": the session is probed BEFORE anything is posted,
    /// and an unreadable/off-console session returns a refusal with the sink
    /// untouched. It is probed AGAIN after the settle wait and before capture.
    /// The ambiguous CoreGraphics obstruction flag never blocks the inert
    /// nudge; it only prevents capture while the saver/login layer remains.
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
        if let reason = MacWakeGuard.nudgeRefusalReason(for: before) {
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
        // NEVER FABRICATE THE ORIGIN. `?? 0` used to mean "unreadable cursor ⇒
        // move the pointer to (0,0)" — the TOP-LEFT HOT CORNER, which is a
        // configurable trigger (Lock Screen, Mission Control, Quick Note). A
        // nudge is supposed to be the smallest inert input there is; teleporting
        // the pointer into a corner is neither small nor inert. An unreadable
        // cursor now REFUSES rather than guessing a coordinate, and the same
        // rule is what makes the relaxed nudge guard honest: the only thing we
        // ever post is a one-pixel move from where the pointer ALREADY is.
        guard let cursorX = before.cursorX, let cursorY = before.cursorY else {
            return injectionRefusal(
                action: "wake",
                error: "cursor_position_unreadable: this Mac would not report where the pointer "
                    + "is, and a nudge posted at a guessed origin could land in a hot corner "
                    + "instead of nowhere, so it refuses rather than move the pointer somewhere "
                    + "it was not",
                status: 503,
                extra: ["session_before": before.toJSON()]
            )
        }
        let origin = (cursorX, cursorY)
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
        // ON BY DEFAULT (User, 2026-08-22; opt out with key_tap:false). Live
        // runs C3F445B2/B94F9DCF proved a bare one-pixel move resets the idle
        // clock and dismisses NOTHING — the saver layer wants a real gesture.
        // Left-shift alone types nothing in any app and cannot authenticate.
        var keyEvents = 0
        if body["key_tap"] != .bool(false) {
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
        if let reason = MacWakeGuard.captureRefusalReason(for: after) {
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
                        "still_obstructed": .bool(true),
                        // THE POINTER CLAIM, MADE CHECKABLE (Agent F0D81308).
                        // The nudge posts (x+1, y) then (x, y), so restoration
                        // is true by construction — but "by construction" is an
                        // argument, not evidence, and she was right that the
                        // receipt could not prove it. These are the two READ
                        // positions; `pointer_restored` is their COMPARISON,
                        // not a restatement of intent, and it is null when
                        // either read failed rather than optimistically true.
                        "nudge_origin": .object([
                            "x": before.cursorX.map { .double(($0 * 10).rounded() / 10) } ?? .null,
                            "y": before.cursorY.map { .double(($0 * 10).rounded() / 10) } ?? .null,
                        ]),
                        "pointer_restored": Self.pointerRestoredJSON(before: before, after: after),
                        "note": .string(
                            "The nudge was delivered and the saver/login layer is still covering "
                                + "the screen, so nothing was photographed or read back. Retrying "
                                + "can help; a screen that never clears needs a human at the "
                                + "keyboard."
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
        // BUILT IN STEPS, not as one literal. Adding two more keys to the big
        // dictionary literal here tipped the Swift type checker past its budget
        // ("unable to type-check this expression in reasonable time") and hung
        // the build for ten minutes before it was killed. Incremental
        // construction is not a style choice; the literal form does not compile.
        var wake: [String: JSONValue] = [:]
        wake["nudged"] = .bool(true)
        wake["mouse_events"] = .int(Int64(mouseEvents))
        wake["key_events"] = .int(Int64(keyEvents))
        wake["settle_ms"] = .int(Int64(settleMs))
        wake["was_obstructed"] = .bool(before.obstructed)
        wake["dismissed"] = .bool(dismissed)
        // The pointer claim rides on EVERY wake receipt, not just refusals —
        // the nudge moves the mouse whether or not the screen clears, so "it
        // was put back" needs proving on the success path too.
        wake["nudge_origin"] = .object([
            "x": before.cursorX.map { JSONValue.double(($0 * 10).rounded() / 10) } ?? .null,
            "y": before.cursorY.map { JSONValue.double(($0 * 10).rounded() / 10) } ?? .null,
        ])
        wake["pointer_restored"] = Self.pointerRestoredJSON(before: before, after: after)
        wake["session_before"] = before.toJSON()
        wake["session_after"] = after.toJSON()
        let wakeTail: [String: JSONValue] = [
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
                    : "The nudge (pointer move + shift tap) was posted but the screen still "
                        + "reports a sleeping display or the saver layer. Retry, or try a larger "
                        + "settle_ms."
            ),
        ]
        for (k, v) in wakeTail { wake[k] = v }
        output["wake"] = .object(wake)
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
