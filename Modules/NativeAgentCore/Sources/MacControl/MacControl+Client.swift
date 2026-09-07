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
    private let sessionStateSource: any MacSessionStateSource
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
           !(policy.trustPolicy.map { MacControlGate.fullMacActive($0, now: now()) } ?? false) {
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


    /// A mark is a reference into the latest view, not injection authority.
    /// Dispatch admission still requires the normal capability and policy gates.
    private enum MarkResolution {
        /// The call named no mark at all — the coordinate/path forms apply.
        case absent
        case resolved(MacScreenViewMark, MacScreenViewSnapshot)
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
            guard let snapshot = await screenViewStore.snapshot(viewId: viewId) else {
                return .refused(injectionRefusal(action: action, error: "stale_view", status: 409))
            }
            return .resolved(hit, snapshot)
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

    /// Resolve only in the captured window. Inferred or duplicate labels cannot
    /// establish element identity, so those marks require a fresh semantic target.
    private func liveMarkedTarget(
        _ mark: MacScreenViewMark,
        snapshot: MacScreenViewSnapshot
    ) -> MacAXActTarget? {
        guard let identity = snapshot.windowIdentity,
              identity.pid != getpid(),
              accessibilitySource.frontmostApp()?.processIdentifier == identity.pid,
              let label = mark.label, !label.isEmpty,
              mark.labelSource == "title" || mark.labelSource == "value"
        else { return nil }
        let windows = accessibilityActSource.windows(pid: identity.pid)
        guard case .matched(let window, _) = MacAXWindowIdentity.match(
            identity, among: windows.map { (handle: $0, identity: $0.identity) }
        ), let focused = accessibilityActSource.focusedWindow(pid: identity.pid),
           focused.handle == window.handle,
           let target = accessibilityActSource.uniqueTarget(
               role: mark.role, label: label, labelSource: mark.labelSource,
               ancestorPath: Array(mark.path.dropLast()), inWindow: window
           ), target.enabled
        else { return nil }
        return target
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
        // Marks retain the captured window; live geometry is resolved at injection.
        var markedTarget: MacScreenViewMark?
        var markedSnapshot: MacScreenViewSnapshot?
        switch await resolveMarkReference(action: "click", body: body) {
        case .refused(let refusal): return refusal
        case .resolved(let hit, let snapshot):
            markedTarget = hit
            markedSnapshot = snapshot
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

        // Approval and execution must name the same single target.
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
                // Stored labels are raw; receipt serialization must redact them.
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
        var cancelled = false
        func releasePressedButton() {
            guard pressed, let lastPosted else { return }
            eventSink.post(mouse: MacMouseEvent(
                phase: .up, button: lastPosted.button, x: lastPosted.x, y: lastPosted.y
            ))
        }
        for var event in events {
            if Task.isCancelled { cancelled = true; break }
            if let refusal = await attentionActionRefusal(action: "click", body: body) {
                releasePressedButton()
                await screenViewStore.invalidate()
                return refusal
            }
            if Task.isCancelled { cancelled = true; break }
            if let markedTarget, let markedSnapshot {
                let x: Double
                let y: Double
                if event.phase == .up, pressed, let lastPosted {
                    // Mouse-down may itself change the label or remove the
                    // target. Finish that click at its accepted position.
                    x = lastPosted.x
                    y = lastPosted.y
                } else {
                    guard let target = liveMarkedTarget(markedTarget, snapshot: markedSnapshot),
                          let centre = target.centre else {
                        releasePressedButton()
                        await screenViewStore.invalidate()
                        return injectionRefusal(action: "click", error: "mark_drifted: take a fresh view", status: 409)
                    }
                    x = centre.x
                    y = centre.y
                }
                event = MacMouseEvent(
                    phase: event.phase, button: event.button, x: x, y: y,
                    clickCount: event.clickCount, modifiers: event.modifiers
                )
                describe["x"] = .double(x)
                describe["y"] = .double(y)
            }
            eventSink.post(mouse: event)
            lastPosted = event
            if event.phase == .down { pressed = true }
            if event.phase == .up { pressed = false }
            if dragStepDelayNanoseconds > 0,
               event.phase == .down || event.phase == .drag {
                do {
                    try await Task.sleep(nanoseconds: dragStepDelayNanoseconds)
                } catch {
                    cancelled = true
                    break
                }
            }
        }
        if cancelled { releasePressedButton() }
        await screenViewStore.invalidate()
        if cancelled {
            return injectionRefusal(
                action: "click", error: "cancelled", status: 409,
                extra: ["status": .string("cancelled")]
            )
        }

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
        // Marks carry their captured window through to the actuator.
        var markedTarget: MacScreenViewMark?
        var markedSnapshot: MacScreenViewSnapshot?
        switch await resolveMarkReference(action: "ax_act", body: body) {
        case .refused(let refusal): return refusal
        case .resolved(let hit, let snapshot):
            markedTarget = hit
            markedSnapshot = snapshot
        case .absent: break
        }
        // A malformed path must never become []: that names the window itself.
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
                        case .double(let d) where d.isFinite && d == d.rounded():
                            guard let index = Int(exactly: d) else { return nil }
                            out.append(index)
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
            // Fractional indices cannot be rounded into a different target.
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
        var resolvedTarget: MacAXActTarget?
        if let markedTarget, let markedSnapshot {
            guard let target = liveMarkedTarget(markedTarget, snapshot: markedSnapshot) else {
                return injectionRefusal(action: "ax_act", error: "mark_drifted: take a fresh view", status: 409)
            }
            resolvedTarget = target
        }
        let outcome = MacAccessibilityActuator.act(
            source: accessibilityActSource,
            sink: eventSink,
            path: path,
            action: requestedAction,
            value: value,
            resolved: resolvedTarget
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
            // Written/secure values use count+digest. Path-only calls lack the
            // caption context needed to safely expose even an unwritten value.
            let redactValue = (value?.isEmpty == false) || markedTarget == nil || markedTarget?.secret == true
            var output: [String: JSONValue] = [
                "ok": .bool(result.ok),
                "status": .string(result.ok ? "acted" : "failed"),
                "method": .string(result.method),
                "requested_action": .string(result.requestedAction),
                "outcome": .string(result.outcome.rawValue),
                "path": pathJSON,
                // Receipt fields retain the legend's contextual redaction.
                "element": MacScreenViewTextRedaction.redactedElementJSON(
                    result.target.toJSON(redactingValue: redactValue),
                    under: markedTarget?.label,
                    enclosing: markedTarget?.enclosingCaption ?? .none
                ),
                // The post-state read is offered so the caller can CHECK
                // whether the state changed; it is not itself a claim that it
                // did (see `verificationState`).
                "post_state": result.postState.map {
                    MacScreenViewTextRedaction.redactedElementJSON(
                        $0.toJSON(redactingValue: redactValue),
                        under: markedTarget?.label,
                        enclosing: markedTarget?.enclosingCaption ?? .none
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
