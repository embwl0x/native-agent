import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Senses
import Synchronization
// Blueprint: | `MacScreenWatch.swift` | One exact-window ScreenCaptureKit stream per part run, generation-bound frame queries and physical hands; person-only windows refused, secret fields inspected every 500 ms and painted out, incomplete inspection ends with an owned failure. Inspection work is retained; success and failure commit only while active, so expiry cancellation cannot cut admitted settlement short or create repair debt. Authority is checked at next/read/hand; window identity at each event. Terminal errors retain their cause; outside an enclosing act Experiences owns repair until an inspected frame from the same window/region arrives or it is let go. Duration stops capture and closes admission immediately; an admitted frame read or hand has up to 10s (the maximum hand duration) to settle before the retained frame and held input retire. Non-cooperative work retains its local frame until actual exit and cannot publish after retirement. Stop, window loss/resize, revocation, part change and takeover retire immediately. |

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
    private struct Frame {
        let seq: Int
        let at: Int
        let screen: MacAXFrame
        let pixels: [UInt8]
        let prior: [UInt8]?
    }

    /// Ties a frame handle to the watch that made it: a replacement watch never answers an old one.
    public let generation: Int
    private static let generations = Mutex(0)
    public let width: Int
    public let height: Int
    private let app: String
    private let dataRoot: URL
    private let enclosingAct = Experience.currentAct
    private let pid: Int32
    private let windowNumber: Int
    /// The window's size in points; a resize ends the watch, since frame pixels
    /// would then mean other places.
    private let size: (w: Double, h: Double)
    /// What the frames cover, in window points from its top-left corner.
    private let region: MacAXFrame
    private let sighting: MacFourVerbs.Sighting
    private let verbs: (@Sendable () async throws -> MacFourVerbs)?
    /// Screen control still allowed: Full Mac active and the accessibility
    /// category on, as the four verbs read it.
    private let authority: @Sendable () async -> Bool
    private let binding: MacDriverBinding?
    private let started = ProcessInfo.processInfo.systemUptime
    fileprivate let queue = DispatchQueue(label: "nativeagent.screen.watch")
    private let lock = NSLock()
    private var stream: SCStream?
    private var tasks: [Task<Void, Never>] = []
    private var inspectionTask: Task<Void, Never>?
    private var settlementTask: Task<Void, Never>?
    private var newest: Frame?
    private var sequence = 0
    private var delivered = 0
    private var seen = 0
    private var queries = 0
    private var hands = 0
    private var window: MacAXFrame
    /// Password fields in window points from the latest complete inspection.
    private var secrets: [MacAXFrame]?
    private var inspected: Double
    private var inspecting = false
    private var inspectedSuccessfully = false
    private var settledRepair = false
    /// Bumped whenever the secret fields change: a frame painted under older
    /// verdicts is never kept or published.
    private var verdict = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var ended: String?
    private var failure: SenseFailure?
    /// Duration closes capture and admission immediately. A read or hand already
    /// admitted has at most the maximum hand duration (10s) to settle. It then
    /// drops the retained frame and releases held input. Every other end is at once.
    private var spent = false
    private var operations = 0

    /// How often the secret fields are read again while frames change: one
    /// whole-window AX walk, the desktop picture's index, costs tens to a few
    /// hundred milliseconds on a busy window, so it runs off the frame queue
    /// at most every 500 ms (a field that scrolls in stays bare at most that
    /// long plus its walk, bounded by `inspectionBudget`).
    private static let inspectionInterval = 0.5
    private static let inspectionBudget = 0.5

    fileprivate init(app: String, dataRoot: URL, pid: Int32, window: SCWindow, region: MacAXFrame, width: Int, height: Int,
                     sighting: MacFourVerbs.Sighting, verbs: (@Sendable () async throws -> MacFourVerbs)?,
                     authority: @escaping @Sendable () async -> Bool, binding: MacDriverBinding?) {
        let frame = MacAXFrame(x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height)
        let origin = sighting.windowFrame ?? frame
        generation = Self.generations.withLock { $0 += 1; return $0 }
        self.app = app; self.dataRoot = dataRoot; self.pid = pid; self.windowNumber = Int(window.windowID)
        self.window = frame; self.size = (frame.w, frame.h)
        self.region = region; self.width = width; self.height = height
        self.sighting = sighting; self.verbs = verbs; self.authority = authority; self.binding = binding
        // The opening sight's verdicts until the first inspection lands.
        secrets = sighting.targets.filter(\.secret).compactMap(\.frame)
            .map { MacAXFrame(x: $0.x - origin.x, y: $0.y - origin.y, w: $0.w, h: $0.h) }
        inspected = started
    }

    // MARK: Opening

    static func start(app: String, dataRoot: URL, pid: Int32, window frame: MacAXFrame, sighting: MacFourVerbs.Sighting, request: Request,
                      verbs: (@Sendable () async throws -> MacFourVerbs)?,
                      authority: @escaping @Sendable () async -> Bool) async throws -> MacScreenWatch {
        guard CGPreflightScreenCaptureAccess() else {
            throw SenseFailure(code: "screen_recording_not_trusted", message: "Screen Recording is off for NativeAgent. System Settings > Privacy & Security > Screen Recording > NativeAgent switch on.",
                               remedy: MacFourVerbsReply.privacyRemedy("screen_recording_not_trusted"))
        }
        let content: SCShareableContent = try await macScreenCaptureWait { request in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                request.receive(content, error)
            }
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
        nonisolated(unsafe) let stream = SCStream(filter: filter, configuration: configuration, delegate: watch)
        do {
            try stream.addStreamOutput(watch, type: .screen, sampleHandlerQueue: watch.queue)
            watch.lock.withLock { watch.stream = stream }
            try await withTaskCancellationHandler {
                let _: Bool = try await macScreenCaptureWait { request in
                    stream.startCapture { error in
                        // Cancellation may have retired the stream before its
                        // asynchronous start completed. Retire that late start too.
                        if watch.lock.withLock({ watch.ended != nil }) { stream.stopCapture { _ in } }
                        request.receive(true, error)
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
    private func place(_ window: MacAXFrame) -> MacAXFrame {
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
    private func liveWindow() throws -> MacAXFrame {
        let now = currentWindow()
        guard let now, abs(now.w - size.w) < 1, abs(now.h - size.h) < 1 else {
            end(now == nil ? "window_gone" : "window_resized")
            throw over ?? SenseFailure(code: "watch_ended", message: "The watched window changed.")
        }
        lock.withLock { window = now }
        return now
    }

    // MARK: Frames

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard lock.withLock({ ended == nil && !spent }), type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .stopped { end("window_gone"); return }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { end("frame_size_changed"); return }
        guard let window = try? liveWindow() else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = CVPixelBufferGetBytesPerRow(buffer), line = width * 4
        var pixels = [UInt8](repeating: 0, count: line * height)
        pixels.withUnsafeMutableBytes { out in
            for y in 0..<height { memcpy(out.baseAddress! + y * line, base + y * row, line) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let (secrets, painted, inspect) = lock.withLock { () -> ([MacAXFrame]?, Int, Bool) in
            let due = !inspecting && now - inspected >= Self.inspectionInterval
            if due { inspecting = true; inspected = now }
            return (self.secrets, verdict, due)
        }
        if inspect {
            lock.withLock {
                guard ended == nil, !spent else { return }
                inspectionTask = Task.detached { [weak self] in self?.inspect(window: window) }
            }
        }
        guard let secrets else { return }
        let geometry = MacScreenViewGeometry(bounds: region, pixelWidth: width, pixelHeight: height)
        let masks = secrets.compactMap { geometry.placement(mark: 0, frame: $0) }
        for mask in masks {
            for y in Int(mask.y.rounded(.down))..<Int((mask.y + mask.h).rounded(.up)) {
                for x in Int(mask.x.rounded(.down))..<Int((mask.x + mask.w).rounded(.up)) {
                    let at = y * line + x * 4
                    pixels[at] = 20; pixels[at + 1] = 20; pixels[at + 2] = 20; pixels[at + 3] = 255
                }
            }
        }
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard ended == nil, !spent, painted == verdict else { return [] }
            sequence += 1
            newest = Frame(seq: sequence, at: Int((now - started) * 1000), screen: place(window),
                           pixels: pixels, prior: newest?.pixels)
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        waiting.forEach { $0.resume() }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard lock.withLock({ ended == nil && !spent }) else { return }
        end("capture_failed", failure: captureFailure("SCStream", error.localizedDescription))
    }

    private func captureFailure(_ operation: String, _ message: String) -> SenseFailure {
        let failure = CGPreflightScreenCaptureAccess() ? MacScreenCaptureFailure.operationFailed(operation, message) : .screenRecordingNotTrusted
        return SenseFailure(code: failure.rawValue, message: "\(operation): \(message)", remedy: failure.remedy(app: app))
    }

    /// The window's password fields now, in window points, by the desktop
    /// picture's one-pass index: its whole tree walked and every element
    /// judged within `inspectionBudget`. A walk that is cut, a control that
    /// cannot be placed, or a root that is not this window's alone leaves the
    /// window uninspected.
    private func inspect(window frame: MacAXFrame) {
        defer { lock.withLock { inspectionTask = nil; inspecting = false } }
        guard lock.withLock({ ended == nil && !spent }), !Task.isCancelled else { return }
        let source = defaultMacAXElementSource(), deadline = Date().addingTimeInterval(Self.inspectionBudget)
        func near(_ a: MacAXFrame) -> Bool {
            abs(a.x - frame.x) <= 2 && abs(a.y - frame.y) <= 2 && abs(a.w - frame.w) <= 2 && abs(a.h - frame.h) <= 2
        }
        var why = "Secret-field inspection exceeded its deadline."
        let found: [MacAXFrame]? = MacAXLimits.$readDeadline.withValue(deadline) {
            let roots = source.windowRoots(pid: pid).filter { $0.identity.frame.map(near) ?? false }
            guard roots.count == 1 else { why = "Window selection matched \(roots.count) AX roots."; return nil }
            let snapshot = MacAccessibilityReader.walk(source: source, root: roots[0].ref, limits: .whole,
                read: source.maskingAttributes, deadline: deadline, stopAtCut: true)
            guard !snapshot.truncated else { why = "AX inspection was cut: \(snapshot.truncationReasons.joined(separator: ", "))."; return nil }
            guard !snapshot.nodes.isEmpty else { why = "AX inspection returned no nodes."; return nil }
            guard snapshot.nodes.allSatisfy({ node in
                      guard MacScreenViewBuilder.isMarkable(node.attributes) else { return true }
                      guard let frame = node.attributes.frame else { return false }
                      return frame.w >= 0 && frame.h >= 0 && [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite)
                  }) else { why = "An AX control has no finite frame for secret masking."; return nil }
            return MacScreenViewTextRedaction.secretFrames(nodes: snapshot.nodes,
                geometry: MacScreenViewGeometry(bounds: frame, pixelWidth: 1, pixelHeight: 1), deadline: deadline)
        }
        let fields = found?.map { MacAXFrame(x: $0.x - frame.x, y: $0.y - frame.y, w: $0.w, h: $0.h) }
        guard fields != nil else {
            let failure = source.isTrusted() ? captureFailure("MacAccessibilityReader secret inspection",
                why + " No frame was delivered. Read the app again before reopening screen.watch.")
                : SenseFailure(code: "accessibility_not_trusted", message: MacAccessibilityReader.notTrustedNote,
                               remedy: MacFourVerbsReply.privacyRemedy("accessibility_not_trusted"))
            end("window_uninspected", failure: failure)
            return
        }
        lock.withLock {
            guard ended == nil, !spent, !Task.isCancelled else { return }
            inspectedSuccessfully = true
            guard fields != secrets else { return }
            // Pixels painted under the old verdicts go with them.
            secrets = fields; verdict += 1; newest = nil
        }
    }

    /// Screen control still allowed, asked every time; when it is not, the
    /// watch ends ("authority_revoked").
    private func allowed() async -> Bool {
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

    private func admitOperation() -> Bool {
        lock.withLock {
            guard ended == nil, !spent, !Task.isCancelled else { return false }
            operations += 1
            return true
        }
    }

    private func finishOperation() {
        let retire = lock.withLock { operations -= 1; return spent && operations == 0 }
        if retire { end("budget_spent") }
    }

    /// Native answers about the newest frame, in its pixels: `{at:[x,y]}` its
    /// exact colour, `{mean:[x,y,w,h]}` the mean colour and luminance,
    /// `{changed:[x,y,w,h]}` the share of pixels that changed against the
    /// frame before, `{text:[x,y,w,h]}` the text there, the whole frame read
    /// on device and redacted as one picture. A frame a newer one replaced, or
    /// of another watch, has expired; it is never answered by a newer one.
    public func read(watch: Int, seq: Int, queries: [JSONValue]) async throws -> JSONValue {
        guard admitOperation() else { throw over ?? CancellationError() }
        defer { finishOperation() }
        func bad() -> SenseFailure {
            SenseFailure(code: "bad_input", message: "frame.read takes 1 to 1024 queries, each {at:[x,y]}, {mean:[x,y,w,h]}, {changed:[x,y,w,h]} or {text:[x,y,w,h]}, in this frame's pixels.")
        }
        guard await allowed() else { throw over ?? bad() }
        guard watch == generation, let (frame, painted) = lock.withLock({ newest.flatMap { $0.seq == seq ? ($0, verdict) : nil } }) else {
            throw SenseFailure(code: "expired", message: "That frame has been replaced; read the frame screen.next() returns.")
        }
        guard (1...1024).contains(queries.count) else { throw bad() }
        var answers: [JSONValue] = [], recognized: [JSONValue]?
        for query in queries {
            try Task.checkCancellation()
            guard case .object(let fields) = query, fields.count == 1, let (kind, value) = fields.first,
                  case .array(let raw) = value, case let n = raw.compactMap({ Self.number($0).flatMap { abs($0) < 1e9 ? Int($0.rounded(.down)) : nil } }),
                  n.count == raw.count else { throw bad() }
            if kind == "at", n.count == 2 {
                guard (0..<width).contains(n[0]), (0..<height).contains(n[1]) else { throw bad() }
                let at = (n[1] * width + n[0]) * 4
                answers.append(.object(["r": .int(Int64(frame.pixels[at + 2])), "g": .int(Int64(frame.pixels[at + 1])),
                                        "b": .int(Int64(frame.pixels[at]))]))
                continue
            }
            guard ["mean", "changed", "text"].contains(kind), n.count == 4, n[2] > 0, n[3] > 0 else { throw bad() }
            let x0 = max(0, n[0]), y0 = max(0, n[1]), x1 = min(width, n[0] + n[2]), y1 = min(height, n[1] + n[3])
            guard x0 < x1, y0 < y1 else { throw bad() }
            if kind == "text" {
                // Redaction judges a caption and its value together, so the whole
                // frame is recognised once; only the lines inside the region return.
                if recognized == nil {
                    guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData),
                          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw bad() }
                    let shot = MacScreenShot(bounds: MacAXFrame(x: 0, y: 0, w: Double(width), h: Double(height)),
                                             pixelWidth: width, pixelHeight: height, cgImage: image)
                    if case .array(let rows) = try await MacAppWindowText.readCaptured(shot).rows { recognized = rows } else { recognized = [] }
                }
                let lines = (recognized ?? []).compactMap { row -> String? in
                    guard case .object(let fields) = row, case .string(let text)? = fields["text"],
                          case .object(let box)? = fields["frame"], let x = box["x"].flatMap(Self.number), let y = box["y"].flatMap(Self.number),
                          let w = box["w"].flatMap(Self.number), let h = box["h"].flatMap(Self.number) else { return nil }
                    let cx = x + w / 2, cy = y + h / 2
                    return cx >= Double(x0) && cx < Double(x1) && cy >= Double(y0) && cy < Double(y1) ? text : nil
                }
                answers.append(.object(["text": .string(lines.joined(separator: "\n"))]))
                continue
            }
            if kind == "changed", frame.prior == nil { answers.append(.object(["changed": .null])); continue }
            var sum = (r: 0, g: 0, b: 0), changed = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let at = (y * width + x) * 4
                    if kind == "mean" {
                        sum.b += Int(frame.pixels[at]); sum.g += Int(frame.pixels[at + 1]); sum.r += Int(frame.pixels[at + 2])
                    } else if let prior = frame.prior,
                              // A small threshold leaves encoder noise out.
                              max(abs(Int(frame.pixels[at]) - Int(prior[at])), abs(Int(frame.pixels[at + 1]) - Int(prior[at + 1])),
                                  abs(Int(frame.pixels[at + 2]) - Int(prior[at + 2]))) > 24 { changed += 1 }
                }
            }
            let count = Double((x1 - x0) * (y1 - y0))
            if kind == "changed" {
                answers.append(.object(["changed": .double((Double(changed) / count * 1000).rounded() / 1000)]))
            } else {
                let r = Double(sum.r) / count, g = Double(sum.g) / count, b = Double(sum.b) / count
                answers.append(.object(["r": .int(Int64(r.rounded())), "g": .int(Int64(g.rounded())), "b": .int(Int64(b.rounded())),
                                        "l": .int(Int64((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))]))
            }
        }
        // Answered only while the watch is open and the secret fields it was
        // painted under still stand; a newer frame arriving meanwhile is fine.
        try Task.checkCancellation()
        guard lock.withLock({ () -> Bool in
            guard ended == nil, verdict == painted else { return false }
            self.queries += queries.count
            return true
        }) else { throw SenseFailure(code: "expired", message: "That frame has been replaced; read the frame screen.next() returns.") }
        return .array(answers)
    }

    // MARK: Hands

    /// One hand in frame pixels: click, double_click, right_click and move at
    /// {x,y}; drag {x,y,to_x,to_y}; key, hold ({keys, seconds}), down and up
    /// with {keys}. The four verbs' physical tail with every check but the
    /// fresh sight and the confirming look: the point inside the watched
    /// window where it is now, nothing of another app over it, a drag clear of
    /// password fields, the watched window its app's front window at every
    /// event, the person's input never overridden.
    public func hand(_ verb: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        guard admitOperation() else { throw over ?? CancellationError() }
        defer { finishOperation() }
        guard let verbs, let binding else {
            throw SenseFailure(code: "undeclared", message: "Declare reach hands to use hand.\(verb).")
        }
        if let over { throw over }
        guard await allowed() else { throw over ?? SenseFailure(code: "watch_ended", message: "Screen control was turned off.") }
        let window = try liveWindow()
        let geometry = MacScreenViewGeometry(bounds: place(window), pixelWidth: width, pixelHeight: height)
        func point(_ x: String, _ y: String) throws -> MacPointerPosition {
            guard let px = args[x].flatMap(Self.number), let py = args[y].flatMap(Self.number),
                  let point = geometry.screenPoint(imageX: px, imageY: py) else {
                throw SenseFailure(code: "point_outside_frame", message: "hand.\(verb) takes \(x), \(y) inside the \(width)×\(height) frame; nothing was sent.")
            }
            return point
        }
        let four = try await verbs()
        try Task.checkCancellation()
        guard lock.withLock({ ended == nil }) else { throw over ?? CancellationError() }
        let reply: MacFourVerbsReply
        var landed: JSONValue = .null
        switch verb {
        case "click", "double_click", "right_click", "move", "drag":
            let at = try point("x", "y"), to = verb == "drag" ? try point("to_x", "to_y") : nil
            let secrets = lock.withLock { self.secrets }
            if to != nil, secrets == nil {
                throw SenseFailure(code: "window_uninspected", message: "I can't tell where \(app)'s password fields are right now, so I won't drag; nothing was sent.")
            }
            // Each pointer event is hit-tested where it lands (handleHand), so the
            // opening sight's covering windows are not consulted.
            var seen = sighting
            seen.obstructions = []
            landed = at.json
            reply = await bound { await four.performPointer(
                verb == "right_click" ? "click" : verb, at: at, to: to, saying: "\(app) at \(Int(at.x)),\(Int(at.y))",
                destination: to.map { "\(Int($0.x)),\(Int($0.y))" }, before: seen, seconds: nil, holding: nil,
                button: verb == "right_click" ? "right" : nil, attention: nil,
                secrets: (secrets ?? []).map { MacAXFrame(x: $0.x + window.x, y: $0.y + window.y, w: $0.w, h: $0.h) }, confirm: false) }
        case "key", "hold", "down", "up":
            guard case .string(let keys)? = args["keys"], !keys.isEmpty else {
                throw SenseFailure(code: "bad_input", message: "hand.\(verb) takes keys, such as \"w\" or \"cmd+s\".")
            }
            var body: [String: JSONValue] = ["keys": .string(keys),
                "gesture": .string(["key": "key", "hold": "hold_key", "down": "key_down", "up": "key_up"][verb]!)]
            if verb == "hold" { body["seconds"] = args["seconds"] ?? .double(0.6) }
            reply = await bound { await four.performHand(body: body, description: "Pressed \(keys) in \(self.app).", before: nil, confirm: false) }
        default:
            throw SenseFailure(code: "unsupported", message: "hand has click, double_click, right_click, move, drag, key, hold, down and up.")
        }
        guard reply.ok else {
            if !binding.allowsEmission { end("taken_over") }
            if let over { throw over }
            let error = reply.detail["error"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? "refused"
            throw SenseFailure(code: String(error.prefix { $0 != ":" }), message: reply.text, remedy: reply.detail["remedy"])
        }
        lock.withLock { hands += 1 }
        return .object(["screen": landed])
    }

    /// One hand on the watch's binding: every event goes out only while it
    /// lands on the watched window, checked at that event (handleHand).
    private func bound(_ work: () async -> MacFourVerbsReply) async -> MacFourVerbsReply {
        await MacDriverContext.$binding.withValue(binding) {
            await MacDriverContext.$holdsAcrossCalls.withValue(true) {
                await MacFourVerbs.$requiredFrontPid.withValue(pid) {
                    await MacFourVerbs.$requiredFrontWindow.withValue(windowNumber) { await work() }
                }
            }
        }
    }

    /// Why no hand goes out any more, once the watch has ended.
    private var over: SenseFailure? {
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
            defer { stream = nil; waiters.removeAll(); tasks = []; inspectionTask = nil; settlementTask = nil; newest = nil }
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

    private static func number(_ value: JSONValue) -> Double? {
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
