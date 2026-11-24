import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import SenseCore
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `MacScreenWatch+Capture.swift` | `MacScreenWatch`: Exact capture with complete secret masks; inspect the newest pending frame even when static |

extension MacScreenWatch {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard state.withLock({ $0.ended == nil && !$0.spent }), type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .stopped { end("window_gone"); return }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { end("frame_size_changed"); return }
        guard let window = try? liveWindow() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { state in
            guard state.ended == nil, !state.spent, state.secrets != nil else { return }
            state.pending = Capture(buffer: MacScreenCaptureValue(value: buffer), window: window, at: now)
            guard state.inspectionTask == nil else { return }
            state.inspectionTask = Task.detached { [weak self] in
                await self?.inspectPending()
            }
        }
    }

    private func inspectPending() async {
        while true {
            let delay = state.withLock { state -> Double? in
                guard state.ended == nil, !state.spent, !Task.isCancelled, state.pending != nil else {
                    state.inspectionTask = nil
                    return nil
                }
                return max(0, Self.inspectionInterval - (ProcessInfo.processInfo.systemUptime - state.inspected))
            }
            guard let delay else { return }
            if delay > 0 {
                guard (try? await Task.sleep(for: .seconds(delay))) != nil else {
                    state.withLock { $0.inspectionTask = nil }
                    return
                }
            }
            let capture = state.withLock { state -> Capture? in
                guard state.ended == nil, !state.spent, !Task.isCancelled, let capture = state.pending else {
                    state.inspectionTask = nil
                    return nil
                }
                state.pending = nil
                state.inspected = ProcessInfo.processInfo.systemUptime
                return capture
            }
            guard let capture else { return }
            inspect(window: capture.window, buffer: capture.buffer.value, at: capture.at)
        }
    }

    private func maskedPixels(from buffer: CVPixelBuffer, secrets: Set<MacAXFrame>) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let line = width * 4
        guard row >= line, let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let geometry = MacScreenViewGeometry(bounds: region, pixelWidth: width, pixelHeight: height)
        return unsafe [UInt8](unsafeUninitializedCapacity: line * height) { bytes, initialized in
            let destination = unsafe bytes.baseAddress!
            for y in 0..<height { unsafe memcpy(destination + y * line, base + y * row, line) }
            var color = UInt32(0xff141414).littleEndian
            for secret in secrets {
                guard let mask = geometry.placement(mark: 0, frame: secret) else { continue }
                let x = Int(mask.x.rounded(.down)), right = min(width, Int((mask.x + mask.w).rounded(.up)))
                let bottom = min(height, Int((mask.y + mask.h).rounded(.up)))
                for y in Int(mask.y.rounded(.down))..<bottom {
                    memset_pattern4(destination + y * line + x * 4, &color, (right - x) * 4)
                }
            }
            initialized = bytes.count
        }
    }

    private func publish(pixels: [UInt8], window: MacAXFrame, at now: Double, painted: Int) {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.ended == nil, !state.spent, painted == state.verdict else { return [] }
            state.sequence += 1
            state.newest = Frame(seq: state.sequence, at: Int((now - started) * 1000), screen: place(window),
                           pixels: pixels, prior: state.newest?.pixels)
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        waiting.forEach { $0.resume() }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard state.withLock({ $0.ended == nil && !$0.spent }) else { return }
        end("capture_failed", failure: captureFailure("SCStream", error.localizedDescription))
    }

    func captureFailure(_ operation: String, _ message: String) -> SenseFailure {
        let failure = CGPreflightScreenCaptureAccess() ? MacScreenCaptureFailure.operationFailed(operation, message) : .screenRecordingNotTrusted
        return SenseFailure(code: failure.rawValue, message: "\(operation): \(message)", remedy: failure.remedy(app: app))
    }

    /// Complete whole-window inspection must place every secret control under the exact window root; truncation leaves pixels uninspected.
    func inspect(window frame: MacAXFrame, buffer: CVPixelBuffer?, at: Double) {
        guard state.withLock({ $0.ended == nil && !$0.spent }), !Task.isCancelled else { return }
        let source = defaultMacAXElementSource(), deadline = Date().addingTimeInterval(Self.inspectionBudget)
        var why = "Secret-field inspection exceeded its deadline."
        let found: [MacAXFrame]? = context.holding(\.readDeadline, deadline) {
            context in let roots = source.windowRoots(pid: pid, context: context).filter { MacAXWindowIdentity.rectsMatch($0.identity.frame, frame) }
            guard roots.count == 1 else { why = "Window selection matched \(roots.count) AX roots."; return nil }
            do {
                let nodes = try MacScreenViewTextRedaction.inspectSecretFields(source: source, root: roots[0].ref, deadline: deadline, context: context)
                return MacScreenViewTextRedaction.secretFrames(nodes: nodes,
                    geometry: MacScreenViewGeometry(bounds: frame, pixelWidth: 1, pixelHeight: 1), deadline: deadline, context: context)
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
        let paint = state.withLock { state -> (Set<MacAXFrame>, Int)? in
            guard state.ended == nil, !state.spent, !Task.isCancelled else { return nil }
            state.inspectedSuccessfully = true
            if fields != state.secrets {
                state.frameMasks.formUnion(fields)
                state.secrets = fields; state.verdict += 1; state.newest = nil
            }
            return (state.frameMasks, state.verdict)
        }
        guard let (masks, painted) = paint, let buffer else { return }
        guard let pixels = maskedPixels(from: buffer, secrets: masks) else { return }
        publish(pixels: pixels, window: frame, at: at, painted: painted)
    }

}
