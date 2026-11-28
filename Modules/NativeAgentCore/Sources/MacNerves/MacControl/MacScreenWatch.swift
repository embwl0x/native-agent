import Dispatch
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SenseCore
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Synchronization
// Blueprint: | `MacScreenWatch.swift` | Exact-window stream; complete secret masks precede publication; bounded settlement and immediate takeover |

/// Keep frame pixels local; queries return only numbers and redacted text. One driver binding spans the watch, so person input ends its hands and releases held
/// keys.
public final class MacScreenWatch: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    /// Bound watch duration and frame rate to one selected window or region.
    public struct Request: Sendable {
        public let app: String
        public let fps: Int
        public let seconds: Double
        public let region: MacAXFrame?

        public init(_ args: [String: JSONValue]) throws {
            func bad(_ detail: String) -> SenseFailure { SenseFailure(code: "bad_input", message: detail) }
            guard args.keys.allSatisfy(["app", "fps", "seconds", "region"].contains) else {
                throw bad("screen.watch takes app, and optionally fps, seconds and region.")
            }
            guard case .string(let app)? = args["app"], !app.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw bad("app names the app whose front window to watch.")
            }
            // Only missing settings take defaults. Supplied values still have to pass the guards below.
            let fps = args["fps"].map { $0.finiteDoubleValue } ?? 10
            let seconds = args["seconds"].map { $0.finiteDoubleValue } ?? 60
            guard let fps, (1...30).contains(fps), fps.rounded() == fps else { throw bad("fps is a whole number from 1 to 30.") }
            guard let seconds, seconds > 0, seconds <= 600 else { throw bad("seconds is more than 0 and at most 600.") }
            if let raw = args["region"] {
                guard case .array(let values) = raw, values.count == 4, case let n = values.compactMap(\.finiteDoubleValue),
                      n.count == 4, n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0 else {
                    throw bad("region is [x, y, w, h] in the window's points, from its top-left corner.")
                }
                region = MacAXFrame(x: n[0], y: n[1], w: n[2], h: n[3])
            } else { region = nil }
            self.app = app; self.fps = Int(fps); self.seconds = seconds
        }
    }

    /// Retain Screen control’s refusal card as the receipt.
    public struct Refusal: Error, Sendable {
        public let receipt: JSONValue
        public init(receipt: JSONValue) { self.receipt = receipt }
    }

    /// Each frame retains masked pixels, observed window placement and the preceding pixels for comparisons.
    struct Frame {
        let seq: Int
        let at: Int
        let screen: MacAXFrame
        let pixels: [UInt8]
        let prior: [UInt8]?
    }

    struct Capture: Sendable {
        let buffer: MacScreenCaptureValue<CVPixelBuffer>
        let window: MacAXFrame
        let at: Double
    }

    /// Bind handles to their originating watch so replacements cannot answer old frame ids.
    public let generation: Int
    private static let generations = Mutex(0)
    public let width: Int
    public let height: Int
    let app: String
    private let dataRoot: URL
    public var handRefusal: MacAppActRefusal? { MacAppActGate.refusal(pid: pid, dataRoot: dataRoot, context: context) }
    let turn: Turn
    let context: MacOperationContext
    let pid: Int32
    let windowNumber: Int
    /// Resize ends the watch because existing pixel coordinates would address different places.
    private let size: (w: Double, h: Double)
    /// Region bounds stay relative to the watched window’s top-left corner.
    let region: MacAXFrame
    let sighting: MacFourVerbs.Sighting
    let verbs: (@Sendable () async throws -> MacFourVerbs)?
    /// Watch admission must use the four verbs’ current Full Mac and accessibility-category authority.
    private let authority: @Sendable () async throws -> Bool
    let binding: MacDriverBinding?
    let started = ProcessInfo.processInfo.systemUptime
    fileprivate let queue = DispatchQueue(label: "nativeagent.screen.watch")
    struct State: Sendable {
        var stopCapture: (@Sendable () -> Void)?
        var tasks: [Task<Void, Never>] = []
        var inspectionTask: Task<Void, Never>?
        var settlementTask: Task<Void, Never>?
        var pending: Capture?
        var newest: Frame?
        var sequence = 0
        var delivered = 0
        var seen = 0
        var queries = 0
        var hands = 0
        var window: MacAXFrame
        var secrets: [MacAXFrame]?
        var frameMasks = Set<MacAXFrame>()
        var inspected: Double
        var inspectedSuccessfully = false
        var settledRepair = false
        var verdict = 0
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var ended: String?
        var failure: SenseFailure?
        var spent = false
        var operations = 0
    }
    let state: Mutex<State>

    /// Whole-window AX inspection is costly, so coalesce it off the frame queue at 500 ms intervals. Every deliverable frame awaits its own complete
    /// inspection, including pending captures after the window becomes static.
    static let inspectionInterval = 0.5
    static let inspectionBudget = 0.5

    fileprivate init(app: String, dataRoot: URL, pid: Int32, window: SCWindow, region: MacAXFrame, width: Int, height: Int,
                     sighting: MacFourVerbs.Sighting, verbs: (@Sendable () async throws -> MacFourVerbs)?,
                     authority: @escaping @Sendable () async throws -> Bool, binding: MacDriverBinding?, turn: Turn, context: MacOperationContext) {
        let frame = MacAXFrame(x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height)
        self.turn = turn
        self.context = context
        generation = Self.generations.withLock { $0 += 1; return $0 }
        self.app = app; self.dataRoot = dataRoot; self.pid = pid; self.windowNumber = Int(window.windowID)
        self.size = (frame.w, frame.h)
        self.region = region; self.width = width; self.height = height
        self.sighting = sighting; self.verbs = verbs; self.authority = authority; self.binding = binding
        state = Mutex(State(window: frame, inspected: started - Self.inspectionInterval))
    }

    // MARK: Opening

    @concurrent static func start(app: String, dataRoot: URL, pid: Int32, window frame: MacAXFrame, sighting: MacFourVerbs.Sighting, request: Request,
                      verbs: (@Sendable () async throws -> MacFourVerbs)?,
                      turn: Turn, context: MacOperationContext, authority: @escaping @Sendable () async throws -> Bool) async throws -> MacScreenWatch {
        guard !PersonOnlyWindows.isOwnProcess(pid) else {
            throw SenseFailure(code: "person_only_window", message: "NativeAgent's own window is person-only; use app pages to read its state.")
        }
        guard SystemPermissionPreflight.heldByThisProcess(.screenRecording) else {
            throw SenseFailure(code: "screen_recording_not_trusted",
                message: "Screen Recording is off for NativeAgent. System Settings > Privacy & Security > Screen Recording > NativeAgent switch on.",
                               remedy: MacFourVerbsReply.privacyRemedy("screen_recording_not_trusted"))
        }
        let content: SCShareableContent = try await macScreenCaptureWait(context: context) { receive in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true, completionHandler: receive)
        }
        // Retain the sight’s exact window selection for capture.
        let windows = content.windows
        guard let number = MacScreenCaptureWindowSelection.selectedID(windows: windows.compactMap { window in
                  window.owningApplication.map { (window.windowID, $0.processID, MacAXFrame(
                      x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height)) }
              }, requested: MacAXWindowIdentity(pid: pid, index: nil, role: "AXWindow", frame: frame)),
              let window = windows.first(where: { $0.windowID == number }) else {
            throw SenseFailure(code: "window_unavailable", message: "I can't single out \(app)'s front window to watch; bring it on screen and try again.")
        }
        guard !PersonOnlyWindows.contains(number: Int(number)) else {
            throw SenseFailure(code: "person_only_window", message: "That window is the person's own; I don't watch it.")
        }
        let region = request.region ?? MacAXFrame(x: 0, y: 0, w: window.frame.width, h: window.frame.height)
        guard region.x + region.w <= window.frame.width, region.y + region.h <= window.frame.height else {
            throw SenseFailure(code: "bad_input",
                message: "region lies outside \(app)'s window, which is \(Int(window.frame.width))×\(Int(window.frame.height)) points.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Bound the long edge to 1024 native pixels.
        let scale = min(max(1, Double(filter.pointPixelScale)), 1024 / max(region.w, region.h))
        let configuration = SCStreamConfiguration()
        if request.region != nil { configuration.sourceRect = CGRect(x: region.x, y: region.y, width: region.w, height: region.h) }
        configuration.width = max(1, Int((region.w * scale).rounded()))
        configuration.height = max(1, Int((region.h * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let binding = verbs == nil ? nil : try await MacAttentionSessionStore.shared.bindDriver()
        let watch = MacScreenWatch(app: app, dataRoot: dataRoot, pid: pid, window: window, region: region, width: configuration.width, height: configuration
            .height, sighting: sighting, verbs: verbs, authority: authority, binding: binding, turn: turn, context: context)
        // Inspect before starting capture because static windows may never produce a second frame.
        let baseline = watch.state.withLock { state -> Task<Void, Never> in
            let initialWindow = state.window
            let task = Task.detached {
                defer { watch.state.withLock { $0.inspectionTask = nil } }
                watch.inspect(window: initialWindow, buffer: nil, at: watch.started)
            }
            state.inspectionTask = task
            return task
        }
        await withTaskCancellationHandler {
            await baseline.value
        } onCancel: { baseline.cancel(); watch.end("cancelled") }
        try Task.checkCancellation()
        if let failure = watch.over { throw failure }
        nonisolated(unsafe) let stream = SCStream(filter: filter, configuration: configuration, delegate: watch)
        do {
            try unsafe stream.addStreamOutput(watch, type: .screen, sampleHandlerQueue: watch.queue)
            watch.state.withLock { $0.stopCapture = { unsafe stream.stopCapture { _ in } } }
            try await withTaskCancellationHandler {
                let _: Bool = try await macScreenCaptureWait(context: context) { receive in
                    unsafe stream.startCapture { error in
                        // Cancellation may have retired the stream before its asynchronous start completed. Retire that late start too.
                        if watch.state.withLock({ $0.ended != nil }) { unsafe stream.stopCapture { _ in } }
                        receive(true, error)
                    }
                }
            } onCancel: { watch.end("cancelled") }
            try Task.checkCancellation()
            guard watch.state.withLock({ $0.ended == nil }) else {
                // A delegate failure can end the watch while startCapture suspends.
                unsafe stream.stopCapture { _ in }
                throw watch.over ?? CancellationError()
            }
        } catch {
            if error is CancellationError { watch.end("cancelled"); throw error }
            watch.end("capture_failed")
            throw watch.captureFailure("SCStream.startCapture", error.localizedDescription)
        }
        // Only hands hold the driver, so person input ends interactive watches but not read-only watches.
        var tasks = [Task { [weak watch] in
            guard (try? await Task.sleep(for: .seconds(request.seconds))) != nil else { return }
            watch?.spend()
        }]
        if let binding {
            tasks.append(Task { [weak watch] in
                for await _ in await MacAttentionSessionStore.shared.driverChanges() where !binding.allowsEmission(context: context) {
                    watch?.end("taken_over")
                    return
                }
            })
        }
        let late = watch.state.withLock { state -> [Task<Void, Never>] in
            guard state.ended == nil else { return tasks }
            state.tasks = tasks
            return []
        }
        late.forEach { $0.cancel() }
        return watch
    }

    public var opened: JSONValue {
        state.withLock { state in
            .object(["app": .string(app), "watch": .int(Int64(generation)), "width": .int(Int64(width)),
                     "height": .int(Int64(height)), "screen": place(state.window).toJSON()])
        }
    }

    /// Place frame coverage using the window’s current observed position.
    func place(_ window: MacAXFrame) -> MacAXFrame {
        MacAXFrame(x: window.x + region.x, y: window.y + region.y, w: region.w, h: region.h)
    }

    /// Resolve current placement by window number, never a sibling’s geometry.
    private func currentWindow() -> MacAXFrame? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    }

    /// A gone or resized window invalidates pixel addressing and ends the watch.
    func liveWindow() throws -> MacAXFrame {
        let now = currentWindow()
        guard let now, abs(now.w - size.w) < 1, abs(now.h - size.h) < 1 else {
            end(now == nil ? "window_gone" : "window_resized")
            throw over ?? SenseFailure(code: "watch_ended", message: "The watched window changed.")
        }
        state.withLock { $0.window = now }
        return now
    }

    /// Recheck screen authority on each admission; revocation ends the watch.
    func allowed() async -> Bool {
        guard state.withLock({ $0.ended == nil }) else { return false }
        do {
            guard try await authority() else { end("authority_revoked"); return false }
        } catch {
            end("authority_unavailable", failure: SenseFailure(error))
            return false
        }
        return state.withLock { $0.ended == nil } && !Task.isCancelled
    }

    package struct AXQueryScope: Sendable, Equatable {
        let pid: Int32
        let window: MacAXFrame
        let region: MacAXFrame
        let identity: MacAXNativeElementIdentity
        let masks: Set<MacAXFrame>
    }

    package var axQueryBundleID: String? { sighting.bundleIdentifier }
    package var axQueryActive: Bool { state.withLock { $0.ended == nil && !$0.spent } }

    package func axQueryScope() async -> AXQueryScope? {
        guard let identity = sighting.window?.nativeWindow, await allowed(), axQueryActive,
              let window = currentWindow(), abs(window.w - size.w) < 1, abs(window.h - size.h) < 1 else { return nil }
        guard let masks = state.withLock({ state in
            state.ended == nil && !state.spent && state.inspectedSuccessfully ? state.frameMasks : nil
        }) else { return nil }
        return AXQueryScope(pid: pid, window: window, region: place(window), identity: identity,
            masks: Set(masks.map { MacAXFrame(x: window.x + $0.x, y: window.y + $0.y, w: $0.w, h: $0.h) }))
    }

    /// Skip intermediate captures rather than queueing them; next times out explicitly, and watch end returns null.
    public func next(timeout: Double?) async throws -> JSONValue {
        let id = UUID()
        let deadline = timeout.map { ContinuousClock.now.advanced(by: .seconds(max(0, $0))) }
        let timer = deadline.map { deadline in Task { [weak self] in
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            self?.wake()
        } }
        defer { timer?.cancel() }
        while true {
            try Task.checkCancellation()
            if let failure = state.withLock({ $0.failure }) { throw failure }
            if state.withLock({ $0.spent }) { return .null }
            _ = await allowed()
            if let failure = state.withLock({ $0.failure }) { throw failure }
            try Task.checkCancellation()
            let answer = state.withLock { state -> JSONValue? in
                if state.ended != nil || state.spent { return .null }
                if let frame = state.newest, frame.seq > state.delivered {
                    state.delivered = frame.seq; state.seen += 1
                    return .object(["watch": .int(Int64(generation)), "seq": .int(Int64(frame.seq)), "at": .int(Int64(frame.at)),
                                    "width": .int(Int64(width)), "height": .int(Int64(height)), "screen": frame.screen.toJSON()])
                }
                if let deadline, ContinuousClock.now >= deadline { return .object(["timedOut": .bool(true)]) }
                return nil
            }
            if let failure = state.withLock({ $0.failure }) { throw failure }
            if let answer {
                if case .object(let frame) = answer, case .int(let seq)? = frame["seq"], state.withLock({ state in
                    guard state.inspectedSuccessfully, !state.settledRepair, state.ended == nil else { return false }
                    state.settledRepair = true
                    return true
                }) {
                    // Inspected capture proves both grants; window-selection and capture races need correction rather than permission debt.
                    for owner in ["macOS Accessibility grant", "macOS Screen Recording grant"] {
                        RepairOwed.settle(dataRoot, operation: "screen.watch:" + owner,
                            evidence: .init(source: "screen.watch", id: "\(generation):\(seq)"))
                    }
                }
                return answer
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now = state.withLock { state -> Bool in
                        guard state.ended == nil, !state.spent, (state.newest?.seq ?? 0) <= state.delivered, !Task.isCancelled,
                              deadline.map({ ContinuousClock.now < $0 }) ?? true else { return true }
                        state.waiters[id] = continuation
                        return false
                    }
                    if now { continuation.resume() }
                }
            } onCancel: { wake() }
        }
    }

    fileprivate func spend() {
        let (stopCapture, idle) = state.withLock { state -> ((@Sendable () -> Void)?, Bool) in
            guard state.ended == nil, !state.spent else { return (nil, false) }
            state.spent = true
            let stopCapture = state.stopCapture.take()
            state.inspectionTask?.cancel()
            state.pending = nil
            if state.operations > 0 {
                // One cleanup deadline bounds settlement; non-cooperative reads retain only local frames and cannot publish after retirement.
                state.settlementTask = Task { [weak self] in
                    guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
                    self?.end("budget_spent")
                }
            }
            return (stopCapture, state.operations == 0)
        }
        stopCapture?()
        if idle { end("budget_spent") }
        wake()
    }

    private func wake() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        waiting.forEach { $0.resume() }
    }

    func admitOperation() -> Bool {
        state.withLock { state in
            guard state.ended == nil, !state.spent, !Task.isCancelled else { return false }
            state.operations += 1
            return true
        }
    }

    func finishOperation() {
        let retire = state.withLock { $0.operations -= 1; return $0.spent && $0.operations == 0 }
        if retire { end("budget_spent") }
    }

    /// Retain the terminal reason so later hands explain their refusal.
    var over: SenseFailure? {
        if let failure = state.withLock({ $0.failure }) { return failure }
        return state.withLock { $0.ended ?? ($0.spent ? "budget_spent" : nil) }.map { reason in
            reason == "taken_over" ? SenseFailure(code: "taken_over", message: "The person took over; nothing more was sent.")
                : SenseFailure(code: "watch_ended", message: "The watch ended (\(reason)); call screen.watch again.")
        }
    }

    // MARK: Ending

    /// First termination wins: drop frames and handles, release held input, stop streaming and wake next with null.
    public func end(_ reason: String, failure: SenseFailure? = nil) {
        let ending = state.withLock { state -> (stopCapture: (@Sendable () -> Void)?, waiters: [CheckedContinuation<Void, Never>], tasks: [Task<Void, Never>])? in
            guard state.ended == nil else { return nil }
            // Decide inspection failure under the retirement lock so expired watches retain admitted settlement.
            guard reason != "window_uninspected" || (!state.spent && !Task.isCancelled) else { return nil }
            state.ended = reason
            state.failure = failure
            defer {
                state.stopCapture = nil
                state.waiters.removeAll()
                state.tasks = []
                state.inspectionTask = nil
                state.settlementTask = nil
                state.pending = nil
                state.newest = nil
            }
            return (state.stopCapture, Array(state.waiters.values), state.tasks + [state.inspectionTask, state.settlementTask].compactMap { $0 })
        }
        guard let ending else { return }
        // Every watch now serves its held Turn. Its retained failure is returned through
        // next/hand to that turn's owner; there is no ambient "no enclosing act" branch.
        ending.stopCapture?()
        binding?.cancel()
        ending.tasks.forEach { $0.cancel() }
        ending.waiters.forEach { $0.resume() }
    }

    /// One receipt accounts for frames, queries, hands and the termination reason.
    public var summary: JSONValue {
        state.withLock { state in
            let frames = state.sequence
            return .object(["app": .string(app), "frames": .int(Int64(frames)), "seen": .int(Int64(state.seen)),
                "skipped": .int(Int64(frames - state.seen)), "queries": .int(Int64(state.queries)), "hands": .int(Int64(state.hands)),
                "ended": .string(state.ended ?? "open"),
                "failure": state.failure.map { .string($0.message) } ?? .null,
                "remedy": state.failure?.remedy ?? .null,
                "seconds": .double(((ProcessInfo.processInfo.systemUptime - started) * 10).rounded() / 10)])
        }
    }
}

extension MacFourVerbs {
    /// Open only the sight’s exact window under its admission; nil hands remain read-only and authority is rechecked.
    public func watch(_ request: MacScreenWatch.Request, dataRoot: URL, hands: (@Sendable () async throws -> MacFourVerbs)?,
                      turn: Turn, context: MacOperationContext, authority: @escaping @Sendable () async throws -> Bool) async throws -> MacScreenWatch {
        let seen: Sighting
        switch await sight(part: nil, app: request.app, turn: turn, context: context) {
        case .blind(let reply):
            throw SenseFailure(code: Self.string(reply.detail["error"]) ?? "blind", message: reply.text, remedy: reply.detail["remedy"])
        case .seen(let sighting): seen = sighting
        }
        guard let pid = seen.pid, let frame = seen.windowFrame else {
            throw SenseFailure(code: "window_unavailable", message: "\(request.app) shows no window I can name to watch.")
        }
        return try await MacScreenWatch.start(app: seen.appName ?? request.app, dataRoot: dataRoot, pid: pid, window: frame, sighting: seen, request: request,
            verbs: hands, turn: turn, context: context, authority: authority)
    }
}
