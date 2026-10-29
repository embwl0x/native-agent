import CoreGraphics
import CoreMedia
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Senses
import Synchronization
// Blueprint: | `MacScreenWatch.swift` | One exact-window ScreenCaptureKit stream per part run, generation-bound frame queries and physical hands in same-owner extensions; person-only windows refused; each delivered frame awaits its complete secret-field inspection and masking; the newest pending capture survives inspection and its 500 ms interval and is inspected without another capture; incomplete inspection ends with an owned failure. Inspection work is retained; success and failure commit only while active, so expiry cancellation cannot cut admitted settlement short or create repair debt. Authority is checked at next/read/hand; window identity at each event. Terminal errors retain their cause; outside an enclosing act Experiences owns repair until an inspected frame from the same window/region arrives or it is let go. Duration stops capture and closes admission immediately; an admitted frame read or hand has up to 10s (the maximum hand duration) to settle before the retained frame and held input retire. Non-cooperative work retains its local frame until actual exit and cannot publish after retirement. Stop, window loss/resize, revocation, part change and takeover retire immediately. |

/// A part's eyes on one window for one run: one ScreenCaptureKit stream of
/// that window's own pixels, its newest frame and the one before copied into
/// buffers of its own, read in place. No frame byte leaves this object; a
/// part asks a frame questions and gets numbers and redacted text back. Its
/// hands turn frame pixels into screen points and go through the four verbs'
/// physical tail on one driver binding held for the whole watch, so the person's input
/// ends the watch and releases any key it holds.
public final class MacScreenWatch: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// What a part asks to watch: an app's front window (or a region of it, in
    /// window points), how often (`fps` 1...30) and for how long (at most 600 s).
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
            let fps = args["fps"].map(MacScreenWatch.number) ?? 10, seconds = args["seconds"].map(MacScreenWatch.number) ?? 60
            guard let fps, (1...30).contains(fps), fps.rounded() == fps else { throw bad("fps is a whole number from 1 to 30.") }
            guard let seconds, seconds > 0, seconds <= 600 else { throw bad("seconds is more than 0 and at most 600.") }
            if let raw = args["region"] {
                guard case .array(let values) = raw, values.count == 4, case let n = values.compactMap(MacScreenWatch.number),
                      n.count == 4, n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0 else {
                    throw bad("region is [x, y, w, h] in the window's points, from its top-left corner.")
                }
                region = MacAXFrame(x: n[0], y: n[1], w: n[2], h: n[3])
            } else { region = nil }
            self.app = app; self.fps = Int(fps); self.seconds = seconds
        }
    }

    /// The app door's way to open one for the part run it serves: its access,
    /// its sight, and hands built under the access it has at each hand.
    @TaskLocal public static var open: (@Sendable (Request, _ hands: Bool) async throws -> MacScreenWatch)?

    /// A refusal that is a receipt of its own: Screen control's card.
    public struct Refusal: Error, Sendable {
        public let receipt: JSONValue
        public init(receipt: JSONValue) { self.receipt = receipt }
    }

    /// One frame: its pixels (secret fields painted out), the window's own
    /// place on screen when it came, and the pixels of the frame before it.
    struct Frame {
        let seq: Int
        let at: Int
        let screen: MacAXFrame
        let pixels: [UInt8]
        let prior: [UInt8]?
    }

    /// Only the newest capture waits; its preceding inspection masks travel with it.
    struct Capture {
        let pixels: [UInt8]
        let window: MacAXFrame
        let preceding: [MacAXFrame]
        let at: Double
    }

    /// Ties a frame handle to the watch that made it: a replacement watch never answers an old one.
    public let generation: Int
    private static let generations = Mutex(0)
    public let width: Int
    public let height: Int
    let app: String
    private let dataRoot: URL
    private let enclosingAct = Experience.currentAct
    let pid: Int32
    let windowNumber: Int
    /// The window's size in points; a resize ends the watch, since frame pixels
    /// would then mean other places.
    private let size: (w: Double, h: Double)
    /// What the frames cover, in window points from its top-left corner.
    let region: MacAXFrame
    let sighting: MacFourVerbs.Sighting
    let verbs: (@Sendable () async throws -> MacFourVerbs)?
    /// Screen control still allowed: Full Mac active and the accessibility
    /// category on, as the four verbs read it.
    private let authority: @Sendable () async -> Bool
    let binding: MacDriverBinding?
    let started = ProcessInfo.processInfo.systemUptime
    fileprivate let queue = DispatchQueue(label: "nativeagent.screen.watch")
    let lock = NSLock()
    private var stream: SCStream?
    private var tasks: [Task<Void, Never>] = []
    var inspectionTask: Task<Void, Never>?
    private var settlementTask: Task<Void, Never>?
    var pending: Capture?
    var newest: Frame?
    var sequence = 0
    private var delivered = 0
    private var seen = 0
    var queries = 0
    var hands = 0
    private var window: MacAXFrame
    /// Password fields in window points from the latest complete inspection.
    var secrets: [MacAXFrame]?
    var inspected: Double
    var inspectedSuccessfully = false
    private var settledRepair = false
    /// Bumped whenever the secret fields change: a frame painted under older
    /// verdicts is never kept or published.
    var verdict = 0
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var ended: String?
    private var failure: SenseFailure?
    /// Duration closes capture and admission immediately. A read or hand already
    /// admitted has at most the maximum hand duration (10s) to settle. It then
    /// drops the retained frame and releases held input. Every other end is at once.
    var spent = false
    private var operations = 0

    /// How often the secret fields are read again while frames change: one
    /// whole-window AX walk, the desktop picture's index, costs tens to a few
    /// hundred milliseconds on a busy window, so it runs off the frame queue
    /// at most every 500 ms. Each deliverable frame waits for its own complete
    /// inspection; intervening captures replace the pending capture, which
    /// is inspected when due even if the window then stays static.
    static let inspectionInterval = 0.5
    static let inspectionBudget = 0.5

    fileprivate init(app: String, dataRoot: URL, pid: Int32, window: SCWindow, region: MacAXFrame, width: Int, height: Int,
                     sighting: MacFourVerbs.Sighting, verbs: (@Sendable () async throws -> MacFourVerbs)?,
                     authority: @escaping @Sendable () async -> Bool, binding: MacDriverBinding?) {
        let frame = MacAXFrame(x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height)
        generation = Self.generations.withLock { $0 += 1; return $0 }
        self.app = app; self.dataRoot = dataRoot; self.pid = pid; self.windowNumber = Int(window.windowID)
        self.window = frame; self.size = (frame.w, frame.h)
        self.region = region; self.width = width; self.height = height
        self.sighting = sighting; self.verbs = verbs; self.authority = authority; self.binding = binding
        secrets = nil
        inspected = started - Self.inspectionInterval
    }

    // MARK: Opening

    static func start(app: String, dataRoot: URL, pid: Int32, window frame: MacAXFrame, sighting: MacFourVerbs.Sighting, request: Request,
                      verbs: (@Sendable () async throws -> MacFourVerbs)?,
                      authority: @escaping @Sendable () async -> Bool) async throws -> MacScreenWatch {
        guard CGPreflightScreenCaptureAccess() else {
            throw SenseFailure(code: "screen_recording_not_trusted", message: "Screen Recording is off for NativeAgent. System Settings > Privacy & Security > Screen Recording > NativeAgent switch on.",
                               remedy: MacFourVerbsReply.privacyRemedy("screen_recording_not_trusted"))
        }
        let content: SCShareableContent = try await macScreenCaptureWait { receive in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true, completionHandler: receive)
        }
        // The window the sight described, by the same exact selection a one-shot capture uses.
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
            throw SenseFailure(code: "bad_input", message: "region lies outside \(app)'s window, which is \(Int(window.frame.width))×\(Int(window.frame.height)) points.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Native pixels, the long side at most 1024.
        let scale = min(max(1, Double(filter.pointPixelScale)), 1024 / max(region.w, region.h))
        let configuration = SCStreamConfiguration()
        if request.region != nil { configuration.sourceRect = CGRect(x: region.x, y: region.y, width: region.w, height: region.h) }
        configuration.width = max(1, Int((region.w * scale).rounded()))
        configuration.height = max(1, Int((region.h * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let binding = verbs == nil ? nil : await MacAttentionSessionStore.shared.bindDriver()
        let watch = MacScreenWatch(app: app, dataRoot: dataRoot, pid: pid, window: window, region: region, width: configuration.width,
                                   height: configuration.height, sighting: sighting, verbs: verbs, authority: authority, binding: binding)
        // Establish complete pre-capture masks before the stream's first frame.
        // A static window may supply only that one complete frame.
        let baseline = watch.lock.withLock { () -> Task<Void, Never> in
            let task = Task.detached {
                defer { watch.lock.withLock { watch.inspectionTask = nil } }
                watch.inspect(window: watch.window, pixels: nil, preceding: [], at: watch.started)
            }
            watch.inspectionTask = task
            return task
        }
        await withTaskCancellationHandler {
            await baseline.value
        } onCancel: { baseline.cancel(); watch.end("cancelled") }
        try Task.checkCancellation()
        if let failure = watch.over { throw failure }
        nonisolated(unsafe) let stream = SCStream(filter: filter, configuration: configuration, delegate: watch)
        do {
            try stream.addStreamOutput(watch, type: .screen, sampleHandlerQueue: watch.queue)
            watch.lock.withLock { watch.stream = stream }
            try await withTaskCancellationHandler {
                let _: Bool = try await macScreenCaptureWait { receive in
                    stream.startCapture { error in
                        // Cancellation may have retired the stream before its
                        // asynchronous start completed. Retire that late start too.
                        if watch.lock.withLock({ watch.ended != nil }) { stream.stopCapture { _ in } }
                        receive(true, error)
                    }
                }
            } onCancel: { watch.end("cancelled") }
            try Task.checkCancellation()
            guard watch.lock.withLock({ watch.ended == nil }) else {
                // A delegate failure can end the watch while startCapture suspends.
                stream.stopCapture { _ in }
                throw watch.over ?? CancellationError()
            }
        } catch {
            if error is CancellationError { watch.end("cancelled"); throw error }
            watch.end("capture_failed")
            throw watch.captureFailure("SCStream.startCapture", error.localizedDescription)
        }
        // The watch's own length, and the person's hands on the Mac (only a watch with
        // hands holds the driver: their input never ends a watch that only looks).
        var tasks = [Task { [weak watch] in
            guard (try? await Task.sleep(for: .seconds(request.seconds))) != nil else { return }
            watch?.spend()
        }]
        if let binding {
            tasks.append(Task { [weak watch] in
                for await _ in await MacAttentionSessionStore.shared.driverChanges() where !binding.allowsEmission {
                    watch?.end("taken_over")
                    return
                }
            })
        }
        let late = watch.lock.withLock { () -> [Task<Void, Never>] in
            guard watch.ended == nil else { return tasks }
            watch.tasks = tasks
            return []
        }
        late.forEach { $0.cancel() }
        return watch
    }

    /// What screen.watch answers: the frames' size and where they are.
    public var opened: JSONValue {
        lock.withLock {
            .object(["app": .string(app), "watch": .int(Int64(generation)), "width": .int(Int64(width)),
                     "height": .int(Int64(height)), "screen": place(window).toJSON()])
        }
    }

    /// What the frames cover, in screen points, with the window at `window`.
    func place(_ window: MacAXFrame) -> MacAXFrame {
        MacAXFrame(x: window.x + region.x, y: window.y + region.y, w: region.w, h: region.h)
    }

    /// The watched window's place now, by its number: one window-server read.
    private func currentWindow() -> MacAXFrame? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    }

    /// The window where it is now, or the watch ends: gone, or resized.
    func liveWindow() throws -> MacAXFrame {
        let now = currentWindow()
        guard let now, abs(now.w - size.w) < 1, abs(now.h - size.h) < 1 else {
            end(now == nil ? "window_gone" : "window_resized")
            throw over ?? SenseFailure(code: "watch_ended", message: "The watched window changed.")
        }
        lock.withLock { window = now }
        return now
    }

    /// Screen control still allowed, asked every time; when it is not, the
    /// watch ends ("authority_revoked").
    func allowed() async -> Bool {
        guard lock.withLock({ ended == nil }) else { return false }
        guard await authority() else { end("authority_revoked"); return false }
        return lock.withLock { ended == nil } && !Task.isCancelled
    }

    /// The newest frame not yet handed out, as soon as there is one (frames
    /// that came and went meanwhile are skipped, never queued); with
    /// `timeout`, `{timedOut: true}` when that many seconds pass without one.
    /// Null once the watch has ended.
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
            if let failure = lock.withLock({ failure }) { throw failure }
            if lock.withLock({ spent }) { return .null }
            _ = await allowed()
            try Task.checkCancellation()
            let answer = lock.withLock { () -> JSONValue? in
                if ended != nil || spent { return .null }
                if let frame = newest, frame.seq > delivered {
                    delivered = frame.seq; seen += 1
                    return .object(["watch": .int(Int64(generation)), "seq": .int(Int64(frame.seq)), "at": .int(Int64(frame.at)),
                                    "width": .int(Int64(width)), "height": .int(Int64(height)), "screen": frame.screen.toJSON()])
                }
                if let deadline, ContinuousClock.now >= deadline { return .object(["timedOut": .bool(true)]) }
                return nil
            }
            if let failure = lock.withLock({ failure }) { throw failure }
            if let answer {
                if case .object(let frame) = answer, case .int(let seq)? = frame["seq"], lock.withLock({
                    guard inspectedSuccessfully, !settledRepair, ended == nil else { return false }
                    settledRepair = true
                    return true
                }) {
                    // An inspected captured frame proves both app-wide grants.
                    // Window selection and capture races are corrections, not debts.
                    for owner in ["macOS Accessibility grant", "macOS Screen Recording grant"] {
                        RepairOwed.settle(dataRoot, operation: "screen.watch:" + owner,
                            evidence: .init(source: "screen.watch", id: "\(generation):\(seq)"))
                    }
                }
                return answer
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now = lock.withLock { () -> Bool in
                        guard ended == nil, !spent, (newest?.seq ?? 0) <= delivered, !Task.isCancelled,
                              deadline.map({ ContinuousClock.now < $0 }) ?? true else { return true }
                        waiters[id] = continuation
                        return false
                    }
                    if now { continuation.resume() }
                }
            } onCancel: { wake() }
        }
    }

    fileprivate func spend() {
        let (capture, idle) = lock.withLock { () -> (SCStream?, Bool) in
            guard ended == nil, !spent else { return (nil, false) }
            spent = true
            let capture = stream
            stream = nil
            inspectionTask?.cancel()
            pending = nil
            if operations > 0 {
                // One cleanup deadline, cancelled on actual settlement. A
                // non-cooperative read keeps only its local frame until exit;
                // it cannot publish after this deadline retires the watch.
                settlementTask = Task { [weak self] in
                    guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
                    self?.end("budget_spent")
                }
            }
            return (capture, operations == 0)
        }
        capture?.stopCapture { _ in }
        if idle { end("budget_spent") }
        wake()
    }

    private func wake() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        waiting.forEach { $0.resume() }
    }

    func admitOperation() -> Bool {
        lock.withLock {
            guard ended == nil, !spent, !Task.isCancelled else { return false }
            operations += 1
            return true
        }
    }

    func finishOperation() {
        let retire = lock.withLock { operations -= 1; return spent && operations == 0 }
        if retire { end("budget_spent") }
    }

    /// Why no hand goes out any more, once the watch has ended.
    var over: SenseFailure? {
        if let failure = lock.withLock({ failure }) { return failure }
        return lock.withLock { ended ?? (spent ? "budget_spent" : nil) }.map { reason in
            reason == "taken_over" ? SenseFailure(code: "taken_over", message: "The person took over; nothing more was sent.")
                : SenseFailure(code: "watch_ended", message: "The watch ended (\(reason)); call screen.watch again.")
        }
    }

    // MARK: Ending

    /// Ends the watch once, for the first reason given: the stream stops, its
    /// frames are dropped with every handle to them, held keys and buttons
    /// are released, and a waiting `next` answers null.
    public func end(_ reason: String, failure: SenseFailure? = nil) {
        let ending = lock.withLock { () -> (stream: SCStream?, waiters: [CheckedContinuation<Void, Never>], tasks: [Task<Void, Never>])? in
            guard ended == nil else { return nil }
            // An inspection failure belongs only to an active watch. Decide
            // under the retirement lock so expiry preserves admitted settlement.
            guard reason != "window_uninspected" || (!spent && !Task.isCancelled) else { return nil }
            ended = reason
            self.failure = failure
            defer { stream = nil; waiters.removeAll(); tasks = []; inspectionTask = nil; settlementTask = nil; pending = nil; newest = nil }
            return (stream, Array(waiters.values), tasks + [inspectionTask, settlementTask].compactMap { $0 })
        }
        guard let ending else { return }
        if enclosingAct == nil, let failure, case .object(let remedy)? = failure.remedy,
           remedy["kind"] == .string("repair"), case .string(let owner)? = remedy["owner"] {
            let tap: String? = if case .string(let value)? = remedy["tap"] { value } else { nil }
            RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .act, operation: "screen.watch:" + owner,
                owner: owner, words: failure.message, nextCall: remedy["next_call"].flatMap { try? $0.serialize(pretty: false) }, tap: tap)
        }
        ending.stream?.stopCapture { _ in }
        binding?.cancel()
        ending.tasks.forEach { $0.cancel() }
        ending.waiters.forEach { $0.resume() }
    }

    /// The watch's one receipt: frames seen and skipped, queries, hands, how it ended.
    public var summary: JSONValue {
        lock.withLock {
            let frames = sequence
            return .object(["app": .string(app), "frames": .int(Int64(frames)), "seen": .int(Int64(seen)),
                "skipped": .int(Int64(frames - seen)), "queries": .int(Int64(queries)), "hands": .int(Int64(hands)),
                "ended": .string(ended ?? "open"),
                "failure": failure.map { .string($0.message) } ?? .null,
                "remedy": failure?.remedy ?? .null,
                "seconds": .double(((ProcessInfo.processInfo.systemUptime - started) * 10).rounded() / 10)])
        }
    }

    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let n): Double(n)
        case .double(let n) where n.isFinite: n
        default: nil
        }
    }
}

extension MacFourVerbs {
    /// Opens a watch on `app`'s front window: the window this verb's own sight
    /// resolves (refusing what a sight refuses), streamed by exact identity.
    /// `hands` builds the verbs each hand runs on; nil watches without hands.
    /// `authority` answers whether screen control is still allowed.
    public func watch(_ request: MacScreenWatch.Request, dataRoot: URL, hands: (@Sendable () async throws -> MacFourVerbs)?,
                      authority: @escaping @Sendable () async -> Bool) async throws -> MacScreenWatch {
        let seen: Sighting
        switch await sight(part: nil, app: request.app) {
        case .blind(let reply):
            throw SenseFailure(code: Self.string(reply.detail["error"]) ?? "blind", message: reply.text, remedy: reply.detail["remedy"])
        case .seen(let sighting): seen = sighting
        }
        guard let pid = seen.pid, let frame = seen.windowFrame else {
            throw SenseFailure(code: "window_unavailable", message: "\(request.app) shows no window I can name to watch.")
        }
        return try await MacScreenWatch.start(app: seen.appName ?? request.app, dataRoot: dataRoot, pid: pid, window: frame,
                                              sighting: seen, request: request, verbs: hands, authority: authority)
    }
}
