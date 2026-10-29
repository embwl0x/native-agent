import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Senses
import Experiences
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `MacScreenWatch+Capture.swift` | `MacScreenWatch`: exact-window frame capture, complete secret inspection and masking before publication; newest pending capture is inspected at its 500ms deadline, without another capture; inspection failure ends the active watch |

extension MacScreenWatch {
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
            guard let destination = out.baseAddress else { return }
            for y in 0..<height { memcpy(destination + y * line, base + y * row, line) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard ended == nil, !spent, let preceding = secrets else { return }
            pending = Capture(pixels: pixels, window: window, preceding: preceding, at: now)
            guard inspectionTask == nil else { return }
            inspectionTask = Task.detached { [weak self] in
                await self?.inspectPending()
            }
        }
    }

    private func inspectPending() async {
        while true {
            let delay = lock.withLock { () -> Double? in
                guard ended == nil, !spent, !Task.isCancelled, pending != nil else {
                    inspectionTask = nil
                    return nil
                }
                return max(0, Self.inspectionInterval - (ProcessInfo.processInfo.systemUptime - inspected))
            }
            guard let delay else { return }
            if delay > 0 {
                guard (try? await Task.sleep(for: .seconds(delay))) != nil else {
                    lock.withLock { inspectionTask = nil }
                    return
                }
            }
            let capture = lock.withLock { () -> Capture? in
                guard ended == nil, !spent, !Task.isCancelled, let capture = pending else {
                    inspectionTask = nil
                    return nil
                }
                pending = nil
                inspected = ProcessInfo.processInfo.systemUptime
                return capture
            }
            guard let capture else { return }
            inspect(window: capture.window, pixels: capture.pixels, preceding: capture.preceding, at: capture.at)
        }
    }

    private func publish(pixels captured: [UInt8], secrets: [MacAXFrame], window: MacAXFrame, at now: Double, painted: Int) {
        var pixels = captured
        let line = width * 4
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

    func captureFailure(_ operation: String, _ message: String) -> SenseFailure {
        let failure = CGPreflightScreenCaptureAccess() ? MacScreenCaptureFailure.operationFailed(operation, message) : .screenRecordingNotTrusted
        return SenseFailure(code: failure.rawValue, message: "\(operation): \(message)", remedy: failure.remedy(app: app))
    }

    /// The window's password fields now, in window points, by the desktop
    /// picture's one-pass index: its whole tree walked and every element
    /// judged within `inspectionBudget`. A walk that is cut, a control that
    /// cannot be placed, or a root that is not this window's alone leaves the
    /// window uninspected.
    func inspect(window frame: MacAXFrame, pixels: [UInt8]?, preceding: [MacAXFrame], at: Double) {
        guard lock.withLock({ ended == nil && !spent }), !Task.isCancelled else { return }
        let source = defaultMacAXElementSource(), deadline = Date().addingTimeInterval(Self.inspectionBudget)
        var why = "Secret-field inspection exceeded its deadline."
        let found: [MacAXFrame]? = MacAXLimits.$readDeadline.withValue(deadline) {
            let roots = source.windowRoots(pid: pid).filter { MacAXWindowIdentity.rectsMatch($0.identity.frame, frame) }
            guard roots.count == 1 else { why = "Window selection matched \(roots.count) AX roots."; return nil }
            do {
                let nodes = try MacScreenViewTextRedaction.inspectSecretFields(source: source, root: roots[0].ref, deadline: deadline)
                return MacScreenViewTextRedaction.secretFrames(nodes: nodes,
                    geometry: MacScreenViewGeometry(bounds: frame, pixelWidth: 1, pixelHeight: 1), deadline: deadline)
            } catch {
                why = (error as? SenseFailure)?.message ?? error.localizedDescription
                return nil
            }
        }
        let fields = found?.map { MacAXFrame(x: $0.x - frame.x, y: $0.y - frame.y, w: $0.w, h: $0.h) }
        guard let fields else {
            let failure = source.isTrusted() ? captureFailure("MacAccessibilityReader secret inspection",
                why + " No frame was delivered. Read the app again before reopening screen.watch.")
                : SenseFailure(code: "accessibility_not_trusted", message: MacAccessibilityReader.notTrustedNote,
                               remedy: MacFourVerbsReply.privacyRemedy("accessibility_not_trusted"))
            end("window_uninspected", failure: failure)
            return
        }
        let painted = lock.withLock { () -> Int? in
            guard ended == nil, !spent, !Task.isCancelled else { return nil }
            inspectedSuccessfully = true
            if fields != secrets {
                // Pixels painted under the old verdicts go with them.
                secrets = fields; verdict += 1; newest = nil
            }
            return verdict
        }
        guard let painted, let pixels else { return }
        // Retain both sides of the capture: a field that scrolled out during
        // the inspection must still mask its pixels in the candidate.
        let masks = preceding + fields.filter { !preceding.contains($0) }
        publish(pixels: pixels, secrets: masks, window: frame, at: at, painted: painted)
    }

}
