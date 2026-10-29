import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ChatTurnContracts
import Dispatcher
import MacControl
import PersistenceCore
import AgentWorkspace
import MemoryV2
import NativeAgentCore
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import Senses
import AgentConversations
import StandingBots
// Blueprint: | `WindowPixels.swift` | `FourVerbPixelAttachment` class; call-scoped captured pixels, region cropping, attachment deduplication and bounded JPEG delivery |

/// One attachment per screen call, reusing its captured frame and thin-AX reason.
/// Background window capture raises nothing; attach runs after the verb.
/// Screen Recording is preflighted, never requested, and missing access is reported.
final class FourVerbPixelAttachment: @unchecked Sendable {
    static let maxLongSide = 1024
    static let maxBytes = 150_000

    let part: String?
    let forced: Bool
    private let lock = NSLock()
    private var recorded = false
    private var frameID = ""
    private var reason: String?
    private var screenRecording = false
    private var png: String?
    private var image: CGImage?
    private var unavailable: String?
    private var captureDetail: String?
    private var captureRemedy: JSONValue?
    private var origin: (x: Double, y: Double) = (0, 0)
    private var logicalSize: (width: Double, height: Double) = (0, 0)
    private var background = false
    private var window = ""
    private var region: (name: String, frame: MacAXFrame)?

    init(part: String?, forced: Bool) {
        self.part = part
        self.forced = forced
    }

    func record(frameID: String, reason: String?, screenRecording: Bool, png: String?, image: CGImage?, unavailable: String?,
                origin: (x: Double, y: Double), logicalSize: (width: Double, height: Double),
                background: Bool, window: String, captureDetail: String? = nil, captureRemedy: JSONValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        recorded = true
        self.frameID = frameID
        discarded = false
        self.reason = reason
        self.screenRecording = screenRecording
        self.png = png
        self.image = image
        self.unavailable = unavailable
        self.captureDetail = captureDetail
        self.captureRemedy = captureRemedy
        self.origin = origin
        self.logicalSize = logicalSize
        self.background = background
        self.window = window
        region = nil
    }

    func focus(name: String, frame: MacAXFrame) {
        lock.lock(); defer { lock.unlock() }
        region = (name, frame)
    }

    /// The look rejected this capture as not its own window: drop its pixels.
    private var discarded = false
    func discard() {
        lock.lock(); defer { lock.unlock() }
        discarded = true
        png = nil
        image = nil
        region = nil
    }

    /// A numbered pixel region by its rendered name ("visual region 3"),
    /// "region 3", "3", or the OCR label a pixel target carries.
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

    /// The delivered image's frame fields (MacImageFrames), once `attach` sent one.
    private(set) var imageFrame: JSONValue?

    /// The one line `screen` adds, or nil when nothing about pixels needs
    /// saying (an AX-rich window she did not ask pixels of).
    func attach() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard recorded, reason != nil || forced else { return nil }
        let why = reason.map { "thin accessibility: \($0)" } ?? "pixels:true"
        guard screenRecording else {
            return "Pixels (\(why)): screen_recording_not_trusted. No image was attached or permission prompt opened. The text read above retains its stated coverage. Request app {action:\"permissions.request\",args:{capability:\"screenRecording\",why:\"Allow NativeAgent to see the screen?\"}}; the owner decides."
        }
        guard !discarded else {
            return "Pixels (\(why)): capture_window_changed. The window changed during capture; no image was attached. The text read above retains its stated coverage. Use mac.look for the affected app to inspect its current state."
        }
        guard let png else {
            let recovery = captureRemedy.flatMap { try? $0.serialize(pretty: false) }
                ?? "Inspect the affected app's menu with mac.menu; correct the capture failure before another image request."
            return "Pixels (\(why)): \(unavailable ?? "capture_failed"). \(captureDetail ?? "No usable image was returned.") No image was attached. The text read above retains its stated coverage. \(recovery)"
        }
        guard LocalToolImage.sink != nil else {
            return "Pixels (\(why)): image_delivery_unavailable. This call cannot carry an image. The text read above retains its stated coverage; request pixels from a model tool turn if an image is needed."
        }
        var scope = "the window"
        if let region { scope = "\(region.name), cropped at higher detail" }
        // Same window, same region, byte-identical source frame → the image
        // already in her context stands. Checked before JPEG fitting.
        let key = window + "|" + (region?.name ?? "")
        let fingerprint = SHA256.hash(data: Data(png.utf8)).map { String(format: "%02x", $0) }.joined()
        let turn = forced ? nil : ChatTurnExecution.current
        if let previousID = turn?.attachedPixelFrame(window: key, fingerprint: fingerprint),
           let previous = MacImageFrames.frame(previousID) {
            let frame = MacImageFrames.remember(previous.geometry, id: frameID)
            imageFrame = frame.fields
            turn?.notePixelsAttached(window: key, fingerprint: fingerprint, frameID: frameID)
            return "Pixels (\(why)): \(scope) is unchanged since its image was attached earlier this turn; not sent again. " + frame.words
        }
        guard let image else {
            return "Pixels (\(why)): the window capture could not be decoded; the words above are all I have."
        }
        var source = (image: image, origin: origin, logicalSize: logicalSize)
        if let region, logicalSize.width > 0, logicalSize.height > 0 {
            let padX = max(24, region.frame.w * 0.25), padY = max(24, region.frame.h * 0.25)
            let crop = VisionImageCropper.crop(
                image,
                to: MacAXFrame(x: region.frame.x - padX, y: region.frame.y - padY,
                               w: region.frame.w + padX * 2, h: region.frame.h + padY * 2),
                origin: origin, logicalSize: logicalSize
            )
            source = (crop.image, crop.origin, crop.logicalSize)
        }
        guard let jpeg = Self.boundedJPEG(source.image) else {
            return "Pixels (\(why)): the image could not be fitted under \(Self.maxBytes / 1000) KB; none was attached."
        }
        // What it shows names it, so a newer look at the same window replaces it.
        let parts = window.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let app = parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts.first ?? "the window"
        let title = parts.count > 2 && !parts[2].isEmpty && parts[2] != app ? " “" + parts[2] + "”" : ""
        let name = LocalToolImage.screenshotName(of: app + title + (region.map { ", " + $0.name } ?? ""), source: key)
        let delivered = LocalToolImage.deliverPNG(jpeg.data, name: name,
            width: jpeg.width, height: jpeg.height, mediaType: "image/jpeg")
        guard case .object(let result) = delivered, result["status"] == .string("ok") else {
            return "Pixels (\(why)): this result already carries its image limit; none was attached."
        }
        let placement = background ? "captured where it sits, nothing raised" : "the front window as shown"
        let attached = "Pixels attached (\(why)): one \(jpeg.width)×\(jpeg.height) JPEG, \(max(1, jpeg.data.count / 1000)) KB, of \(scope) (\(placement)). It follows this result."
        // The final size and the screen rect it covers travel together, so a point in it is a place.
        guard source.logicalSize.width > 0, source.logicalSize.height > 0 else { return attached }
        let frame = MacImageFrames.remember(MacScreenViewGeometry(
            bounds: MacAXFrame(x: source.origin.x, y: source.origin.y, w: source.logicalSize.width, h: source.logicalSize.height),
            pixelWidth: jpeg.width, pixelHeight: jpeg.height), id: frameID)
        imageFrame = frame.fields
        ChatTurnExecution.current?.notePixelsAttached(window: key, fingerprint: fingerprint, frameID: frameID, image: name)
        return attached + " " + frame.words
    }

    /// Long side ≤ 1024 px and ≤ 150 KB: quality steps first, then 3/4 scale.
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
