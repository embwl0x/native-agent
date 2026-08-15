import Foundation
import NativeAgentCore
import PersistenceCore
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
#endif

// MARK: - The FUSED VIEW organ (W3.5)
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
//   1. This file NEVER walks AX itself. It consumes `MacAccessibilityReader`'s
//      nodes. The read organ stays the single perception walker and stays
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

// MARK: - Capture seam

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
public enum MacScreenCaptureFailure: String, Sendable, Equatable, Error {
    case screenRecordingNotTrusted = "screen_recording_not_trusted"
    case noDisplay = "no_display"
    case captureFailed = "capture_failed"
    case unavailableOnThisPlatform = "screen_capture_unavailable_on_this_platform"
    case encodeFailed = "image_encode_failed"
    case exceedsByteCap = "image_exceeds_byte_cap"
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
}

// MARK: - Render seam

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

/// Draws the numbered markers and encodes. Injectable so the byte-budget ladder
/// and the placement math are testable with no pixels involved.
public protocol MacScreenImageRenderer: Sendable {
    /// - Parameter downscale: 1.0 = native pixels. The renderer applies it to
    ///   BOTH the image and the marker geometry, so a marker never drifts off
    ///   its element when the image shrinks to fit the byte cap.
    func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data?
}

// MARK: - Legend

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
    /// W3.5-FIX-R4 — the secret-naming ancestor GROUPS this control sits
    /// inside, resolved at capture time from the same window's node set. A form
    /// captions its CVV box by ENCLOSING it, not by sitting left of it, and the
    /// mark has no other way to know.
    public let enclosingCaption: MacScreenViewTextRedaction.EnclosingCaptionKinds

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
        enclosingCaption: MacScreenViewTextRedaction.EnclosingCaptionKinds = .none
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
        self.enclosingCaption = enclosingCaption
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
        ]
        if let subrole { object["subrole"] = .string(subrole) }
        if let label {
            // W3.5-FIX 1 — a legend NAME can be a secret too. `nearby_text`
            // inference names an unlabeled control from the text beside it, and
            // the text beside a code field is frequently the code itself; a
            // title can also literally be the code. Same shape test as the
            // prose channel, applied here so no channel is the weak one.
            object["label"] = MacScreenViewTextRedaction.redactedLegendString(
                label,
                valueChars: valueChars,
                // W3.5-FIX-R4 — an untitled field's inferred label is very
                // often its own VALUE ("451"), so the enclosing caption has to
                // reach this channel too or the CVV leaks as a NAME.
                enclosing: enclosingCaption
            )
            if labelSource != "title" { object["label_source"] = .string(labelSource) }
        } else {
            object["label_source"] = .string("none")
        }
        if let value {
            object["value"] = secret
                ? MacInjectionResultRedaction.redactedSecret(value)
                // `under: label` — W3.5-FIX-R2 3. A legend row carries its own
                // caption, so a non-secure field captioned "CVV" showing three
                // digits is the labeled shape, not a bare number.
                : MacScreenViewTextRedaction.redactedLegendString(
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

    public init(
        viewId: String,
        capturedAt: Date,
        scope: MacScreenCaptureScope,
        bounds: MacAXFrame,
        appName: String?,
        windowTitle: String?,
        marks: [MacScreenViewMark]
    ) {
        self.viewId = viewId
        self.capturedAt = capturedAt
        self.scope = scope
        self.bounds = bounds
        self.appName = appName
        self.windowTitle = windowTitle
        self.marks = marks
    }

    public func mark(_ number: Int) -> MacScreenViewMark? {
        marks.first { $0.mark == number }
    }
}

// MARK: - View store (the staleness boundary)

/// Remembers the LATEST fused view so a later `mark` can be resolved to a real
/// element — and refuses everything else.
///
/// WHY A TOKEN AT ALL. A mark number is only meaningful against the picture it
/// was drawn on. The UI moves: a menu closes, a list scrolls, a dialog appears,
/// and mark 2 is now a different control. Accepting a bare `mark: 2` would
/// therefore be exactly the coordinate-guessing failure mode this whole wave
/// exists to kill, just with a smaller number. So a mark call must carry the
/// opaque `view` id it came from, and this store answers only for the view it
/// most recently recorded:
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
public actor MacScreenViewStore {
    public static let shared = MacScreenViewStore()

    /// A view older than this is not a description of the screen any more.
    public static let ttlSeconds: TimeInterval = 180

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
                return "that view is older than \(Int(MacScreenViewStore.ttlSeconds))s — call mac_view again"
            case .unknownMark:
                return "that mark number is not in the latest view's legend"
            }
        }
    }

    private var latest: MacScreenViewSnapshot?

    public init() {}

    public func record(_ snapshot: MacScreenViewSnapshot) {
        latest = snapshot
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
        guard now.timeIntervalSince(latest.capturedAt) <= Self.ttlSeconds else {
            return .failure(.viewExpired)
        }
        guard let hit = latest.mark(mark) else { return .failure(.unknownMark) }
        return .success(hit)
    }

    /// Test seam only: forget everything. Never called on a production path.
    public func reset() { latest = nil }
}

// MARK: - Geometry (THE CRUX)

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
        let x0 = (frame.x - bounds.x) * scaleX
        let y0 = (frame.y - bounds.y) * scaleY
        let x1 = (frame.x + frame.w - bounds.x) * scaleX
        let y1 = (frame.y + frame.h - bounds.y) * scaleY
        let clampedX0 = max(0, min(x0, Double(pixelWidth)))
        let clampedY0 = max(0, min(y0, Double(pixelHeight)))
        let clampedX1 = max(0, min(x1, Double(pixelWidth)))
        let clampedY1 = max(0, min(y1, Double(pixelHeight)))
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
}

// MARK: - Pure fusion logic

public enum MacScreenViewBuilder {
    /// Hard ceilings. A 4K capture of a dense app can offer hundreds of
    /// actionable elements and ~10 MB of pixels; either one alone would eat the
    /// turn. A caller may lower these, never raise them.
    public static let hardMaxMarks = 60
    public static let hardMaxImageBytes = 600_000
    /// The prose channel is capped too: a document window can expose thousands
    /// of static-text nodes, and an unbounded dump would drown the legend it
    /// exists to complete.
    public static let hardMaxTextItems = 80

    /// Roles that are worth a number even when the app advertises no AX action
    /// for them. Two families:
    ///   • CLICKABLE — the things a human would point at.
    ///   • SCROLLABLE — the things a human would scroll; they are rarely
    ///     "pressable" but `mac_scroll` needs somewhere to aim.
    public static let clickableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField", "AXTextArea",
        "AXSecureTextField", "AXSearchField", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXStepper", "AXDisclosureTriangle", "AXTabButton",
        "AXToolbarButton", "AXColorWell", "AXSegmentedControl",
    ]

    public static let scrollableRoles: Set<String> = [
        "AXScrollArea", "AXScrollBar", "AXTable", "AXOutline", "AXList",
        "AXWebArea", "AXCollection",
    ]

    /// Secure fields, by the marker macOS itself publishes plus the labels apps
    /// use when they roll their own. Over-inclusive on purpose: a false
    /// positive costs a legend row's readability, a false negative costs a
    /// password.
    public static let secretLabelHints: [String] = [
        "password", "passcode", "passphrase", "secret", "api key", "api-key",
        "token", "pin code", "security code", "2fa", "one-time code",
    ]

    public static func isSecretField(role: String, subrole: String?, label: String?) -> Bool {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        guard let label = label?.lowercased(), !label.isEmpty else { return false }
        return secretLabelHints.contains { label.contains($0) }
    }

    /// Is this element worth a number? Actionable (it advertises any AX action)
    /// or structurally clickable/scrollable by role. Everything else — static
    /// text, groups, decoration — stays unmarked so the picture does not turn
    /// into confetti.
    public static func isMarkable(_ attributes: MacAXAttributes) -> Bool {
        if !attributes.actions.isEmpty { return true }
        if clickableRoles.contains(attributes.role) { return true }
        if scrollableRoles.contains(attributes.role) { return true }
        return false
    }

    public struct Selection: Sendable, Equatable {
        public let marks: [MacScreenViewMark]
        /// Markable elements dropped because the mark cap was reached.
        public let omitted: Int
        /// Markable elements with no frame, or a frame entirely outside the
        /// captured rect. Counted, never silently dropped.
        public let offscreen: Int
        public var truncated: Bool { omitted > 0 }
    }

    /// Number the markable elements in READING ORDER — top-to-bottom in 8-point
    /// row bands, then left-to-right inside a band, then document order. That
    /// is how a human scans a GUI, so "the third button along the toolbar" is
    /// the third number, and it is fully deterministic: two captures of an
    /// unchanged screen produce the same numbering.
    public static func select(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        maxMarks: Int = hardMaxMarks
    ) -> Selection {
        let cap = max(1, min(maxMarks, hardMaxMarks))
        var candidates: [(frame: MacAXFrame, node: MacAXNode)] = []
        var offscreen = 0
        for node in nodes {
            guard isMarkable(node.attributes) else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0 else {
                offscreen += 1
                continue
            }
            guard geometry.intersects(frame) else {
                offscreen += 1
                continue
            }
            candidates.append((frame, node))
        }
        candidates.sort { lhs, rhs in
            let lhsBand = (lhs.frame.y / 8.0).rounded(.down)
            let rhsBand = (rhs.frame.y / 8.0).rounded(.down)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
            return pathIsBefore(lhs.node.path, rhs.node.path)
        }
        let kept = candidates.prefix(cap)
        var marks: [MacScreenViewMark] = []
        marks.reserveCapacity(kept.count)
        // W3.5-FIX-R4 — built once from the WHOLE node set (an enclosing group
        // is never itself markable, so it is not in `candidates`).
        let captions = MacScreenViewTextRedaction.enclosingCaptions(nodes)
        for (index, candidate) in kept.enumerated() {
            let attributes = candidate.node.attributes
            let named = inferLabel(for: candidate.node, frame: candidate.frame, among: nodes)
            let label = named.label
            marks.append(MacScreenViewMark(
                mark: index + 1,
                role: attributes.role,
                subrole: attributes.subrole,
                label: label,
                labelSource: named.source,
                value: attributes.value,
                secret: isSecretField(
                    role: attributes.role,
                    subrole: attributes.subrole,
                    label: label
                ),
                enabled: attributes.enabled,
                frame: candidate.frame,
                path: candidate.node.path,
                actions: attributes.actions,
                enclosingCaption: MacScreenViewTextRedaction.enclosingKinds(
                    forNodeAt: candidate.frame,
                    path: candidate.node.path,
                    among: captions
                )
            ))
        }
        return Selection(
            marks: marks,
            omitted: max(0, candidates.count - kept.count),
            offscreen: offscreen
        )
    }

    /// Give every numbered control a NAME, and say where the name came from.
    ///
    /// THE EFFORTLESS-VISION BAR (User, 2026-08-12): an LLM reads structured
    /// text losslessly and pixels with effort, so the legend has to be enough
    /// on its own — "mark 4: AXButton, no label" fails that bar and sends her
    /// back to squinting at the screenshot. Apps leave controls untitled all
    /// the time (an icon button, a field whose only name is the caption beside
    /// it), and a human reads those the same way this does: take what the
    /// control says about itself, else take the text sitting immediately to its
    /// left or directly above it.
    ///
    /// The inference is deliberately narrow and deterministic — nearest static
    /// text within 240 points, on the same row (vertically overlapping) or
    /// directly above with horizontal overlap, closest wins, path order breaks
    /// ties — and it is always LABELLED as an inference, because a guessed name
    /// presented as a fact is how a confident click lands on the wrong control.
    public static func inferLabel(
        for node: MacAXNode,
        frame: MacAXFrame,
        among nodes: [MacAXNode]
    ) -> (label: String?, source: String) {
        if let title = node.attributes.title, !title.isEmpty { return (title, "title") }
        // A popup button / checkbox often carries its meaning in its value.
        if !isSecretField(role: node.attributes.role, subrole: node.attributes.subrole, label: nil),
           let value = node.attributes.value?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty, value.count <= 60 {
            return (value, "value")
        }
        var best: (text: String, distance: Double, path: [Int])?
        for candidate in nodes {
            guard textRoles.contains(candidate.attributes.role) else { continue }
            guard let text = candidate.attributes.title ?? candidate.attributes.value,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let other = candidate.attributes.frame, other.w > 0, other.h > 0 else { continue }
            let sameRow = other.y < frame.y + frame.h && other.y + other.h > frame.y
            let toTheLeft = other.x + other.w <= frame.x + 1
            let above = other.y + other.h <= frame.y + 1
            let horizontallyOverlapping = other.x < frame.x + frame.w && other.x + other.w > frame.x
            let distance: Double
            if sameRow, toTheLeft {
                distance = frame.x - (other.x + other.w)
            } else if above, horizontallyOverlapping {
                distance = frame.y - (other.y + other.h)
            } else {
                continue
            }
            guard distance >= 0, distance <= 240 else { continue }
            if let current = best,
               !(distance < current.distance
                 || (distance == current.distance && pathIsBefore(candidate.path, current.path))) {
                continue
            }
            best = (text.trimmingCharacters(in: .whitespacesAndNewlines), distance, candidate.path)
        }
        if let best { return (best.text, "nearby_text") }
        return (nil, "none")
    }

    /// Roles that carry readable prose rather than behaviour.
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLabel", "AXValueIndicator",
    ]

    public struct VisibleText: Sendable, Equatable {
        public let text: String
        public let frame: MacAXFrame
        /// Non-nil when this line was judged to be a secret shown as PROSE (an
        /// on-screen 2FA code, a revealed API key, a masked password run). The
        /// characters then never leave — see `toJSON()`. Set by
        /// `MacScreenViewTextRedaction`, never by a caller.
        public let redactionReason: String?

        public init(text: String, frame: MacAXFrame, redactionReason: String? = nil) {
            self.text = text
            self.frame = frame
            self.redactionReason = redactionReason
        }

        public func toJSON(valueChars: Int = MacAXLimits.hardValueChars) -> JSONValue {
            .object([
                "text": redactionReason.map {
                    MacScreenViewTextRedaction.redactedText(text, reason: $0)
                } ?? .string(MacAccessibilityReader.truncate(text, to: valueChars)),
                "frame": frame.toJSON(),
            ])
        }
    }

    public struct TextSelection: Sendable, Equatable {
        public let items: [VisibleText]
        public let omitted: Int
    }

    /// What the window SAYS, in reading order — the part of the screen that is
    /// prose rather than controls. Without this the legend describes a set of
    /// controls floating in a void; with it, the legend alone answers "what is
    /// on screen and what does it say", which is the bar the image is not
    /// supposed to be needed for.
    public static func visibleText(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        limit: Int = hardMaxTextItems
    ) -> TextSelection {
        let cap = max(1, min(limit, hardMaxTextItems))
        var candidates: [(frame: MacAXFrame, text: String, path: [Int])] = []
        var seen: Set<String> = []
        for node in nodes {
            guard textRoles.contains(node.attributes.role) else { continue }
            guard let raw = node.attributes.title ?? node.attributes.value else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0,
                  geometry.intersects(frame) else { continue }
            // Repeated boilerplate (a table's repeated column text) adds no
            // information and eats the cap.
            let key = "\(text)|\(Int(frame.x))|\(Int(frame.y))"
            guard seen.insert(key).inserted else { continue }
            candidates.append((frame, text, node.path))
        }
        candidates.sort { lhs, rhs in
            let lhsBand = (lhs.frame.y / 8.0).rounded(.down)
            let rhsBand = (rhs.frame.y / 8.0).rounded(.down)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
            return pathIsBefore(lhs.path, rhs.path)
        }
        let kept = candidates.prefix(cap)
        // W3.5-FIX 1 — the prose channel is a SECRET CHANNEL too. Marking the
        // secure FIELD's value was only half the job: a 2FA code, a recovery
        // code or a revealed API key is usually STATIC TEXT on the page, not a
        // field value, and this array is persisted in the turn trace and can
        // sync to iOS/Telegram. Redaction happens HERE, at the source, so no
        // caller can construct an un-redacted text channel.
        return TextSelection(
            items: MacScreenViewTextRedaction.applied(
                to: kept.map { VisibleText(text: $0.text, frame: $0.frame) },
                paths: kept.map(\.path),
                enclosing: MacScreenViewTextRedaction.enclosingCaptions(nodes)
            ),
            omitted: max(0, candidates.count - kept.count)
        )
    }

    private static func pathIsBefore(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return lhs.count < rhs.count
    }

    /// Fit the annotated image under a byte cap by stepping DOWN a fixed
    /// resolution ladder, taking the first rung that fits.
    ///
    /// Honest by construction: when no rung fits, this returns nil and the
    /// caller reports `image_exceeds_byte_cap` instead of shipping a truncated
    /// or silently-absent image. The ladder is fixed (not a binary search) so
    /// the same screen always produces the same bytes.
    public static func fitImage(
        maxBytes: Int,
        ladder: [Double] = [1.0, 0.75, 0.5, 0.35, 0.25],
        encode: (Double) -> Data?
    ) -> (data: Data, downscale: Double)? {
        let cap = max(1, maxBytes)
        for rung in ladder {
            guard let data = encode(rung) else { continue }
            if data.count <= cap { return (data, rung) }
        }
        return nil
    }
}

// MARK: - Secrets in the PROSE channel (W3.5-FIX 1)

/// Keeps a secret that is merely DISPLAYED out of the fused view's text channel.
///
/// THE HOLE THIS CLOSES. `MacScreenViewMark` redacts a secure text FIELD's
/// value, which covers a password being typed. It does not cover the far more
/// common shape: the secret is already on the screen as ordinary text — the
/// 2FA code in the SMS banner, the recovery codes a site shows once, the API
/// key a dashboard reveals, the masked bullets of a password field an app drew
/// itself. Those arrive as `AXStaticText` and rode out of `mac_view` verbatim,
/// into the persisted turn trace and every surface that syncs it.
///
/// THE BAR, both ways. Over-redaction blinds the perception organ this wave
/// exists to build: a sentence containing the word "password" is prose, and
/// blanking it makes her unable to read her own screen. Under-redaction leaks
/// an account. So the test is never "does this text mention a secret" — it is
/// "is this text ITSELF a secret", which is a question about SHAPE:
///
///   • a lone 6–8 digit code (an OTP and nothing else in the line);
///   • a long high-entropy single token, or one carrying a known key prefix;
///   • a run of bullets/asterisks (a masked field, drawn as text);
///   • `label: value` on one line where the label names a secret and the value
///     is a single token — "API key: sk-live-…";
///   • a code-shaped token sitting immediately right of / below a SHORT label
///     that names a secret — the same proximity heuristic the legend uses to
///     name an unlabeled control, because a form reads the same way either way.
///
/// Everything else passes through. Prose is long, multi-word, and punctuated;
/// none of the five shapes above can match it.
public enum MacScreenViewTextRedaction {
    /// Words that make a SHORT nearby line a secret LABEL. Matched only against
    /// labels (≤ `maxLabelChars`), never against the body of a sentence.
    public static let secretLabelTokens: [String] = [
        "2fa", "two-factor", "two factor", "one-time", "one time", "otp",
        "password", "passcode", "passphrase", "api key", "api-key", "apikey",
        "secret", "token", "recovery", "security code", "verification code",
        "auth code", "authentication code", "access key", "private key",
        "pin", "code",
        // W3.5-FIX-R2 3 — the shapes round 1 missed.
        "cvv", "cvc", "csc", "card verification", "card security",
        "seed phrase", "recovery phrase", "seed words", "recovery words",
        "mnemonic", "backup phrase", "secret phrase", "card number",
    ]

    /// A label naming the 3–4 digit code on the back of a card. Split out from
    /// `secretLabelTokens` because its VALUE is shorter than any other secret
    /// we redact — three digits — and only a label this specific earns the
    /// right to darken something that short. "Security code" lives here AND in
    /// the generic list; the disqualifier pass never applies to these.
    public static let cardVerificationLabelTokens: [String] = [
        "cvv", "cvc", "csc", "cvv2", "cid",
        "security code", "card verification", "card security",
    ]

    /// A label naming a wallet's recovery words. Under one of these, a run of
    /// lowercase words far SHORTER than the unlabeled bar is still the secret.
    public static let seedPhraseLabelTokens: [String] = [
        "seed phrase", "recovery phrase", "seed words", "recovery words",
        "mnemonic", "backup phrase", "secret phrase", "secret recovery phrase",
    ]

    /// Function words that are common in English prose. Used ONLY as a
    /// false-positive guard on the unlabeled seed-phrase shape: a run of
    /// lowercase words containing any of these is a sentence, not a wallet
    /// backup. Deliberately conservative — a wordlist phrase that happens to
    /// contain one of these is MISSED rather than prose being darkened, and an
    /// explicitly labeled phrase is caught regardless of this list.
    public static let proseFunctionWords: Set<String> = [
        "the", "and", "that", "this", "with", "for", "are", "was", "not",
        "but", "have", "from", "they", "his", "her", "has", "had", "were",
        "been", "will", "can", "out", "how", "why", "when", "what", "who",
        "which", "there", "here", "then", "than", "into", "just", "like",
        "some", "more", "most", "only", "very", "after", "before", "because",
        "them", "him", "your", "our", "their", "its", "would", "could",
        "should", "said", "says", "our", "you",
    ]

    /// "Code" is the most useful indicator and the most dangerous one: a screen
    /// is full of zip codes, area codes, promo codes and error codes. A label
    /// whose "code" is qualified by any of these is not naming a secret.
    public static let codeDisqualifiers: [String] = [
        "zip", "postal", "post code", "area", "country", "dial", "promo",
        "coupon", "discount", "error", "status", "color", "colour", "qr",
        "barcode", "bar code", "source", "product", "language", "currency",
        "airport", "region", "state", "sort code", "swift code", "referral",
        "invite", "tracking",
    ]

    /// Known secret prefixes: short but unambiguous, so they bypass the length
    /// bar an unlabeled random token has to clear.
    public static let knownSecretPrefixes: [String] = [
        "sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_",
        "github_pat_", "xoxb-", "xoxp-", "xoxa-", "akia", "asia", "aiza",
        "ya29.", "eyj", "npm_", "glpat-", "shpat_",
    ]

    /// A label longer than this is a sentence, not a caption.
    public static let maxLabelChars = 40
    /// A redactable VALUE is a token, not a paragraph.
    public static let maxValueChars = 128
    /// Same reach the legend's label inference uses, for the same reason.
    public static let proximityPoints: Double = 240

    /// The replacement: never the characters, always enough to audit them.
    /// Same digest shape as `MacInjectionResultRedaction.redactedSecret`, plus
    /// the reason — a caller deserves to know WHY a line went dark, otherwise
    /// redaction is indistinguishable from the organ failing to see.
    public static func redactedText(_ secret: String, reason: String) -> JSONValue {
        guard case .object(var object) =
            MacInjectionResultRedaction.redactedSecret(secret) else {
            return .object(["redacted": .bool(true), "reason": .string(reason)])
        }
        object["reason"] = .string(reason)
        return .object(object)
    }

    /// Is this line, ON ITS OWN, a secret? Independent of neighbours, so it
    /// also guards the legend's labels and values.
    public static func standaloneSecretReason(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isMaskedRun(text) { return "masked_secret" }
        if isOneTimeCode(text) { return "otp_shape" }
        if let inline = inlineLabeledSecretReason(text) { return inline }
        // W3.5-FIX-R2 3 — the four shapes round 1's heuristic could not see.
        // Ordered cheapest-first; each carries its own false-positive guard.
        if isPaymentCardNumber(text) { return "card_number_shape" }
        if isRecoveryPhrase(text) { return "recovery_phrase_shape" }
        if isHighEntropyToken(text) { return "high_entropy_token" }
        if isBase64Token(text) { return "high_entropy_token" }
        return nil
    }

    /// Does this SHORT line name the 3–4 digit card verification code?
    public static func isCardVerificationLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        return cardVerificationLabelTokens.contains { token in
            // "cid"/"cvc" are short enough to appear inside another word, so a
            // 3-letter token has to sit on a word boundary.
            guard token.count <= 3 else { return text.contains(token) }
            return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0.lowercased() == token }
        }
    }

    /// Does this SHORT line name a wallet recovery phrase?
    public static func isSeedPhraseLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        return seedPhraseLabelTokens.contains { text.contains($0) }
    }

    /// Exactly 3–4 digits and nothing else. Only ever redacted UNDER a card
    /// verification label — on its own, three digits is a quantity.
    static func isShortCodeValue(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= 4 else { return false }
        return text.allSatisfy { $0.isNumber }
    }

    /// Does this SHORT line name a secret — i.e. is it the caption of a secret
    /// field/value? Never true for a sentence.
    public static func looksLikeSecretLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        guard secretLabelTokens.contains(where: { text.contains($0) }) else { return false }
        // Qualified "code" labels (zip/area/promo/…) are not secrets. Only the
        // bare-"code" match needs the guard: every other token in the list is
        // unambiguous on its own.
        let matchedOnlyCode = !secretLabelTokens.contains {
            $0 != "code" && $0 != "pin" && text.contains($0)
        }
        if matchedOnlyCode, codeDisqualifiers.contains(where: { text.contains($0) }) {
            return false
        }
        return true
    }

    /// Fill in `redactionReason` for every line that is a secret on its own OR
    /// sits where a form puts a secret's value: immediately right of, or
    /// directly below, a short label that names one.
    /// - Parameters:
    ///   - paths: W3.5-FIX-R4 — the AX path of each item, positionally aligned
    ///     with `items`. Needed only for the enclosing-caption geometry, which
    ///     is an ANCESTOR relationship and cannot be decided from frames alone.
    ///     Empty (the default) keeps the beside/above behaviour unchanged.
    ///   - enclosing: the secret-naming groups on this screen.
    public static func applied(
        to items: [MacScreenViewBuilder.VisibleText],
        paths: [[Int]] = [],
        enclosing: [EnclosingCaption] = []
    ) -> [MacScreenViewBuilder.VisibleText] {
        let labels = items.filter { looksLikeSecretLabel($0.text) }
        let cvvLabels = items.filter { isCardVerificationLabel($0.text) }
        let seedLabels = items.filter { isSeedPhraseLabel($0.text) }
        func near(_ candidates: [MacScreenViewBuilder.VisibleText], _ item: MacScreenViewBuilder.VisibleText) -> Bool {
            candidates.contains { label in
                label.frame != item.frame && isLabel(label.frame, forValueAt: item.frame)
            }
        }
        return items.enumerated().map { index, item in
            func darkened(_ reason: String) -> MacScreenViewBuilder.VisibleText {
                MacScreenViewBuilder.VisibleText(
                    text: item.text,
                    frame: item.frame,
                    redactionReason: reason
                )
            }
            if let reason = standaloneSecretReason(item.text) { return darkened(reason) }
            // W3.5-FIX-R4 — the enclosing group. Prose sits inside a captioned
            // group just as often as a field does (the recovery words a wallet
            // prints under a "Recovery Phrase" heading are static text).
            if index < paths.count {
                let kinds = enclosingKinds(
                    forNodeAt: item.frame, path: paths[index], among: enclosing
                )
                if let reason = enclosingSecretReason(item.text, kinds: kinds) {
                    return darkened(reason)
                }
            }
            // W3.5-FIX-R2 3 — same two labeled shapes as the inline path, by
            // POSITION: a form puts the CVV box right of its caption and the
            // recovery words directly under theirs.
            if isShortCodeValue(item.text), near(cvvLabels, item) { return darkened("labeled_cvv") }
            if isRecoveryPhrase(item.text, minWords: labeledSeedMinWords), near(seedLabels, item) {
                return darkened("labeled_recovery_phrase")
            }
            guard looksLikeRedactableValue(item.text) else { return item }
            guard near(labels, item) else { return item }
            return darkened("labeled_secret_nearby")
        }
    }

    /// The legend's mirror of `applied`: a name or a value that is itself a
    /// secret never rides out as a label row either.
    /// - Parameter under: the control's own label, when this string is that
    ///   control's VALUE. A legend row carries its own caption, so the CVV box
    ///   labeled "CVV" showing `123` is the positional shape the prose channel
    ///   already redacts — without this the same three digits ride out in the
    ///   legend. Nil for a label (a label has no label).
    /// - Parameter enclosing: W3.5-FIX-R4 — the secret-naming GROUPS this
    ///   control sits inside, computed once per capture in
    ///   `MacScreenViewBuilder.select`. A CVV field enclosed by a group titled
    ///   "CVV" has no caption of its own to pass as `under`, so without this
    ///   the three digits ride out in the legend.
    public static func redactedLegendString(
        _ text: String,
        valueChars: Int,
        under label: String? = nil,
        enclosing: EnclosingCaptionKinds = .none
    ) -> JSONValue {
        if let reason = standaloneSecretReason(text) {
            return redactedText(text, reason: reason)
        }
        if let reason = enclosingSecretReason(text, kinds: enclosing) {
            return redactedText(text, reason: reason)
        }
        if let label {
            if isCardVerificationLabel(label), isShortCodeValue(text) {
                return redactedText(text, reason: "labeled_cvv")
            }
            if isSeedPhraseLabel(label), isRecoveryPhrase(text, minWords: labeledSeedMinWords) {
                return redactedText(text, reason: "labeled_recovery_phrase")
            }
            if looksLikeSecretLabel(label), looksLikeRedactableValue(text) {
                return redactedText(text, reason: "labeled_secret_nearby")
            }
        }
        return .string(MacAccessibilityReader.truncate(text, to: valueChars))
    }

    /// W3.5-FIX-R2 1 — the LATER ECHO.
    ///
    /// `mac_view` serialized every legend row through the redactor above, and
    /// then `mac_click{mark}` / `mac_ax_act{mark}` echoed the element they
    /// resolved to back into their own result — `element.label`, `element.title`,
    /// `element.value`, `post_state.value` — straight from the stored mark or a
    /// fresh AX read, redactor bypassed. Those results ride the ordinary tool
    /// sinks (trace, persisted row, sync), so a secret-shaped control name
    /// leaked on the ACT call even though the READ call had covered it.
    ///
    /// This walks an already-built element object and re-runs the SAME
    /// standalone redactor over its name/value fields. Fields already redacted
    /// (the injection redactor's `{redacted, sha256, …}` object) are not
    /// strings, so they pass through untouched.
    public static func redactedElementJSON(
        _ value: JSONValue,
        valueChars: Int = MacAXLimits.hardValueChars
    ) -> JSONValue {
        guard case .object(var object) = value else { return value }
        let nameKeys = ["label", "title"]
        var label: String?
        for key in nameKeys {
            guard case .string(let raw)? = object[key] else { continue }
            label = label ?? raw
            object[key] = redactedLegendString(raw, valueChars: valueChars)
        }
        if case .string(let raw)? = object["value"] {
            object["value"] = redactedLegendString(raw, valueChars: valueChars, under: label)
        }
        return .object(object)
    }

    // MARK: - The SIBLING organ: mac_ax_tree / mac_ax_find (W3.5-FIX-R3)

    /// W3.5-FIX-R3 — THE OTHER EYE.
    ///
    /// `mac_view` (W3.5) redacts its text channel, legend, element echoes and
    /// window title. `mac_ax_tree` / `mac_ax_find` (W1, SHIPPED d38d67bb) read
    /// the SAME screen through the SAME `MacAccessibilityReader` walk and dump
    /// every node's `title` and `value` plus the window title straight into the
    /// tool result — which rides the identical sinks (turn trace, persisted
    /// tool row, cognitive-event preview, iOS/Telegram sync). A displayed 2FA
    /// code, a revealed API key or an authenticator window's title left the
    /// machine in the clear on the read tool that needs no approval.
    ///
    /// Redaction lives HERE, at the tool-serialization boundary, and NOT inside
    /// `MacAccessibilityReader`: the walk is the shared, injection-free read
    /// organ and stays byte-identical, exactly as `mac_view` redacts in its
    /// builder rather than in the AX walk underneath it.
    ///
    /// What survives: `role`, `subrole`, `enabled`, `frame`, `actions`, `path`,
    /// `score`. WHERE a control is and that it is pressable is not a secret,
    /// and she still has to act on it — a redacted node stays fully addressable.
    ///
    /// The detectors are the round-1 + round-2 ones verbatim (Luhn card,
    /// entropy/marker base64, wordlist seed, captioned CVV, CamelCase guard).
    /// No new shape is invented here: over-redaction blinds the tree exactly
    /// the way it blinds the view, and the negative table is what holds it.
    public struct NodeSecretContext: Sendable {
        public let secretLabelFrames: [MacAXFrame]
        public let cvvLabelFrames: [MacAXFrame]
        public let seedLabelFrames: [MacAXFrame]
        /// W3.5-FIX-R4 — the third caption geometry: an ancestor GROUP whose
        /// title names a secret and whose frame contains the value.
        public let enclosingCaptions: [EnclosingCaption]

        public init(
            secretLabelFrames: [MacAXFrame],
            cvvLabelFrames: [MacAXFrame],
            seedLabelFrames: [MacAXFrame],
            enclosingCaptions: [EnclosingCaption] = []
        ) {
            self.secretLabelFrames = secretLabelFrames
            self.cvvLabelFrames = cvvLabelFrames
            self.seedLabelFrames = seedLabelFrames
            self.enclosingCaptions = enclosingCaptions
        }

        public static let empty = NodeSecretContext(
            secretLabelFrames: [], cvvLabelFrames: [], seedLabelFrames: []
        )
    }

    /// The proximity context the prose channel gets for free from `visibleText`:
    /// which frames on this screen are CAPTIONS naming a secret. Built from the
    /// WHOLE snapshot — including nodes a `find` query did not match — because a
    /// caption two rows away still names the value beside it.
    public static func nodeSecretContext(_ nodes: [MacAXNode]) -> NodeSecretContext {
        var secret: [MacAXFrame] = []
        var cvv: [MacAXFrame] = []
        var seed: [MacAXFrame] = []
        for node in nodes {
            guard let frame = node.attributes.frame else { continue }
            for candidate in [node.attributes.title, node.attributes.value].compactMap({ $0 }) {
                if looksLikeSecretLabel(candidate) { secret.append(frame) }
                if isCardVerificationLabel(candidate) { cvv.append(frame) }
                if isSeedPhraseLabel(candidate) { seed.append(frame) }
            }
        }
        return NodeSecretContext(
            secretLabelFrames: secret,
            cvvLabelFrames: cvv,
            seedLabelFrames: seed,
            enclosingCaptions: enclosingCaptions(nodes)
        )
    }

    /// One node's text field, judged by shape on its own, then by the caption it
    /// carries (`under`), then by the caption sitting beside/above it.
    static func redactedNodeString(
        _ text: String,
        valueChars: Int,
        frame: MacAXFrame?,
        under label: String?,
        enclosing: EnclosingCaptionKinds = .none,
        context: NodeSecretContext
    ) -> JSONValue {
        if let reason = standaloneSecretReason(text) {
            return redactedText(text, reason: reason)
        }
        // W3.5-FIX-R4 — the enclosing group's caption, before the beside/above
        // ones: it is the geometry a real card form actually uses.
        if let reason = enclosingSecretReason(text, kinds: enclosing) {
            return redactedText(text, reason: reason)
        }
        if let label {
            if isCardVerificationLabel(label), isShortCodeValue(text) {
                return redactedText(text, reason: "labeled_cvv")
            }
            if isSeedPhraseLabel(label), isRecoveryPhrase(text, minWords: labeledSeedMinWords) {
                return redactedText(text, reason: "labeled_recovery_phrase")
            }
            if looksLikeSecretLabel(label), looksLikeRedactableValue(text) {
                return redactedText(text, reason: "labeled_secret_nearby")
            }
        }
        if let frame {
            func near(_ frames: [MacAXFrame]) -> Bool {
                frames.contains { $0 != frame && isLabel($0, forValueAt: frame) }
            }
            if isShortCodeValue(text), near(context.cvvLabelFrames) {
                return redactedText(text, reason: "labeled_cvv")
            }
            if isRecoveryPhrase(text, minWords: labeledSeedMinWords), near(context.seedLabelFrames) {
                return redactedText(text, reason: "labeled_recovery_phrase")
            }
            if looksLikeRedactableValue(text), near(context.secretLabelFrames) {
                return redactedText(text, reason: "labeled_secret_nearby")
            }
        }
        return .string(MacAccessibilityReader.truncate(text, to: valueChars))
    }

    /// Serialize one AX node with its text channels redacted and every
    /// addressing channel intact.
    public static func redactedNodeJSON(
        _ node: MacAXNode,
        valueChars: Int = MacAXLimits.hardValueChars,
        context: NodeSecretContext = .empty
    ) -> JSONValue {
        guard case .object(var object) = node.toJSON(valueChars: valueChars) else {
            return node.toJSON(valueChars: valueChars)
        }
        let frame = node.attributes.frame
        // W3.5-FIX-R4 — which secret-naming GROUPS this node sits inside.
        let enclosing = enclosingKinds(
            forNodeAt: frame,
            path: node.path,
            among: context.enclosingCaptions
        )
        if let title = node.attributes.title {
            object["title"] = redactedNodeString(
                title,
                valueChars: valueChars,
                frame: frame,
                under: nil,
                enclosing: enclosing,
                context: context
            )
        }
        if let value = node.attributes.value {
            object["value"] = redactedNodeString(
                value,
                valueChars: valueChars,
                frame: frame,
                // A control's own title IS its caption — the "CVV" box showing
                // `123`, the "API key" field showing the key.
                under: node.attributes.title,
                enclosing: enclosing,
                context: context
            )
        }
        return .object(object)
    }

    /// `mac_ax_tree`'s node array.
    public static func redactedNodesJSON(
        _ nodes: [MacAXNode],
        valueChars: Int = MacAXLimits.hardValueChars
    ) -> [JSONValue] {
        let context = nodeSecretContext(nodes)
        return nodes.map { redactedNodeJSON($0, valueChars: valueChars, context: context) }
    }

    /// `mac_ax_find`'s match array. Same redaction, `score` preserved — a match
    /// on a redacted node is still a usable handle.
    public static func redactedMatchesJSON(
        _ matches: [MacAXMatch],
        valueChars: Int = MacAXLimits.hardValueChars,
        context: NodeSecretContext
    ) -> [JSONValue] {
        matches.map { match in
            guard case .object(var object) =
                redactedNodeJSON(match.node, valueChars: valueChars, context: context) else {
                return match.toJSON(valueChars: valueChars)
            }
            object["score"] = .double(match.score)
            return .object(object)
        }
    }

    // MARK: - The ENCLOSING caption (W3.5-FIX-R4)

    /// W3.5-FIX-R4 — THE CAPTION THAT SURROUNDS INSTEAD OF POINTING.
    ///
    /// Every caption rule above answers "what text NAMES this value" with two
    /// geometries: the caption sits to its LEFT, or directly ABOVE it. A form
    /// has a third one, and it is the one a real card form uses:
    ///
    ///     AXGroup  title="CVV"          ← encloses
    ///       AXTextField  value="451"    ← no title of its own
    ///
    /// The field has no own title, `451` is not a standalone secret (three
    /// digits is a quantity), and the group is neither left-of nor above — it
    /// CONTAINS. So the value rode out in the clear on `ax_tree`, `ax_find` and
    /// the `mac_view` legend alike. This adds the containment geometry, using
    /// the SAME secret-caption vocabulary and the SAME shape detectors; no new
    /// shape is invented, only a third way for an existing caption to reach an
    /// existing shape.
    ///
    /// THE FALSE-POSITIVE GUARD IS THE HARD PART. A caption beside one value
    /// darkens one value; an enclosing caption darkens a whole SUBTREE, so it
    /// earns a stricter bar than the beside-geometry keeps:
    ///
    ///   • the caption must NAME a secret — a group titled "Payment", "Form",
    ///     "Account" or "Toolbar" is ordinary structure and its children stay
    ///     fully legible;
    ///   • the secret word must be a WORD, not a substring — "Shipping"
    ///     contains "pin" and a shipping section is not a secret. (The
    ///     beside-geometry keeps its shipped substring rule: one value of blast
    ///     radius does not pay for a behaviour change on a shipped path.)
    ///   • the ROOT window is never an enclosing caption. It encloses
    ///     everything, so a window titled "Recovery Code" would blank the whole
    ///     screen; the window title is redacted on its own, standalone.
    ///   • the value still has to have a secret SHAPE. A toolbar group named
    ///     "Password" enclosing a "New Tab" button keeps its button.
    public struct EnclosingCaptionKinds: Sendable, Equatable {
        public let secret: Bool
        public let cvv: Bool
        public let seed: Bool

        public init(secret: Bool = false, cvv: Bool = false, seed: Bool = false) {
            self.secret = secret
            self.cvv = cvv
            self.seed = seed
        }

        public var any: Bool { secret || cvv || seed }
        public static let none = EnclosingCaptionKinds()

        public func merged(with other: EnclosingCaptionKinds) -> EnclosingCaptionKinds {
            EnclosingCaptionKinds(
                secret: secret || other.secret,
                cvv: cvv || other.cvv,
                seed: seed || other.seed
            )
        }
    }

    /// One node that both NAMES a secret and ENCLOSES things: a candidate
    /// ancestor. `path` is what makes it an ancestor rather than merely a
    /// bigger overlapping rectangle — frame containment alone would let a
    /// full-window backdrop caption a control it has no relationship to.
    public struct EnclosingCaption: Sendable, Equatable {
        public let frame: MacAXFrame
        public let path: [Int]
        public let kinds: EnclosingCaptionKinds

        public init(frame: MacAXFrame, path: [Int], kinds: EnclosingCaptionKinds) {
            self.frame = frame
            self.path = path
            self.kinds = kinds
        }
    }

    /// Words, not substrings: `"Shipping"` must not match `"pin"`.
    /// Normalizes both sides (lowercase, every non-alphanumeric run becomes a
    /// single space) so a multi-word token like `"api key"` or `"one-time"`
    /// matches `"API Key:"` and `"One-Time Code"` on the same rule.
    static func captionWords(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var words: [String] = []
        var current = ""
        for character in lowered {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return " " + words.joined(separator: " ") + " "
    }

    static func captionContainsWord(_ normalized: String, anyOf tokens: [String]) -> Bool {
        tokens.contains { token in
            let needle = captionWords(token)
            guard needle.count > 2 else { return false }
            return normalized.contains(needle)
        }
    }

    /// Which secret-caption vocabularies does this title belong to, judged at
    /// the stricter word-boundary bar an enclosing caption has to clear?
    public static func enclosingCaptionKinds(forCaption raw: String) -> EnclosingCaptionKinds {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLabelChars else { return .none }
        let normalized = captionWords(text)
        let cvv = captionContainsWord(normalized, anyOf: cardVerificationLabelTokens)
        let seed = captionContainsWord(normalized, anyOf: seedPhraseLabelTokens)
        var secret = captionContainsWord(normalized, anyOf: secretLabelTokens)
        if secret {
            // Same disqualifier pass the beside-geometry runs: a group titled
            // "Zip Code" or "Promo Code" names neither a secret nor a PIN.
            let matchedOnlyCode = !secretLabelTokens.contains {
                $0 != "code" && $0 != "pin"
                    && captionContainsWord(normalized, anyOf: [$0])
            }
            if matchedOnlyCode,
               codeDisqualifiers.contains(where: { text.lowercased().contains($0) }) {
                secret = false
            }
        }
        return EnclosingCaptionKinds(secret: secret, cvv: cvv, seed: seed)
    }

    /// Every node on this screen that could caption its own subtree. Built from
    /// the WHOLE snapshot for the same reason the beside-caption map is: a
    /// `find` query matches the field, never the group around it.
    public static func enclosingCaptions(_ nodes: [MacAXNode]) -> [EnclosingCaption] {
        var captions: [EnclosingCaption] = []
        for node in nodes {
            // The root (empty path) encloses the entire window — excluded on
            // purpose, see the guard list above.
            guard !node.path.isEmpty else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0 else { continue }
            guard let title = node.attributes.title else { continue }
            let kinds = enclosingCaptionKinds(forCaption: title)
            guard kinds.any else { continue }
            captions.append(EnclosingCaption(frame: frame, path: node.path, kinds: kinds))
        }
        return captions
    }

    /// Which enclosing captions apply to the node at `path`/`frame`: a strict
    /// path ancestor whose frame also contains the node. Both are required —
    /// the path proves the relationship, the frame proves the group is really
    /// drawn around it (an AX subtree can outlive its visual box).
    public static func enclosingKinds(
        forNodeAt frame: MacAXFrame?,
        path: [Int],
        among captions: [EnclosingCaption]
    ) -> EnclosingCaptionKinds {
        guard let frame, frame.w > 0, frame.h > 0, !captions.isEmpty else { return .none }
        var kinds = EnclosingCaptionKinds.none
        for caption in captions where isStrictAncestor(caption.path, of: path) {
            guard frameContains(caption.frame, frame) else { continue }
            kinds = kinds.merged(with: caption.kinds)
        }
        return kinds
    }

    static func isStrictAncestor(_ ancestor: [Int], of path: [Int]) -> Bool {
        guard !ancestor.isEmpty, ancestor.count < path.count else { return false }
        for (index, component) in ancestor.enumerated() where path[index] != component {
            return false
        }
        return true
    }

    static func frameContains(_ outer: MacAXFrame, _ inner: MacAXFrame) -> Bool {
        let slack = 1.0
        return outer.x <= inner.x + slack
            && outer.y <= inner.y + slack
            && outer.x + outer.w >= inner.x + inner.w - slack
            && outer.y + outer.h >= inner.y + inner.h - slack
    }

    /// The enclosing rule, applied to one string. Shape still decides: the
    /// caption only says WHICH shapes are in play here.
    static func enclosingSecretReason(_ text: String, kinds: EnclosingCaptionKinds) -> String? {
        guard kinds.any else { return nil }
        if kinds.cvv, isShortCodeValue(text) { return "enclosing_cvv" }
        if kinds.seed, isRecoveryPhrase(text, minWords: labeledSeedMinWords) {
            return "enclosing_recovery_phrase"
        }
        if kinds.secret, looksLikeRedactableValue(text) { return "enclosing_secret_caption" }
        return nil
    }

    // MARK: shapes

    /// Same geometry as `MacScreenViewBuilder.inferLabel`, inverted: there we
    /// ask "which text names this control", here "is a secret-naming text
    /// pointing at this value".
    static func isLabel(_ label: MacAXFrame, forValueAt value: MacAXFrame) -> Bool {
        guard label.w > 0, label.h > 0, value.w > 0, value.h > 0 else { return false }
        let sameRow = label.y < value.y + value.h && label.y + label.h > value.y
        let toTheLeft = label.x + label.w <= value.x + 1
        if sameRow, toTheLeft {
            let distance = value.x - (label.x + label.w)
            return distance >= 0 && distance <= proximityPoints
        }
        let above = label.y + label.h <= value.y + 1
        let horizontallyOverlapping = label.x < value.x + value.w && label.x + label.w > value.x
        if above, horizontallyOverlapping {
            let distance = value.y - (label.y + label.h)
            return distance >= 0 && distance <= proximityPoints
        }
        return false
    }

    /// A value worth redacting BY POSITION is a token, not prose: one word,
    /// long enough to be a secret, and either carrying a digit, long, or an
    /// all-caps/alnum run. "Cancel" beside a password label stays visible;
    /// "8F2K-91QT" does not.
    static func looksLikeRedactableValue(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= maxValueChars else { return false }
        guard !text.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return false }
        let hasDigit = text.contains { $0.isNumber }
        let allCaps = text.allSatisfy { !$0.isLowercase } && text.contains { $0.isLetter }
        return hasDigit || allCaps || text.count >= 12
    }

    static func isMaskedRun(_ text: String) -> Bool {
        let masks: Set<Character> = ["•", "●", "*", "·", "∙", "◦", "⁕", "✱", "◍", "＊"]
        let stripped = text.filter { !$0.isWhitespace }
        guard stripped.count >= 4 else { return false }
        return stripped.allSatisfy { masks.contains($0) }
    }

    /// A LONE 6–8 digit code. The whole line has to be the code: "123456" is an
    /// OTP, "Order 123456 shipped" is not.
    static func isOneTimeCode(_ text: String) -> Bool {
        guard text.count <= 12 else { return false }
        guard !text.contains(where: { $0.isLetter }) else { return false }
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 6, digits.count <= 8 else { return false }
        let separators: Set<Character> = [" ", "-", "–", "—", "\u{00A0}"]
        return text.allSatisfy { $0.isNumber || separators.contains($0) }
    }

    /// `label: value` on one line, where the label names a secret and the value
    /// is a single token. The single-token bar is the false-positive guard:
    /// "Choose a strong password: it must be at least 8 characters" has a
    /// secret-naming label and a SENTENCE after the colon, so it stays visible.
    static func inlineLabeledSecretReason(_ text: String) -> String? {
        guard text.count <= 200 else { return nil }
        for separator in [":", "=", "："] {
            guard let range = text.range(of: separator) else { continue }
            let label = String(text[text.startIndex..<range.lowerBound])
            let value = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            // W3.5-FIX-R2 3 — the two labeled shapes whose VALUE the generic
            // token test rejects: a 3-digit CVV (under the length floor) and a
            // recovery phrase (multi-word, so the no-whitespace test kills it).
            if isCardVerificationLabel(label), isShortCodeValue(value) {
                return "labeled_cvv"
            }
            if isSeedPhraseLabel(label), isRecoveryPhrase(value, minWords: labeledSeedMinWords) {
                return "labeled_recovery_phrase"
            }
            guard looksLikeSecretLabel(label) else { continue }
            // The generic token test rejects whitespace, so a spaced card
            // number or a word run after a secret caption needs its own shape.
            guard looksLikeRedactableValue(value)
                || isPaymentCardNumber(value)
                || isRecoveryPhrase(value, minWords: labeledSeedMinWords) else { continue }
            return "labeled_inline_secret"
        }
        return nil
    }

    /// Under an explicit seed/recovery caption the wordlist run does not have to
    /// reach the unlabeled 12-word bar — the caption already said what it is.
    public static let labeledSeedMinWords = 6

    // MARK: shapes added in W3.5-FIX-R2 (round-2 adversarial review)

    /// A payment card number, INCLUDING the spaced/dashed form a human reads.
    ///
    /// Round 1 could not see this: `looksLikeRedactableValue` rejects anything
    /// containing whitespace, so `4111 1111 1111 1111` — the way every checkout
    /// form and every card actually renders it — sailed through in the clear.
    ///
    /// FALSE-POSITIVE GUARD: **Luhn**. 13–19 digits is a wide net (an order id,
    /// an account number, a serial all live in there), so the line only goes
    /// dark if it also satisfies the card checksum. An order number, a tracking
    /// number and a phone number are shorter, carry letters, or fail Luhn.
    static func isPaymentCardNumber(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32 else { return false }
        let separators: Set<Character> = [" ", "-", "–", "—", "\u{00A0}"]
        guard text.allSatisfy({ $0.isNumber || separators.contains($0) }) else { return false }
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        return luhnValid(digits)
    }

    /// The Luhn mod-10 checksum every issuer's numbering satisfies.
    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for character in digits.reversed() {
            guard let value = character.wholeNumberValue else { return false }
            if double {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// A wallet seed / recovery phrase: a run of lowercase space-separated
    /// words. Round 1 never considered a multi-WORD secret at all — every shape
    /// it knew was a single token — so twelve words of someone's wallet backup
    /// read out as ordinary prose.
    ///
    /// FALSE-POSITIVE GUARD, three layers, because "lowercase words" is what
    /// prose is made of: (1) every word must be 3–8 letters, pure alphabetic —
    /// wordlist shape, and prose is full of 1–2 letter function words; (2) the
    /// WHOLE line must be the run, so any capital or punctuation mark — which
    /// real prose lines carry — disqualifies it; (3) no common English function
    /// word may appear. A phrase that happens to contain one of those words is
    /// MISSED rather than a sentence being darkened; that direction of error is
    /// the deliberate one, and a LABELED phrase is caught regardless (see
    /// `minWords`, dropped to 6 under a seed/recovery caption).
    static func isRecoveryPhrase(_ raw: String, minWords: Int = 12) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 400 else { return false }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= minWords else { return false }
        for word in words {
            guard word.count >= 3, word.count <= 8 else { return false }
            guard word.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
            if proseFunctionWords.contains(word) { return false }
        }
        return true
    }

    /// A base64 / base64url blob. Round 1's token charset was
    /// `[letters, digits, -, _, .]`, so `+`, `/` and `=` — the characters that
    /// make a token base64 in the first place — DISQUALIFIED it.
    ///
    /// FALSE-POSITIVE GUARD, four gates, because `/` also means "path":
    /// (1) at least one true base64 marker (`+`, `/`, `=`) — those never occur
    /// in an identifier or an English word; (2) no `.` or `:`, which kills URLs,
    /// hostnames and filenames outright; (3) mixed case AND a digit, the
    /// signature random bytes always produce; (4) no same-case alphabetic run
    /// longer than 5, which is what separates `Reports/2024/Summary` (run of 6
    /// in "eports") from an encoded blob; then a Shannon entropy floor.
    /// base64url tokens made only of `[A-Za-z0-9-_]` carry no marker char and
    /// are already caught by `isHighEntropyToken` above.
    static func isBase64Token(_ text: String) -> Bool {
        guard text.count >= 20, text.count <= maxValueChars else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        guard !text.contains("."), !text.contains(":") else { return false }
        let markers: Set<Character> = ["+", "/", "="]
        let allowed = text.allSatisfy {
            $0.isLetter || $0.isNumber || markers.contains($0) || $0 == "-" || $0 == "_"
        }
        guard allowed else { return false }
        guard text.contains(where: { markers.contains($0) }) else { return false }
        guard text.contains(where: { $0.isUppercase }),
              text.contains(where: { $0.isLowercase }),
              text.contains(where: { $0.isNumber }) else { return false }
        guard longestSameCaseRun(text) <= 5 else { return false }
        return shannonEntropyBitsPerCharacter(text) >= 3.5
    }

    /// Longest run of consecutive letters sharing a case. Words have long ones;
    /// encoded bytes do not.
    static func longestSameCaseRun(_ text: String) -> Int {
        var best = 0
        var current = 0
        var previous: Bool?
        for character in text {
            guard character.isLetter else {
                current = 0
                previous = nil
                continue
            }
            let upper = character.isUppercase
            if upper == previous { current += 1 } else { current = 1; previous = upper }
            best = max(best, current)
        }
        return best
    }

    /// Shannon entropy over the characters, in bits per character.
    static func shannonEntropyBitsPerCharacter(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0.0) { partial, count in
            let probability = Double(count) / total
            return partial - probability * log2(probability)
        }
    }

    /// A single opaque token: long, mixed, and made only of token characters
    /// (so a URL, a path, an email or a sentence cannot qualify) — or short but
    /// carrying a known key prefix.
    static func isHighEntropyToken(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        guard text.count <= maxValueChars else { return false }
        let allowed = text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard allowed else { return false }
        let lowered = text.lowercased()
        if knownSecretPrefixes.contains(where: { lowered.hasPrefix($0) }), text.count >= 12 {
            return true
        }
        guard text.count >= 20 else { return false }
        // A dotted word run (a hostname, a filename, a version) is not a token.
        guard !text.contains(".") else { return false }
        let hasDigit = text.contains { $0.isNumber }
        let hasLetter = text.contains { $0.isLetter }
        guard hasDigit, hasLetter else { return false }
        // W3.5-FIX-R2 — false-positive guard found by the round-2 negative
        // table: `NativeAgentCoreBuildNumber42` cleared every bar above (20+
        // chars, no dot, digits and letters, 10+ distinct characters) and went
        // dark. A long CamelCase identifier is exactly the kind of ordinary
        // screen text that must stay legible.
        guard !looksLikeCamelCaseIdentifier(text) else { return false }
        return Set(text).count >= 10
    }

    /// Does this split at its capitals into three or more real words? A random
    /// token does not — its "words" are two characters long and full of digits.
    static func looksLikeCamelCaseIdentifier(_ text: String) -> Bool {
        var segments: [String] = []
        var current = ""
        for character in text {
            if character.isUppercase, !current.isEmpty {
                segments.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { segments.append(current) }
        guard segments.count >= 3 else { return false }
        return segments.allSatisfy { segment in
            let letters = segment.prefix { $0.isLetter }
            guard letters.count >= 3 else { return false }
            return segment.dropFirst(letters.count).allSatisfy { $0.isNumber }
        }
    }
}

// MARK: - Keeping the PICTURE out of persisted previews (W3.5-FIX 3)

/// `mac_view` returns a base64 PNG of the screen. That is correct for the LIVE
/// model call — it is the spatial backdrop the whole organ exists to provide —
/// and wrong for everything downstream of it. The generic trace/persistence
/// preview sinks redact injection-SHAPED results only, so a full screenshot of
/// whatever User had open (a banking page, a private message, an authenticator)
/// was riding into the turn trace and the persisted transcript, which syncs.
///
/// This strips the pixels at those sinks and leaves the audit trail: how big it
/// was, what it hashed to, and what its pixel size was (already in the result).
public enum MacScreenViewResultRedaction {
    /// Every name `mac_view` answers to across the tool/registry/action layers.
    ///
    /// W6 — `mac_wake` is here too. It returns the view output FLATTENED (the
    /// same top-level `image` / `marks` / `text` keys plus a `wake` block)
    /// precisely so it inherits this stripping and mac_view's source redaction
    /// instead of opening a second screen-read channel no sink knows about.
    public static let viewToolNames: Set<String> = [
        "mac_view", "mac.view", "view",
        "mac_wake", "mac.wake", "wake",
    ]

    public static func carriesImage(tool: String) -> Bool {
        viewToolNames.contains(
            tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Idempotent: an already-stripped result has no `image` string left, so a
    /// sink can call this without knowing whether an upstream sink did.
    public static func redacted(tool: String, result: JSONValue) -> JSONValue {
        guard carriesImage(tool: tool) else { return result }
        guard case .object(var object) = result else { return result }
        guard case .string(let base64)? = object["image"], !base64.isEmpty else { return result }
        object.removeValue(forKey: "image")
        object["image_redacted"] = .bool(true)
        if object["image_bytes"] == nil || object["image_bytes"] == .null {
            let bytes = Data(base64Encoded: base64)?.count ?? base64.utf8.count
            object["image_bytes"] = .int(Int64(bytes))
        }
        if let digest = MacInjectionArgRedaction.sha256(base64) {
            object["image_sha256"] = .string(digest)
        }
        return .object(object)
    }
}

// MARK: - Production capture source (ScreenCaptureKit)

#if canImport(ScreenCaptureKit) && os(macOS)

/// Live capture.
///
/// ScreenCaptureKit, not `CGWindowListCreateImage`: that call is OBSOLETED as
/// of macOS 15 and does not compile against the current SDK, so there is no
/// legacy path to fall back to.
///
/// Deliberately NOT reusing `SwiftNativeScreenVision`: that organ captures the
/// whole primary display and returns encoded PNG bytes, which is a different
/// capability from "this sub-rect, as a CGImage I still have to draw markers
/// onto". Sharing it would mean either widening its contract or re-decoding a
/// PNG to annotate it. The permission it reads is the same one.
public struct SystemMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}

    /// Read-only preflight. Never `CGRequestScreenCaptureAccess` — that shows
    /// the OS prompt, and the grant is User's, not code's, to initiate.
    public func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard isScreenRecordingTrusted() else { return .failure(.screenRecordingNotTrusted) }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return .failure(.captureFailed)
        }
        // Pick the display the requested rect actually lives on (by its centre),
        // falling back to the main display. A window dragged to a second
        // monitor must not be "captured" from the primary one.
        let wanted = rect
        let displays = content.displays
        guard !displays.isEmpty else { return .failure(.noDisplay) }
        let mainID = CGMainDisplayID()
        let display: SCDisplay = {
            if let wanted {
                let cx = wanted.x + wanted.w / 2
                let cy = wanted.y + wanted.h / 2
                if let hit = displays.first(where: {
                    CGDisplayBounds($0.displayID).contains(CGPoint(x: cx, y: cy))
                }) {
                    return hit
                }
            }
            return displays.first(where: { $0.displayID == mainID }) ?? displays[0]
        }()

        let displayBounds = CGDisplayBounds(display.displayID)
        // Global (AX) points → this display's local points. Identical for the
        // main display at the origin; not identical for any other.
        let globalRect: CGRect = {
            guard let wanted, wanted.w > 0, wanted.h > 0 else { return displayBounds }
            return CGRect(x: wanted.x, y: wanted.y, width: wanted.w, height: wanted.h)
                .intersection(displayBounds)
        }()
        guard !globalRect.isNull, globalRect.width >= 1, globalRect.height >= 1 else {
            return .failure(.captureFailed)
        }
        let localRect = CGRect(
            x: globalRect.origin.x - displayBounds.origin.x,
            y: globalRect.origin.y - displayBounds.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        // Native pixel density of THIS display: physical pixels per point.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let densityX = (mode?.pixelWidth).map { Double($0) / Double(max(1, display.width)) } ?? 1.0
        let densityY = (mode?.pixelHeight).map { Double($0) / Double(max(1, display.height)) } ?? 1.0
        let density = max(1.0, min(max(densityX, densityY), 4.0))

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int((localRect.width * density).rounded()))
        configuration.height = max(1, Int((localRect.height * density).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            return .failure(.captureFailed)
        }
        // The SHOT reports the pixel size that came back, not the size that was
        // asked for. Everything downstream derives its scale from this, so a
        // pipeline that clamped or rounded the request cannot displace a marker.
        return .success(MacScreenShot(
            bounds: MacAXFrame(
                x: Double(globalRect.origin.x),
                y: Double(globalRect.origin.y),
                w: Double(globalRect.width),
                h: Double(globalRect.height)
            ),
            pixelWidth: image.width,
            pixelHeight: image.height,
            cgImage: image
        ))
    }
}

#endif

/// Platform fallback: honest unavailability, never a fabricated picture.
public struct UnavailableMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}
    public func isScreenRecordingTrusted() -> Bool { false }
    public func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        .failure(.unavailableOnThisPlatform)
    }
}

public func defaultMacScreenCaptureSource() -> any MacScreenCaptureSource {
    #if canImport(ScreenCaptureKit) && os(macOS)
    return SystemMacScreenCaptureSource()
    #else
    return UnavailableMacScreenCaptureSource()
    #endif
}

// MARK: - Production renderer (CoreGraphics + CoreText)

#if canImport(CoreGraphics) && canImport(CoreText) && os(macOS)

/// Set-of-marks renderer.
///
/// LEGIBILITY IN BOTH THEMES, deterministically: every stroke is drawn twice —
/// a thick WHITE halo underneath and a thin BLACK line on top — so the marker
/// survives a white background and a black one without sampling the pixels
/// underneath (sampling would make the output depend on the screen's content,
/// which is exactly the non-determinism a set-of-marks image must not have).
/// The number badge is the same sandwich: white plate, black border, black
/// digits.
public struct CoreGraphicsMacScreenImageRenderer: MacScreenImageRenderer {
    public init() {}

    public func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data? {
        guard let source = shot.cgImage else { return nil }
        let factor = max(0.05, min(downscale, 1.0))
        let width = max(1, Int((Double(shot.pixelWidth) * factor).rounded()))
        let height = max(1, Int((Double(shot.pixelHeight) * factor).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Marker scale: tie the badge to the IMAGE's own size so a 1x window
        // capture and a 2x retina capture look the same to the eye.
        let unit = max(1.0, Double(min(width, height)) / 400.0)
        let lineWidth = max(1.0, 1.5 * unit)
        let fontSize = max(9.0, 9.0 * unit)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        for placement in placements {
            let x = placement.x * factor
            let w = max(1.0, placement.w * factor)
            let h = max(1.0, placement.h * factor)
            // Placements are top-left origin (image space); CGContext is
            // bottom-left. Flip once, here, at the boundary.
            let y = Double(height) - (placement.y * factor) - h
            let rect = CGRect(x: x, y: y, width: w, height: h)

            context.setLineWidth(lineWidth * 2.2)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            context.stroke(rect)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.95))
            context.stroke(rect)

            drawBadge(
                context: context,
                number: placement.mark,
                font: font,
                fontSize: fontSize,
                unit: unit,
                anchor: CGPoint(x: rect.minX, y: rect.maxY)
            )
        }

        guard let annotated = context.makeImage() else { return nil }
        return Self.encodePNG(annotated)
    }

    private func drawBadge(
        context: CGContext,
        number: Int,
        font: CTFont,
        fontSize: Double,
        unit: Double,
        anchor: CGPoint
    ) {
        let text = String(number)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        let textBounds = CTLineGetImageBounds(line, context)
        let padding = 2.0 * unit
        let plateWidth = max(fontSize, textBounds.width) + padding * 2
        let plateHeight = fontSize + padding * 2
        // Badge sits just ABOVE the element's top-left corner, tucked back
        // inside the image when the element is flush with an edge.
        var plate = CGRect(
            x: anchor.x,
            y: anchor.y,
            width: plateWidth,
            height: plateHeight
        )
        let canvasWidth = Double(context.width)
        let canvasHeight = Double(context.height)
        if plate.maxX > canvasWidth { plate.origin.x = canvasWidth - plate.width }
        if plate.maxY > canvasHeight { plate.origin.y = canvasHeight - plate.height }
        plate.origin.x = max(0, plate.origin.x)
        plate.origin.y = max(0, plate.origin.y)

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
        context.fill(plate)
        context.setLineWidth(max(1.0, unit))
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.stroke(plate)

        context.textPosition = CGPoint(
            x: plate.minX + (plate.width - textBounds.width) / 2 - textBounds.minX,
            y: plate.minY + padding
        )
        CTLineDraw(line, context)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        #if canImport(AppKit)
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

#endif

/// Platform fallback: no renderer, reported as an encode failure rather than a
/// blank image.
public struct UnavailableMacScreenImageRenderer: MacScreenImageRenderer {
    public init() {}
    public func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data? { nil }
}

public func defaultMacScreenImageRenderer() -> any MacScreenImageRenderer {
    #if canImport(CoreGraphics) && canImport(CoreText) && os(macOS)
    return CoreGraphicsMacScreenImageRenderer()
    #else
    return UnavailableMacScreenImageRenderer()
    #endif
}
