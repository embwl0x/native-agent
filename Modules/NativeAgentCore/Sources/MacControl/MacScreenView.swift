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
// Blueprint: | `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`; `MacScreenViewTextRedaction` owns field/prose secret-label vocabulary with distinct matching rules and shared AX/OCR caption geometry with caller-unit proximity; session-scoped `MacImageFrames` holds delivered pixel geometry under the semantic observation's reference (desktop images mint their own) |
#endif
//
// Normal computer use is: screenshot → the model guesses a coordinate → hope.
// This file is the other thing. It fuses the two perceptions the machine
// already has into ONE object:
//
//   • the PICTURE (ScreenCaptureKit) — what a human eye would see, and
//   • the STRUCTURE (the AX tree the read organ already walks) — what each
//     thing IS, where it really is, and what it can do.
//
// Every actionable element gets a NUMBERED MARKER drawn on the picture at its
// real frame, and the same number appears in a legend bound to that element's
// REAL AX path. She then acts by REFERENCE — `mac_click{mark: 2, view: …}` —
// and the exact pixel/element comes from the AX frame this organ captured,
// never from the model's arithmetic. Coordinates stay out of the model's hands
// unless there is nothing structured to point at (a canvas, a game, a video),
// which is exactly when the raw picture is still there to point into.
//
// THREE STRUCTURAL RULES, all load-bearing:
//   1. Complete secret inspection uses `MacAccessibilityReader`'s walker.
//      The read organ stays the single perception walker and stays
//      injection-free (no CGEvent, no PerformAction, no attribute write lives
//      here either — a view is a look).
//   2. Everything that can be tested without a window server IS separated from
//      everything that cannot: geometry, mark selection, the byte budget and
//      the legend are pure functions over value types; capture and rendering
//      are two injectable seams (`MacScreenCaptureSource`,
//      `MacScreenImageRenderer`).
//   3. A mark is a REFERENCE, not an authority. Resolving `mark: 2` yields an
//      element path/frame and nothing else; the injection gates upstream are
//      untouched by it. See `MacScreenViewStore`.
public enum MacScreenCaptureScope: String, Sendable, Equatable {
    /// The frontmost window's own rect (the default — "look at what I'm using").
    case focusedWindow = "focused_window"
    /// The whole main display.
    case fullScreen = "full_screen"
}
/// One frozen picture. `bounds` is the captured rect in SCREEN POINTS in the
/// same global, top-left-origin space AX reports element frames in — that
/// shared space is what makes the translation in `MacScreenViewGeometry`
/// exact rather than approximate.
public struct MacScreenShot: @unchecked Sendable {
    public let bounds: MacAXFrame
    public let pixelWidth: Int
    public let pixelHeight: Int
    #if canImport(CoreGraphics)
    /// The pixels. Optional so a test can drive the whole pipeline (geometry,
    /// caps, legend, store) with no window server and no image at all.
    public let cgImage: CGImage?
    public init(bounds: MacAXFrame, pixelWidth: Int, pixelHeight: Int, cgImage: CGImage? = nil) {
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cgImage = cgImage
    }
    #else
    public init(bounds: MacAXFrame, pixelWidth: Int, pixelHeight: Int) {
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
    #endif
}
/// Why no image came back. Always REPORTED, never silently swallowed — "I need
/// Screen Recording permission" is a true and actionable answer; a missing
/// `image` key with no reason is not.
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
            return Repair.why(owner: "macOS Screen Recording grant",
                tap: "System Settings > Privacy & Security > Screen Recording > NativeAgent",
                instruction: "Ask the owner to enable NativeAgent's Screen Recording grant, then follow macOS's restart instruction if shown.")
        case .noDisplay:
            return Repair.why(owner: "Mac display availability", tap: "Mac > connected display",
                instruction: "Connect or wake a display before requesting pixels; no display was available to capture.")
        case .unavailableOnThisPlatform:
            return Repair.terminal(instruction: "Screen capture is unavailable on this platform. Use a Mac with a graphical login session for pixels.")
        case .exceedsByteCap:
            return Repair.reconcile(instruction: "The image exceeds the delivery limit. Inspect mac.look's region selector, then request a smaller named part rather than the same capture.",
                nextCall: .object(["tool": .string("app"), "input": .object(["find": .string("mac.look")])]))
        case .encodeFailed:
            return Repair.reconcile(instruction: "Image encoding failed. Inspect the app's menu without capturing pixels; encoding needs repair before another image request.",
                nextCall: .object(["tool": .string("app"), "input": .object([
                    "action": .string("mac.menu"), "args": .object(args)])]))
        case .captureFailed, .operationFailed:
            return Repair.reconcile(instruction: "\(errorDescription ?? rawValue). Inspect the app's menu without capturing pixels to establish available controls; correct the capture failure before another image request.",
                nextCall: .object(["tool": .string("app"), "input": .object([
                    "action": .string("mac.menu"), "args": .object(args)])]))
        }
    }
}
/// The injectable capture seam. Production is `SystemMacScreenCaptureSource`
/// (ScreenCaptureKit); tests inject a synthetic shot.
///
/// Screen Recording is its OWN TCC permission, separate from Accessibility.
/// `isScreenRecordingTrusted()` is a read-only preflight: it never prompts and
/// never toggles. The grant is User's click in System Settings.
public protocol MacScreenCaptureSource: Sendable {
    func isScreenRecordingTrusted() -> Bool
    /// - Parameter rect: the region to capture in global screen POINTS, or nil
    ///   for the whole main display.
    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure>
    /// Capture only this window's pixels, independently of covering windows.
    /// Never substitute a desktop crop when the source cannot honor identity.
    func capture(window: MacAXWindowIdentity) async -> Result<MacScreenShot, MacScreenCaptureFailure>
    /// One enumeration of the windows on screen, then any of them by its exact
    /// window number (never a sibling at the same frame), no wider than
    /// `maxPixelWidth`: what a composite of many windows needs.
    func windowCapture() async -> MacScreenWindowCapture
}
public typealias MacScreenWindowCapture = @Sendable (_ windowNumber: Int, _ maxPixelWidth: Int) async -> Result<MacScreenShot, MacScreenCaptureFailure>
public extension MacScreenCaptureSource {
    func capture(window: MacAXWindowIdentity) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        .failure(.captureFailed)
    }
    func windowCapture() async -> MacScreenWindowCapture {
        { _, _ in .failure(.captureFailed) }
    }
}
/// Where one marker goes, in FULL-RESOLUTION pixels of the shot, top-left
/// origin (the space the image is in, not the space AX is in).
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
/// Masks secret frames, draws the numbered markers and encodes. Injectable so the byte-budget ladder
/// and the placement math are testable with no pixels involved.
public protocol MacScreenImageRenderer: Sendable {
    /// - Parameter downscale: 1.0 = native pixels. The renderer applies it to
    ///   BOTH the image and the marker geometry, so a marker never drifts off
    ///   its element when the image shrinks to fit the byte cap.
    func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        secretFrames: [MacAXFrame],
        downscale: Double
    ) -> Data?
}
/// One numbered thing on screen. `path` is the SAME child-index path
/// `ax_tree`/`ax_find` hand out, so `mark → path → live element` is exact and
/// the act path resolves it fresh at act time (never a stale handle).
public struct MacScreenViewMark: Sendable, Equatable {
    public let mark: Int
    public let role: String
    public let subrole: String?
    public let label: String?
    /// Where `label` came from: `title` (the app said so), `value` (the control
    /// shows its own content, e.g. a popup button), `nearby_text` (INFERRED
    /// from the static text sitting immediately left of / above it, the way a
    /// human reads a form), or `none`. Named rather than hidden because an
    /// inferred label is a guess and the caller deserves to know which rows are
    /// guesses — an unlabeled control is a real thing and pretending otherwise
    /// is how "the third button" becomes the wrong button.
    public let labelSource: String
    public let value: String?
    /// True when this element is a password/secure field. Its value NEVER
    /// leaves in the clear — see `toJSON()`.
    public let secret: Bool
    public let enabled: Bool
    public let frame: MacAXFrame
    public let path: [Int]
    public let actions: [String]
    public let settableAttributes: [String]
    /// Secret-naming ancestor groups, resolved from the complete window node set at capture time.
    public let enclosingCaption: MacScreenViewTextRedaction.EnclosingCaptionKinds
    /// Redaction objects judged against the complete captured node context.
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
        enabled: Bool = true,
        frame: MacAXFrame,
        path: [Int],
        actions: [String] = [],
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
        self.settableAttributes = settableAttributes
        self.enclosingCaption = enclosingCaption
        self.labelRedaction = labelRedaction
        self.valueRedaction = valueRedaction
    }
    /// The legend row the model sees.
    ///
    /// REDACTION: a secure text field's value rides out as count + digest via
    /// the SAME `MacInjectionResultRedaction.redactedSecret` shape the injection
    /// result path uses. The fused view is a perception surface with a very
    /// wide blast radius — it is persisted in the turn trace and can sync to
    /// iOS/Telegram — so a password sitting in a legend row would be strictly
    /// worse than the injection leak that redaction was built to close.
    public func toJSON(valueChars: Int = MacAXLimits.hardValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "mark": .int(Int64(mark)),
            "role": .string(role),
            "enabled": .bool(enabled),
            "frame": frame.toJSON(),
            "path": .array(path.map { .int(Int64($0)) }),
            "actions": .array(actions.map { .string($0) }),
            "settable_attributes": .array(settableAttributes.map { .string($0) }),
        ]
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
            object["label_source"] = .string("none")
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
/// The whole frozen scene, as remembered for later mark resolution.
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
/// Remembers the LATEST fused view so a later `mark` can be resolved to a real
/// element — and refuses everything else.
///
/// A mark is meaningful only with its captured view id; resolve only the latest view:
///   • a view id from any EARLIER view  → `stale_view` (take a fresh mac_view)
///   • the latest view past its TTL     → `view_expired`
///   • a number that was never drawn    → `unknown_mark`
/// Single-slot on purpose: "the last view" is the only view whose numbers can
/// still be trusted, and a strictly-one-live-view rule cannot be reasoned
/// around by holding several tokens.
///
/// IT GRANTS NO AUTHORITY. Resolution returns an element path and frame. The
/// injection gates (accessibility category, ACTIVE Full Mac window, and a
/// body-bound single-use `MacInjectionCapability` minted only after a resolved
/// human approval) all sit UPSTREAM of the handler that consults this store, so
/// a mark can only ever redirect an already-approved act at a better target.
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
    /// Forget the frozen scene because a physical user input or a completed
    /// motor action may have changed it. This is a safety invalidation, not a
    /// history deletion: the store intentionally owns only one live view.
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
/// AX screen points → image pixels.
///
/// Both spaces share an origin convention (top-left, y down) — AX element
/// frames and the Quartz display space are the same coordinate system, and the
/// capture is requested for an explicit rect in that system. So the whole
/// translation is one affine map, and the only thing that can be wrong is the
/// SCALE.
///
/// HOW THE SCALE IS OBTAINED, and why it is not `backingScaleFactor`: it is
/// DERIVED from the capture that actually came back —
/// `pixelWidth / bounds.w`. Asking `NSScreen.backingScaleFactor` is asking
/// what the display is; dividing the returned pixel count by the requested
/// point rect is measuring what the IMAGE is. Those disagree whenever the
/// capture pipeline clamps a size, a display is mirrored or scaled, the window
/// straddles a 1x and a 2x screen, or the shot is downsampled — and every one
/// of those disagreements would put every marker in the wrong place. x and y
/// are derived independently for the same reason: a non-square effective scale
/// is unusual but it is not impossible, and assuming it away is how a marker
/// ends up half a button low.
public struct MacScreenViewGeometry: Sendable, Equatable {
    public let bounds: MacAXFrame
    public let pixelWidth: Int
    public let pixelHeight: Int
    public init(bounds: MacAXFrame, pixelWidth: Int, pixelHeight: Int) {
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
    public init(shot: MacScreenShot) {
        self.init(bounds: shot.bounds, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight)
    }
    public var scaleX: Double {
        bounds.w > 0 ? Double(pixelWidth) / bounds.w : 0
    }
    public var scaleY: Double {
        bounds.h > 0 ? Double(pixelHeight) / bounds.h : 0
    }
    /// The single scale reported to the caller. When x and y agree (the normal
    /// case) this is that number; when they do not, the smaller one is the
    /// honest summary — but the PLACEMENTS always use both axes separately.
    public var reportedScale: Double { min(scaleX, scaleY) }
    /// Translate one AX frame into full-resolution image pixels, clipped to the
    /// image. Returns nil when the element lies entirely outside the capture —
    /// which is a real thing (an off-screen or scrolled-away control), and
    /// drawing a marker for it would be a lie about where it is.
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
    /// True when any part of the frame falls inside the captured rect. Used to
    /// decide whether an element is markable at all, independently of whether
    /// an image came back (the legend is still worth having with no picture).
    public func intersects(_ frame: MacAXFrame) -> Bool {
        guard frame.w > 0, frame.h > 0, bounds.w > 0, bounds.h > 0 else { return false }
        let noOverlap = frame.x >= bounds.x + bounds.w
            || frame.y >= bounds.y + bounds.h
            || frame.x + frame.w <= bounds.x
            || frame.y + frame.h <= bounds.y
        return !noOverlap
    }
    /// Image pixels → global screen points: `placement` run backwards, on the
    /// same two measured scales. Nil off the image.
    public func screenPoint(imageX x: Double, imageY y: Double) -> MacPointerPosition? {
        guard scaleX > 0, scaleY > 0, (0...Double(pixelWidth)).contains(x), (0...Double(pixelHeight)).contains(y) else { return nil }
        return MacPointerPosition(x: bounds.x + x / scaleX, y: bounds.y + y / scaleY)
    }
    /// Global screen points to image pixels, without clipping or rounding.
    public func imageRect(_ frame: MacAXFrame) -> VisionRect {
        VisionRect(x: (frame.x - bounds.x) * scaleX, y: (frame.y - bounds.y) * scaleY,
            w: frame.w * scaleX, h: frame.h * scaleY)
    }
    /// Source-image pixels to global logical bounds, without clipping or rounding.
    public func screenRect(_ rect: VisionRect) -> MacAXFrame {
        MacAXFrame(x: bounds.x + rect.x / scaleX, y: bounds.y + rect.y / scaleY,
            w: rect.w / scaleX, h: rect.h / scaleY)
    }
}
/// Every image she is handed is a frame: the pixels delivered and the global
/// screen rect they cover, so a point she reads off the picture is a place
/// her hand can go, by the picture's own measured scale and never an assumed
/// Retina factor. Ids are random, so an old id is refused rather than meaning
/// another picture. Each chat session holds its own last 16; an id or "the
/// latest" is looked up only among the asking session's.
public enum MacImageFrames {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var held: [(id: String, session: String, geometry: MacScreenViewGeometry)] = []
    /// Keep a delivered image; its receipt fields and the sentence that reads them.
    public static func remember(_ geometry: MacScreenViewGeometry, id: String = "img-" + UUID().uuidString.prefix(8).lowercased()) -> (fields: JSONValue, words: String) {
        let session = PersonOnlyWindows.driver?.session ?? ""
        lock.withLock {
            held.append((id, session, geometry))
            if held.count(where: { $0.session == session }) > 16,
               let oldest = held.firstIndex(where: { $0.session == session }) { held.remove(at: oldest) }
        }
        let b = geometry.bounds, w = geometry.pixelWidth, h = geometry.pixelHeight
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
        return (.object([
            "id": .string(id), "width": .int(Int64(w)), "height": .int(Int64(h)),
            "screen": .object(["x": .double(b.x), "y": .double(b.y), "w": .double(b.w), "h": .double(b.h)]),
        ]), "Image \(id) is \(w)×\(h) px covering screen points (\(n(b.x)), \(n(b.y))) \(n(b.w))×\(n(b.h)): "
            + "a point (ix, iy) in this image is screen point (\(n(b.x)) + ix*\(n(b.w))/\(w), \(n(b.y)) + iy*\(n(b.h))/\(h)); "
            + "no Retina factor to apply. act at:{x,y} takes this image's pixels as they are.")
    }
    /// This session's image by id, or its latest when no id is given.
    public static func frame(_ id: String?) -> (id: String, geometry: MacScreenViewGeometry)? {
        let session = PersonOnlyWindows.driver?.session ?? ""
        return lock.withLock {
            held.last { $0.session == session && (id == nil || $0.id == id) }
        }.map { ($0.id, $0.geometry) }
    }
}
