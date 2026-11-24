import Foundation
import Synchronization
import MacNerves
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MindCore
import PersistenceCore
import NativeAgentCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import SenseCore
// Blueprint: | `WindowPixels.swift` | Crop before deduplication; bounded JPEGs retain capture provenance |

/// One attachment per screen call, reusing its captured frame and thin-AX reason. Background window capture raises nothing; attach runs after the verb. Screen
/// Recording is preflighted, never requested, and missing access is reported.
final class FourVerbPixelAttachment: Sendable {
    static let maxLongSide = 1024
    static let maxBytes = 150_000

    let turn: Turn
    let invocation: ChatToolInvocation
    let part: String?
    let forced: Bool
    private struct State {
        var recorded = false
        var frameID = ""
        var capture: MacImageCapture?
        var reason: String?
        var screenRecording = false
        var png: String?
        var image: CGImage?
        var unavailable: String?
        var captureDetail: String?
        var captureRemedy: JSONValue?
        var origin: (x: Double, y: Double) = (0, 0)
        var logicalSize: (width: Double, height: Double) = (0, 0)
        var background = false
        var window = ""
        var region: (name: String, frame: MacAXFrame)?
        var discarded = false
        var imageFrame: JSONValue?
    }
    private let state = Mutex(State())

    init(part: String?, forced: Bool, turn: Turn, invocation: ChatToolInvocation) {
        self.turn = turn
        self.invocation = invocation
        self.part = part
        self.forced = forced
    }

    func record(frameID: String, capture: MacImageCapture?, reason: String?, screenRecording: Bool, png: String?, image: CGImage?, unavailable: String?,
                origin: (x: Double, y: Double), logicalSize: (width: Double, height: Double),
                background: Bool, window: String, captureDetail: String? = nil, captureRemedy: JSONValue? = nil) {
        state.withLock { state in
            state.recorded = true
            state.frameID = frameID
            state.capture = capture
            state.discarded = false
            state.reason = reason
            state.screenRecording = screenRecording
            state.png = png
            state.image = image
            state.unavailable = unavailable
            state.captureDetail = captureDetail
            state.captureRemedy = captureRemedy
            state.origin = origin
            state.logicalSize = logicalSize
            state.background = background
            state.window = window
            state.region = nil
        }
    }

    func focus(name: String, frame: MacAXFrame) {
        state.withLock { $0.region = (name, frame) }
    }

    /// Reject pixels from a capture the look could not bind to its window.
    func discard() {
        state.withLock { state in
            state.discarded = true
            state.png = nil
            state.image = nil
            state.region = nil
        }
    }

    static func region(named part: String, in targets: [MacFourVerbsSupplementalTarget]) -> (name: String, frame: MacAXFrame)? {
        func normalize(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#\"'"))
        }
        let wanted = normalize(part)
        let words = wanted.split(separator: " ")
        let number = words.last.flatMap { Int($0) }
        let prefix = words.dropLast().joined(separator: " ")
        for target in targets where target.sourceAXPath == nil {
            guard let label = target.label?.display else { continue }
            let name = normalize(label)
            if name == wanted || target.aliases.map(normalize).contains(wanted)
                || (number.map { name == "visual region \($0)" } ?? false
                    && ["", "region", "visual region"].contains(prefix)) {
                return (label, target.observedFrame)
            }
        }
        return nil
    }

    var imageFrame: JSONValue? { state.withLock { $0.imageFrame } }

    /// An AX-rich window needs no pixel note unless pixels were requested.
    func attach() -> String? {
        state.withLock { state in attach(&state) }
    }

    private func attach(_ state: inout State) -> String? {
        state.imageFrame = nil
        guard state.recorded, state.reason != nil || forced else { return nil }
        let why = state.reason.map { "thin accessibility: \($0)" } ?? "pixels:true"
        guard state.screenRecording else {
            return """
                Pixels (\(why)): screen_recording_not_trusted. No image was attached or permission prompt opened. The text read above retains \
                its stated coverage. Request app {action:\"permissions.request\",args:{capability:\"privacy:screenRecording\",why:\"Allow NativeAgent to \
                see the screen?\"}}; the owner decides.
                """
        }
        guard !state.discarded else {
            return """
                Pixels (\(why)): capture_window_changed. The window changed during capture; no image was attached. The text read above retains \
                its stated coverage. Use mac.look for the affected app to inspect its current state.
                """
        }
        guard let png = state.png else {
            let recovery = state.captureRemedy.flatMap { try? $0.serialize(pretty: false) }
                ?? "Inspect the affected app's menu with mac.menu; correct the capture failure before another image request."
            return """
                Pixels (\(why)): \(state.unavailable ?? "capture_failed"). \(state.captureDetail ?? "No usable image was returned.") No image was attached. \
                The text read above retains its stated coverage. \(recovery)
                """
        }
        guard invocation.imageSink != nil else {
            return """
                Pixels (\(why)): image_delivery_unavailable. This call cannot carry an image. The text read above retains its stated coverage; \
                request pixels from a model turn's call if an image is needed.
                """
        }
        let region = state.region
        var scope = "the window"
        if let region { scope = "\(region.name), cropped at higher detail" }
        guard let image = state.image else {
            return "Pixels (\(why)): the window capture could not be decoded; the words above are all I have."
        }
        var source = (image: image, origin: state.origin, logicalSize: state.logicalSize)
        if let region {
            let padX = max(24, region.frame.w * 0.25), padY = max(24, region.frame.h * 0.25)
            guard let crop = VisionImageCropper.crop(
                image,
                to: MacAXFrame(x: region.frame.x - padX, y: region.frame.y - padY,
                               w: region.frame.w + padX * 2, h: region.frame.h + padY * 2),
                origin: state.origin, logicalSize: state.logicalSize
            ) else {
                return "Pixels (\(why)): region_crop_failed. The requested region could not be cropped; no image was attached."
            }
            source = (crop.image, crop.origin, crop.logicalSize)
        }
        // Deduplicate identical window/region/source bytes before JPEG fitting; the delivered frame already represents them.
        let key = state.window + "|" + (region?.name ?? "")
        let geometryKey = [source.origin.x, source.origin.y, source.logicalSize.width, source.logicalSize.height]
            .map { String($0) }.joined(separator: "|")
        let fingerprint = SHA256Hex.of(Data((png + "|" + geometryKey).utf8))
        let execution = forced ? nil : turn.execution
        if let previousID = execution?.attachedPixelFrame(window: key, fingerprint: fingerprint),
           let previous = MacImageFrames.frame(previousID, turn: turn) {
            let old = previous.geometry
            let frame = MacImageFrames.remember(MacScreenViewGeometry(bounds: old.bounds,
                pixelWidth: old.pixelWidth, pixelHeight: old.pixelHeight, capture: state.capture), id: state.frameID, turn: turn)
            state.imageFrame = frame.fields
            execution?.notePixelsAttached(window: key, fingerprint: fingerprint, frameID: state.frameID)
            return "Pixels (\(why)): \(scope) is unchanged since its image was attached earlier this turn; not sent again. " + frame.words
        }
        guard let jpeg = Self.boundedJPEG(source.image) else {
            return "Pixels (\(why)): the image could not be fitted under \(Self.maxBytes / 1000) KB; none was attached."
        }
        // What it shows names it, so a newer look at the same window replaces it.
        let parts = state.window.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let app = parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts.first ?? "the window"
        let title = parts.count > 2 && !parts[2].isEmpty && parts[2] != app ? " “" + parts[2] + "”" : ""
        let name = LocalToolImage.screenshotName(of: app + title + (region.map { ", " + $0.name } ?? ""), source: key)
        let delivered = LocalToolImage.deliverPNG(jpeg.data, name: name,
            width: jpeg.width, height: jpeg.height, mediaType: "image/jpeg", sink: invocation.imageSink)
        let reply = ToolResult(delivered)
        guard case .object(let result) = delivered, reply.said("ok"), reply.status == result["status"]?.stringValue else {
            return "Pixels (\(why)): this result already carries its image limit; none was attached."
        }
        let placement = state.background ? "captured where it sits, nothing raised" : "the front window as shown"
        let attached = """
            Pixels attached (\(why)): one \(jpeg.width)×\(jpeg.height) JPEG, \(max(1, jpeg.data.count / 1000)) KB, of \(scope) (\(placement)). \
            It follows this result.
            """
        // The final size and the screen rect it covers travel together, so a point in it is a place.
        guard source.logicalSize.width > 0, source.logicalSize.height > 0 else { return attached }
        let frame = MacImageFrames.remember(MacScreenViewGeometry(
            bounds: MacAXFrame(x: source.origin.x, y: source.origin.y, w: source.logicalSize.width, h: source.logicalSize.height),
            pixelWidth: jpeg.width, pixelHeight: jpeg.height, capture: state.capture), id: state.frameID, turn: turn)
        state.imageFrame = frame.fields
        turn.execution?.notePixelsAttached(window: key, fingerprint: fingerprint, frameID: state.frameID, image: name)
        return attached + " " + frame.words
    }

    /// Long side ≤ 1024 px and ≤ 150 KB bounds provider input; try quality steps before 3/4 scaling.
    static func boundedJPEG(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        let longest = max(image.width, image.height)
        guard longest > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var side = min(maxLongSide, longest)
        while side >= 128 {
            let scale = Double(side) / Double(longest)
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            for quality in [0.8, 0.65, 0.5, 0.4] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, scaled,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), encoded.length > 0, encoded.length <= maxBytes {
                    return (encoded as Data, width, height)
                }
            }
            side = side * 3 / 4
        }
        return nil
    }
}
