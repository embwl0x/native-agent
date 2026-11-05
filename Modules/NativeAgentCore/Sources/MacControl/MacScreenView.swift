import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(ScreenCaptureKit) && os(macOS)
import ScreenCaptureKit
#endif
#if canImport(AppKit)
import AppKit
// Blueprint: | `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`, `MacScreenViewTextRedaction`, `MacImageFrames`, `MacImageCapture`: Capture |
#endif
// Fuse pixels and AX structure so marks address captured elements rather than guessed coordinates. Use the shared injection-free AX walker for
// complete secret inspection; keep geometry and budgeting pure over value types. Marks provide references, never authority; dispatch policy, grants,
// switches and driver admission still gate effects.
public enum MacScreenCaptureScope: String, Sendable, Equatable {
    case focusedWindow = "focused_window"
}
/// Captured bounds share AX’s global top-left screen-point space so image translation remains exact.
public struct MacScreenShot: @unchecked Sendable {
    /// Capture provenance is immutable window-server evidence, not a delivery-time reread.
    public let capture: MacImageCapture?
    public let bounds: MacAXFrame
    public let pixelWidth: Int
    public let pixelHeight: Int
    #if canImport(CoreGraphics)
    /// Geometry, legend and storage must remain usable without captured pixels.
    public let cgImage: CGImage?
    public init(bounds: MacAXFrame, pixelWidth: Int, pixelHeight: Int, cgImage: CGImage? = nil, capture: MacImageCapture? = nil) {
        self.capture = capture
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cgImage = cgImage
    }
    #else
    public init(bounds: MacAXFrame, pixelWidth: Int, pixelHeight: Int, capture: MacImageCapture? = nil) {
        self.capture = capture
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
    #endif
}
/// Report why an image is absent so missing permission or capture failure stays actionable.
public enum MacScreenCaptureFailure: Sendable, Equatable, Error, LocalizedError {
    case screenRecordingNotTrusted, noDisplay, captureFailed, unavailableOnThisPlatform, encodeFailed, exceedsByteCap
    case operationFailed(String, String)
    public var rawValue: String {
        switch self {
        case .screenRecordingNotTrusted: "screen_recording_not_trusted"
        case .noDisplay: "no_display"
        case .captureFailed: "capture_failed"
        case .unavailableOnThisPlatform: "screen_capture_unavailable_on_this_platform"
        case .encodeFailed: "image_encode_failed"
        case .exceedsByteCap: "image_exceeds_byte_cap"
        case .operationFailed: "capture_failed"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .screenRecordingNotTrusted: "NativeAgent lacks the macOS Screen Recording grant."
        case .noDisplay: "No display is available to capture."
        case .captureFailed: "The screen capture source returned no usable image."
        case .unavailableOnThisPlatform: "Screen capture is unavailable on this platform."
        case .encodeFailed: "The captured image could not be encoded."
        case .exceedsByteCap: "The image exceeds the delivery byte limit."
        case .operationFailed(let operation, let cause): "\(operation): \(cause)"
        }
    }
    public func remedy(app: String? = nil, part: String? = nil) -> JSONValue {
        let args: [String: JSONValue] = app.map { ["app": .string($0)] } ?? [:]
        switch self {
        case .screenRecordingNotTrusted:
            return MacFourVerbsReply.permissionRemedy("privacy:screenRecording", name: "Screen Recording")
        case .noDisplay:
            return Repair.why(owner: "Mac display availability", tap: "Mac > connected display",
                instruction: "Connect or wake a display before requesting pixels; no display was available to capture.")
        case .unavailableOnThisPlatform:
            return Repair.terminal(instruction: "Screen capture is unavailable on this platform. Use a Mac with a graphical login session for pixels.")
        case .exceedsByteCap:
            return Repair.reconcile(
                instruction: """
                    The image exceeds the delivery limit. Inspect mac.look's region selector, then request a smaller named part rather than the same \
                    capture.
                    """,
                nextCall: .object(["tool": .string("app"), "input": .object(["find": .string("mac.look")])]))
        case .encodeFailed:
            return Repair.reconcile(
                instruction: "Image encoding failed. Inspect the app's menu without capturing pixels; encoding needs repair before another image request.",
                nextCall: .object(["tool": .string("app"), "input": .object([
                    "action": .string("mac.menu"), "args": .object(args)])]))
        case .captureFailed, .operationFailed:
            return Repair.reconcile(
                instruction: """
                    \(errorDescription ?? rawValue). Inspect the app's menu without capturing pixels to establish available controls; correct the capture \
                    failure before another image request.
                    """,
                nextCall: .object(["tool": .string("app"), "input": .object([
                    "action": .string("mac.menu"), "args": .object(args)])]))
        }
    }
}
/// Screen Recording is separate from Accessibility; preflight reads it without prompting, and only the user initiates the grant.
public protocol MacScreenCaptureSource: Sendable {
    func isScreenRecordingTrusted() -> Bool
    /// Capture rects use global screen points; nil selects the whole main display.
    func capture(rect: MacAXFrame?, context: MacOperationContext) async -> Result<MacScreenShot, MacScreenCaptureFailure>
    /// Exact-window capture cannot substitute a desktop crop when identity is unavailable.
    func capture(window: MacAXWindowIdentity, context: MacOperationContext) async -> Result<MacScreenShot, MacScreenCaptureFailure>
    /// Composite capture shares one enumeration and selects exact window numbers, never same-frame siblings.
    func windowCapture(context: MacOperationContext) async -> MacScreenWindowCapture
}
public typealias MacScreenWindowCapture = @Sendable (_ windowNumber: Int, _ maxPixelWidth: Int) async -> Result<MacScreenShot, MacScreenCaptureFailure>
public extension MacScreenCaptureSource {
    func capture(window: MacAXWindowIdentity, context: MacOperationContext) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        .failure(.captureFailed)
    }
    func windowCapture(context: MacOperationContext) async -> MacScreenWindowCapture {
        { _, _ in .failure(.captureFailed) }
    }
}
/// Marker positions use full-resolution image pixels with a top-left origin, not AX screen points.
public struct MacScreenMarkerPlacement: Sendable, Equatable {
    public let mark: Int
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public init(mark: Int, x: Double, y: Double, w: Double, h: Double) {
        self.mark = mark
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}
/// Keep rendering separate from pure geometry and byte-budget selection.
public protocol MacScreenImageRenderer: Sendable {
    /// Scale image and marker geometry together so byte-cap resizing cannot displace marks.
    func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        secretFrames: [MacAXFrame],
        downscale: Double
    ) -> Data?
}
/// Marks carry the shared AX child path and resolve it fresh at act time rather than trusting a stale element.
public struct MacScreenViewMark: Sendable, Equatable {
    public let mark: Int
    public let role: String
    public let subrole: String?
    public let label: String?
    /// Distinguish owned captions from unreadable or absent names so missing evidence cannot masquerade as a label.
    public let labelSource: String
    public let value: String?
    /// Secure-field values never leave in clear text.
    public let secret: Bool
    public let enabled: Bool?
    public let frame: MacAXFrame
    public let path: [Int]
    public let actions: [String]
    public let actionsUnreadable: String?
    public let attributeGaps: [String]
    public let settableAttributes: [String]
    /// Resolve enclosing secret captions from the complete captured node set.
    public let enclosingCaption: MacScreenViewTextRedaction.EnclosingCaptionKinds
    /// Redaction needs complete captured context, not only the displayed subset.
    public let labelRedaction: JSONValue?
    public let valueRedaction: JSONValue?
    public init(
        mark: Int,
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        labelSource: String = "title",
        value: String? = nil,
        secret: Bool = false,
        enabled: Bool? = nil,
        frame: MacAXFrame,
        path: [Int],
        actions: [String] = [],
        actionsUnreadable: String? = nil,
        attributeGaps: [String] = [],
        settableAttributes: [String] = [],
        enclosingCaption: MacScreenViewTextRedaction.EnclosingCaptionKinds = .none,
        labelRedaction: JSONValue? = nil,
        valueRedaction: JSONValue? = nil
    ) {
        self.mark = mark
        self.role = role
        self.subrole = subrole
        self.label = label
        self.labelSource = labelSource
        self.value = value
        self.secret = secret
        self.enabled = enabled
        self.frame = frame
        self.path = path
        self.actions = actions
        self.actionsUnreadable = actionsUnreadable
        self.attributeGaps = attributeGaps
        self.settableAttributes = settableAttributes
        self.enclosingCaption = enclosingCaption
        self.labelRedaction = labelRedaction
        self.valueRedaction = valueRedaction
    }
    /// Legend values reach trace, persistence and sync; secure values must use the shared count/digest redaction shape.
    public func toJSON(valueChars: Int = MacAXLimits.hardValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "mark": .int(Int64(mark)),
            "role": .string(role),
            "enabled": enabled.map(JSONValue.bool) ?? .null,
            "frame": frame.toJSON(),
            "path": .array(path.map { .int(Int64($0)) }),
            "settable_attributes": .array(settableAttributes.map { .string($0) }),
        ]
        if !attributeGaps.isEmpty {
            object["attribute_gaps"] = .array(attributeGaps.map(JSONValue.string))
        }
        if let actionsUnreadable {
            object["actions_unreadable"] = .string(actionsUnreadable)
        } else {
            object["actions"] = .array(actions.map { .string($0) })
        }
        if let subrole { object["subrole"] = .string(subrole) }
        if let label {
            // Titles and inferred names use the same secret-shape checks as prose.
            object["label"] = labelRedaction ?? MacScreenViewTextRedaction.redactedLegendString(
                label,
                valueChars: valueChars,
                // Inferred names can be field values, so enclosing captions apply here too.
                enclosing: enclosingCaption
            )
            if labelSource != "title" { object["label_source"] = .string(labelSource) }
        } else {
            object["label_source"] = .string(labelSource == "unreadable" ? "unreadable" : "none")
        }
        if let value {
            object["value"] = secret
                ? MacInjectionResultRedaction.redactedSecret(value)
                // A row's own caption makes a short CVV a labeled secret, not a bare number.
                : valueRedaction ?? MacScreenViewTextRedaction.redactedLegendString(
                    value,
                    valueChars: valueChars,
                    under: label,
                    enclosing: enclosingCaption
                )
        }
        if secret { object["secret_field"] = .bool(true) }
        return .object(object)
    }
}
public struct MacScreenViewSnapshot: Sendable, Equatable {
    public let viewId: String
    public let capturedAt: Date
    public let scope: MacScreenCaptureScope
    public let bounds: MacAXFrame
    public let appName: String?
    public let windowTitle: String?
    public let marks: [MacScreenViewMark]
    public let windowIdentity: MacAXWindowIdentity?
    public init(
        viewId: String,
        capturedAt: Date,
        scope: MacScreenCaptureScope,
        bounds: MacAXFrame,
        appName: String?,
        windowTitle: String?,
        marks: [MacScreenViewMark],
        windowIdentity: MacAXWindowIdentity? = nil
    ) {
        self.viewId = viewId
        self.capturedAt = capturedAt
        self.scope = scope
        self.bounds = bounds
        self.appName = appName
        self.windowTitle = windowTitle
        self.marks = marks
        self.windowIdentity = windowIdentity
    }
    public func mark(_ number: Int) -> MacScreenViewMark? {
        marks.first { $0.mark == number }
    }
}
/// Keep only the latest fused view: earlier ids, expired views and undrawn marks refuse rather than reinterpret addresses. Resolution grants no
/// authority; ordinary effect gates and explicit replay’s body-bound single-use capability still apply.
@MainActor
public final class MacScreenViewStore {
    public nonisolated static let shared = MacScreenViewStore()
    public enum ResolveFailure: String, Sendable, Equatable, Error {
        case noView = "no_view"
        case staleView = "stale_view"
        case viewExpired = "view_expired"
        case unknownMark = "unknown_mark"
        public var guidance: String {
            switch self {
            case .noView:
                return "no fused view has been taken yet — call mac_view first"
            case .staleView:
                return "that view is not the latest one — the screen may have changed; call mac_view again"
            case .viewExpired:
                return "that view is older than \(Int(MacLookFrameStore.ttlSeconds))s — call mac_view again"
            case .unknownMark:
                return "that mark number is not in the latest view's legend"
            }
        }
    }
    private var latest: MacScreenViewSnapshot?
    private let publication = LatestRead()
    public nonisolated init() {}
    public func read(
        _ load: @Sendable () async -> (MacControlResult, MacScreenViewSnapshot?)
    ) async -> (value: MacControlResult, published: Bool) {
        var published = false
        do {
            let read = try await publication.read({
                let result = await load()
                guard result.0.ok, result.1 != nil else { throw MacSnapshotUnavailable(result: result.0) }
                return result
            }) { result in
                if let snapshot = result.1 { latest = snapshot; published = true }
            }
            return (read.0, published)
        } catch {
            return (MacSnapshotUnavailable.result(for: error), false)
        }
    }
    public func latestViewId() -> String? { latest?.viewId }
    public func snapshot(viewId: String) -> MacScreenViewSnapshot? {
        guard let latest, latest.viewId == viewId else { return nil }
        return latest
    }
    public func resolve(
        viewId: String,
        mark: Int,
        now: Date
    ) -> Result<MacScreenViewMark, ResolveFailure> {
        guard let latest else { return .failure(.noView) }
        guard latest.viewId == viewId else { return .failure(.staleView) }
        guard now.timeIntervalSince(latest.capturedAt) <= MacLookFrameStore.ttlSeconds else {
            return .failure(.viewExpired)
        }
        guard let hit = latest.mark(mark) else { return .failure(.unknownMark) }
        return .success(hit)
    }
    /// Input or completed motor work can invalidate the single live scene; retaining old handles would misdirect later acts.
    public func invalidate() {
        publication.write { latest = nil }
    }
}
/// A failed capture returns its own receipt without advancing LatestRead.
struct MacSnapshotUnavailable: Error {
    let result: MacControlResult
    static func result(for error: Error) -> MacControlResult {
        if let capture = error as? MacSnapshotUnavailable { return capture.result }
        return MacControlResult(ok: false, action: "screen", output: .object([
            "error": .string(error.localizedDescription),
        ]), error: "snapshot_read_failed", durationMs: 0)
    }
}
/// Derive x and y scales from returned pixels and captured bounds, never the display’s nominal Retina factor. Clamping, mirroring, mixed-scale
/// displays and downsampling can change effective scale independently on either axis.
public struct MacScreenViewGeometry: Sendable, Equatable {
    public let capture: MacImageCapture?
    public let bounds: MacAXFrame
    public let pixelWidth: Int
    public let pixelHeight: Int
    public init(bounds: MacAXFrame, pixelWidth: Int, pixelHeight: Int, capture: MacImageCapture? = nil) {
        self.capture = capture
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
    public init(shot: MacScreenShot) {
        self.init(bounds: shot.bounds, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight, capture: shot.capture)
    }
    public var scaleX: Double {
        bounds.w > 0 ? Double(pixelWidth) / bounds.w : 0
    }
    public var scaleY: Double {
        bounds.h > 0 ? Double(pixelHeight) / bounds.h : 0
    }
    /// Report the smaller scale when axes differ, but place marks with each measured axis separately.
    public var reportedScale: Double { min(scaleX, scaleY) }
    /// Clip placements to the image and omit wholly off-capture elements so markers cannot claim invisible positions.
    public func placement(mark: Int, frame: MacAXFrame) -> MacScreenMarkerPlacement? {
        guard scaleX > 0, scaleY > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let rect = imageRect(frame)
        let clampedX0 = max(0, min(rect.x, Double(pixelWidth)))
        let clampedY0 = max(0, min(rect.y, Double(pixelHeight)))
        let clampedX1 = max(0, min(rect.x + rect.w, Double(pixelWidth)))
        let clampedY1 = max(0, min(rect.y + rect.h, Double(pixelHeight)))
        let w = clampedX1 - clampedX0
        let h = clampedY1 - clampedY0
        guard w > 0, h > 0 else { return nil }
        return MacScreenMarkerPlacement(mark: mark, x: clampedX0, y: clampedY0, w: w, h: h)
    }
    /// Markability needs observed intersection even without pixels; the legend remains useful without an image.
    public func intersects(_ frame: MacAXFrame) -> Bool {
        guard frame.w > 0, frame.h > 0, bounds.w > 0, bounds.h > 0 else { return false }
        let noOverlap = frame.x >= bounds.x + bounds.w
            || frame.y >= bounds.y + bounds.h
            || frame.x + frame.w <= bounds.x
            || frame.y + frame.h <= bounds.y
        return !noOverlap
    }
    /// Invert the same measured scales for image-to-screen translation; off-image points remain unavailable.
    public func screenPoint(imageX x: Double, imageY y: Double) -> MacPointerPosition? {
        guard scaleX > 0, scaleY > 0,
              x >= 0, x < Double(pixelWidth), y >= 0, y < Double(pixelHeight) else { return nil }
        return MacPointerPosition(x: bounds.x + x / scaleX, y: bounds.y + y / scaleY)
    }
    public func imageRect(_ frame: MacAXFrame) -> VisionRect {
        VisionRect(x: (frame.x - bounds.x) * scaleX, y: (frame.y - bounds.y) * scaleY,
            w: frame.w * scaleX, h: frame.h * scaleY)
    }
    public func screenRect(_ rect: VisionRect) -> MacAXFrame {
        MacAXFrame(x: bounds.x + rect.x / scaleX, y: bounds.y + rect.y / scaleY,
            w: rect.w / scaleX, h: rect.h / scaleY)
    }
}
/// Immutable provenance describes the captured picture, never a second live window inventory.
public struct MacImageCapture: Sendable, Equatable, Codable {
    struct Window: Sendable, Equatable, Codable {
        let number: Int
        let pid: Int32
        let layer: Int
        let alpha: Double
        let x: Double, y: Double, w: Double, h: Double
        var frame: MacAXFrame { MacAXFrame(x: x, y: y, w: w, h: h) }
    }
    /// Unavailable inner AX regions cannot inherit an outer control’s identity.
    public struct PointTarget: Sendable, Equatable, Codable {
        let pid: Int32
        let role: String?
        let labelDigest: String?
        let x: Double, y: Double, w: Double, h: Double
        let path: [Int]
        var windowNumber: Int? = nil
        var frame: MacAXFrame { MacAXFrame(x: x, y: y, w: w, h: h) }
    }
    let capturedAt: Date
    let windows: [Window]
    let targets: [PointTarget]?

    public func recordingTargets(_ targets: [PointTarget]) -> Self {
        // Check other input owners live; an unrelated input-transparent backing must not replace the captured AX window.
        let owners = Set(targets.map(\.pid))
        let recorded = targets.map { target in
            var target = target
            target.windowNumber = windows.first { window in
                window.pid == target.pid && MacPointerPosition(x: target.x + target.w / 2, y: target.y + target.h / 2)
                    .map { $0.isInside(window.frame) } == true
            }?.number
            return target
        }
        return Self(capturedAt: capturedAt, windows: windows.filter { owners.contains($0.pid) }, targets: recorded)
    }

    /// Desktop composition retains front-to-back layers; masked layers carry no control evidence.
    public func composing(_ layers: [(number: Int, capture: MacImageCapture?)]) -> Self {
        Self(capturedAt: layers.compactMap { $0.capture?.capturedAt }.min() ?? capturedAt,
             windows: layers.compactMap { layer in windows.first { $0.number == layer.number } },
             targets: layers.flatMap { $0.capture?.targets ?? [] })
    }

    /// Keep transport provenance private to capture and delivery.
    public var json: JSONValue? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONValue.parse(data)
    }
    public static func from(_ json: JSONValue?) -> Self? {
        guard let json, let data = try? json.serializedData(pretty: false) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
/// Use each delivered picture’s measured geometry so image points map to real hand targets without assumed Retina scale. Random ids and per-session
/// retention refuse old or foreign images; hands recheck captured window and control identity.
public enum MacImageFrames {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var held: [(id: String, session: String, geometry: MacScreenViewGeometry)] = []
    public static func remember(_ geometry: MacScreenViewGeometry, id: String = "img-" + UUID().uuidString.prefix(8).lowercased(), turn: Turn) -> (
        fields: JSONValue,
        words: String) {
        let session = turn.session ?? ""
        lock.withLock {
            held.append((id, session, geometry))
            if held.count(where: { $0.session == session }) > 16,
               let oldest = held.firstIndex(where: { $0.session == session }) { held.remove(at: oldest) }
        }
        let b = geometry.bounds, w = geometry.pixelWidth, h = geometry.pixelHeight
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
        var fields: [String: JSONValue] = [
            "id": .string(id), "width": .int(Int64(w)), "height": .int(Int64(h)),
            "screen": .object(["x": .double(b.x), "y": .double(b.y), "w": .double(b.w), "h": .double(b.h)]),
        ]
        fields["captured_at"] = geometry.capture.map { .string(NativeTimestampFormat.plainZulu($0.capturedAt)) }
        return (.object(fields), "Image \(id) is \(w)×\(h) px covering screen points (\(n(b.x)), \(n(b.y))) \(n(b.w))×\(n(b.h)): "
            + "a point (ix, iy) in this image is screen point (\(n(b.x)) + ix*\(n(b.w))/\(w), \(n(b.y)) + iy*\(n(b.h))/\(h)); "
            + "no Retina factor to apply. act at:{x,y} takes this image's pixels as they are.")
    }
    public static func frame(_ id: String?, turn: Turn) -> (id: String, geometry: MacScreenViewGeometry)? {
        let session = turn.session ?? ""
        return lock.withLock {
            held.last { $0.session == session && (id == nil || $0.id == id) }
        }.map { ($0.id, $0.geometry) }
    }
}
