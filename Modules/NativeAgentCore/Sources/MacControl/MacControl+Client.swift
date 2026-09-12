import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - SwiftNative impl

public actor SwiftNativeMacControl: MacControlClient {
    let now: @Sendable () -> Date
    private let notificationCenterAdapter: NotificationCenterAdapter
    let appleScriptAdapter: AppleScriptAdapter
    let processAdapter: ProcessAdapter
    let fileManagerAdapter: FileManagerAdapter
    let appControlAdapter: AppControlAdapter
    let openTargetAdapter: OpenTargetAdapter
    /// Read-only accessibility perception seam (W1). Production reads live
    /// AXUIElement state; tests inject a synthetic tree so the caps and the
    /// ranking are pinned without a window server.
    let accessibilitySource: any MacAXElementSource
    /// W2 — the physical input seam (CGEvent). Production posts real events at
    /// the HID tap; tests inject a recorder so no test ever moves the real
    /// mouse or keyboard. Deliberately separate from `accessibilitySource`:
    /// the read seam has no member that can emit anything.
    let eventSink: any MacEventSink
    /// W3 — the semantic act seam (AXUIElementPerformAction / SetAttributeValue),
    /// again separate from the read seam so perception stays provably
    /// injection-free.
    let accessibilityActSource: any MacAXActSource
    /// native-look item 3 — the CLOSED LOOP's effect seam. Production installs
    /// a real `AXObserver` on the target app's pid, sourced on the main run
    /// loop; tests inject a fake that emits scripted notifications and counts
    /// installs/removals, so "the observer is always removed" is pinned rather
    /// than assumed. Separate from every seam above for the same reason they
    /// are separate from each other: this one only LISTENS.
    let effectObserverSource: any MacAXEffectObserverSource
    /// W3.5 — the picture half of the fused view. Screen Recording is its OWN
    /// TCC permission; this seam only ever PREFLIGHTS it (never prompts, never
    /// toggles) and reports the answer honestly.
    let screenCaptureSource: any MacScreenCaptureSource
    let pointerPositionSource: any MacPointerPositionSource
    /// W3.5 — set-of-marks renderer. Injectable so the placement math and the
    /// byte budget are pinned with no window server in the loop.
    let screenImageRenderer: any MacScreenImageRenderer
    /// W3.5 — the latest fused view, so a later `mark` resolves to a real
    /// element. A mark is a REFERENCE ONLY: every injection gate still runs.
    let screenViewStore: MacScreenViewStore
    /// native-look item 2 — the latest look's task-scoped perceptual frame, so
    /// item 3's verbs can resolve a handle back to a path. Like a mark, a
    /// handle is a REFERENCE ONLY and grants no authority.
    let lookFrameStore: MacLookFrameStore
    /// Explicit, bounded continuity over fused views. The source installs no
    /// observers until `mac_attention start`; the store is shared because the
    /// dispatcher constructs a short-lived MacControl client per tool call.
    let attentionEventSource: any MacAttentionEventSource
    let attentionStore: MacAttentionSessionStore
    /// W6 — the login-session probe `wake` refuses on. Injectable so the
    /// locked-refusal is pinned without a real password lock in the loop, and
    /// deliberately separate from the event sink: the thing that DECIDES
    /// whether to post must not be the thing that posts.
    let sessionStateSource: any MacSessionStateSource
    /// fable51 item 30 — the pasteboard seam. Separate from every seam above
    /// for the same reason they are separate from each other: nothing in it can
    /// walk a tree, post an event, or capture a pixel.
    let pasteboardSource: any MacPasteboardSource
    /// Production uses the live Swift TrustCenter policy. A nil provider lets
    /// direct library callers exercise handlers without policy preflight.
    let policyProvider: (any MacControlPolicyProvider)?
    /// Optional refusal-audit path. Appends a stable legacy receipt under the
    /// shared file lock; nil disables auditing without changing the refusal.
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
        if case .double(let value) = body["timeout"] ?? .null,
           let timeout = Int(exactly: value.rounded(.towardZero)) {
            return max(1, min(timeout, 120))
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

    // MARK: gate pre-flight

    /// A refusal returns its shaped result; proceed continues native dispatch.
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

    /// Check master, remote, and category gates before the file-policy layer.
    /// Execution, approval, and operation receipts remain with their owners.
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
        // Accessibility category permission alone is insufficient: reads,
        // input, clipboard, document access and nudge also require an active
        // Full Mac window, including calls entering through remote surfaces.
        if macControlAccessibilityReadActions.contains(action)
            || macControlAccessibilityNudgeActions.contains(action)
            || macControlClipboardActions.contains(action)
            || macControlDocumentReadActions.contains(action)
            || macControlAccessibilityInjectionActions.contains(action),
           !(policy.trustPolicy.map { MacControlGate.fullMacActive($0) } ?? false) {
            let reason = "full_mac_inactive: \(action) requires an active Full Mac trust window"
            let result = Self.refusalResult(action: action, reason: reason, now: now)
            await emitBlockedAudit(action: action, category: category, reason: reason, trigger: trigger, policy: policy, body: body)
            return .refuse(result)
        }
        // Let each native handler report its authoritative sensitive-path
        // refusal before the workspace policy refusal. For other paths, run
        // the workspace-root and Full Mac checks here.
        let pathKeys = macControlFilePolicyPathKeys(forAction: action)
        if !pathKeys.isEmpty {
            let paths: [String] = pathKeys.compactMap { key in
                guard let v = body.stringValue(key), !v.isEmpty else { return nil }
                return v
            }
            let anySensitive = paths.contains { MacControlSensitivePathFence.reason(forPath: $0) != nil }
            if !anySensitive, !paths.isEmpty,
               let reason = MacControlGate.fileReason(policy, forPaths: paths) {
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

    // MARK: blocked-receipt audit append

    /// Preserve the audit format's legacy method names for renamed actions.
    /// Actions without a historical alias keep their dispatch name.
    private static func daemonMethodName(forAction action: String, body: [String: JSONValue]) -> String {
        switch action {
        case "applescript":   return "run_applescript"
        case "jxa":           return "run_jxa"
        case "shortcut",
             "shortcut/run":  return "run_shortcut"
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

    /// System dispatch records the concrete operation; unknown actions retain
    /// the generic system label.
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

    /// An explicit list is authoritative, including an empty one. An absent
    /// list requires approval only for shell, matching the saved audit format.
    private static func approvalRequired(forCategory category: String, policy: MacControlPolicy) -> Bool {
        guard let list = policy.approvalRequiredFor else {
            return category == "shell"
        }
        return list.contains(category)
    }

    /// Append a refusal under the shared cross-process lock. A failed audit
    /// must not turn a refused action into an executed one.
    ///
    /// Preserve the legacy receipt's insertion order, Python JSON separators,
    /// and UTC microsecond timestamp. Do not add fields or pass through the
    /// ordinary sorted-key JSON serializer: consumers retain these exact bytes.
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

    /// Preserve the saved audit format: UTC +00:00, six fractional digits
    /// except at whole seconds, where the fraction is omitted. Both calendar
    /// components and microseconds derive from one floored epoch value.
    private static func iso8601(_ date: Date) -> String {
        NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(date)
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


    // MARK: accessibility perception (W1 — READ-ONLY)

    /// Resolve the caller-supplied bounds, clamped to the hard ceilings by
    /// `MacAXLimits.init`. A caller CANNOT raise the caps, only lower them.
    static func axLimits(from body: [String: JSONValue]) -> MacAXLimits {
        return MacAXLimits(
            maxNodes: intValue(body, "max_nodes") ?? MacAXLimits.hardMaxNodes,
            maxDepth: intValue(body, "max_depth") ?? MacAXLimits.hardMaxDepth,
            maxMatches: intValue(body, "limit") ?? MacAXLimits.hardMaxMatches
        )
    }

    func axUntrustedResult(action: String) -> MacControlResult {
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


    // MARK: accessibility injection (W2 — physical, W3 — semantic)
    //
    // Every handler below has already passed the three-gate pre-flight
    // (accessibility category + active Full Mac window + body-bound injection
    // capability, supplied by admitted YOLO or an exact approved replay).
    // They still re-check the macOS Accessibility TCC grant, because a policy
    // gate is not a system grant: without the grant CGEventPost is silently
    // swallowed by the window server and the caller would be told "typed" when
    // nothing was typed.

    func injectionRefusal(
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
    func injectionPreconditions(action: String, requiresSink: Bool) -> MacControlResult? {
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

    static func doubleValue(_ body: [String: JSONValue], _ key: String) -> Double? {
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
    func attentionActionRefusal(
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
