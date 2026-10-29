import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbsContracts.swift` | `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement`, `MacFourVerbsSupplementalPerceptionSource`; four verbs dispatch through `MacControlClient` |

/// A target discovered by the fused screenshot/vision lane. The addressing
/// tokens remain on this side of the four-verb wall: the model sees the label
/// or role ordinal, while the implementation may use a current view mark or a
/// confidence-gated physical point.
public struct MacFourVerbsSupplementalTarget: Sendable, Equatable {
    /// The real AX role, when this target came from accessibility.
    public let role: String?
    public let actions: [String]
    public let settableAttributes: [String]
    /// The screenshot mark's AX identity, private to fusion and never an
    /// action authority or a rendered name. Nil denotes pixel-only evidence.
    public let sourceAXPath: [Int]?
    public let enabled: Bool
    public let label: MacScreenText?
    /// Exact natural names for the same target. They add no second address and
    /// resolve through the ordinary ambiguity rules when several objects share
    /// an appearance.
    public let aliases: [String]
    public let kind: String
    public let secret: Bool
    public let frame: MacAXFrame
    /// Captured bounds, distinct from the private motion-led motor frame.
    public let observedFrame: MacAXFrame
    public let excludedFrames: [MacAXFrame]
    public let provenance: MacScreenRender.Provenance
    public let viewId: String?
    public let mark: Int?
    public let ordinal: Int?
    public let regionOnly: Bool
    /// Pixel evidence can pin a useful place without knowing what kind of UI
    /// object occupies it. Such a target may receive literal hand gestures,
    /// but must never be promoted into type/select/toggle/dismiss semantics.
    public let physicalOnly: Bool
    /// The live vision owner has not yet distinguished motion from a jump.
    /// A time-sensitive click may collect bounded fresh frames before aiming.
    public let motionUncertain: Bool

    public init(
        label: MacScreenText?,
        aliases: [String] = [],
        kind: String,
        secret: Bool = false,
        frame: MacAXFrame,
        observedFrame: MacAXFrame? = nil,
        excludedFrames: [MacAXFrame] = [],
        provenance: MacScreenRender.Provenance,
        viewId: String? = nil,
        mark: Int? = nil,
        ordinal: Int? = nil,
        regionOnly: Bool = false,
        physicalOnly: Bool = false,
        motionUncertain: Bool = false,
        sourceAXPath: [Int]? = nil,
        enabled: Bool = true,
        role: String? = nil,
        actions: [String] = [],
        settableAttributes: [String] = []
    ) {
        self.role = role
        self.actions = actions
        self.settableAttributes = settableAttributes
        self.label = label
        self.aliases = aliases
        self.kind = kind
        self.secret = secret
        self.frame = frame
        self.observedFrame = observedFrame ?? frame
        self.excludedFrames = excludedFrames
        self.provenance = provenance
        self.viewId = viewId
        self.mark = mark
        self.ordinal = ordinal
        self.regionOnly = regionOnly
        self.physicalOnly = physicalOnly
        self.motionUncertain = motionUncertain
        self.sourceAXPath = sourceAXPath
        self.enabled = enabled
    }
}

/// Additive evidence from the fused screenshot lane. It never replaces AX:
/// semantic targets win when both organs describe the same region, and this
/// fills only the things AX could not name plus genuinely pixel-only regions.
public struct MacFourVerbsSupplement: Sendable, Equatable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let visibleFrame: MacAXFrame?
    public let pointer: MacPointerPosition?
    public let pointerFrame: MacAXFrame?
    public let contents: [MacScreenRender.Content]
    public let controls: [MacScreenRender.Control]
    public let values: [MacScreenRender.Value]
    public let targets: [MacFourVerbsSupplementalTarget]
    /// Other apps' windows above this one, in screen points (wherever the
    /// pixels came from): where a physical act must not land or pass.
    public let obstructions: [MacAXFrame]
    /// Non-rendered, handle-free telemetry for diagnosing the perception
    /// boundary. This never becomes screen prose or an action authority.
    public let diagnostics: [String: JSONValue]

    public init(
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        visibleFrame: MacAXFrame? = nil,
        pointer: MacPointerPosition? = nil,
        pointerFrame: MacAXFrame? = nil,
        contents: [MacScreenRender.Content] = [],
        controls: [MacScreenRender.Control] = [],
        values: [MacScreenRender.Value] = [],
        targets: [MacFourVerbsSupplementalTarget] = [],
        obstructions: [MacAXFrame] = [],
        diagnostics: [String: JSONValue] = [:]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.visibleFrame = visibleFrame
        self.pointer = pointer
        self.pointerFrame = pointerFrame
        self.contents = contents
        self.controls = controls
        self.values = values
        self.targets = targets
        self.obstructions = obstructions
        self.diagnostics = diagnostics
    }
}

public protocol MacFourVerbsSupplementalPerceptionSource: Sendable {
    func observe(app: String?) async -> MacFourVerbsSupplement?
    /// The last observed supplement was not this look's own window and was
    /// discarded; a source must drop anything it kept from that capture.
    func rejected()
}

public struct SystemMacFourVerbsClock: Sendable {
    public init() {}
    public func monotonicSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum MacTypeMode: String, Sendable {
    case replace, append
}

/// A place on an image she was handed, in that image's pixels: `at` (a
/// drag's start) and a drag's end `to`. `image` is its frame id; nil is her
/// session's latest. Only the hands turn it into a screen point.
public struct MacImagePlace: Sendable, Equatable {
    public let image: String?
    public let at: MacPointerPosition
    public let to: MacPointerPosition?

    public init(image: String?, at: MacPointerPosition, to: MacPointerPosition? = nil) {
        self.image = image
        self.at = at
        self.to = to
    }
}

/// Her-screen Phase 5 — one step of a batched `act`: a verb, a name (or a
/// place on an image), text/mode for `type`, and a named drag's `to`. No
/// repeat, hold or button inside a step.
public struct MacActStep: Sendable, Equatable {
    public let verb: String
    public let target: String
    public let text: String?
    public let mode: MacTypeMode
    public let to: String?
    public let place: MacImagePlace?

    public init(verb: String, target: String, text: String? = nil, mode: MacTypeMode = .replace,
                to: String? = nil, place: MacImagePlace? = nil) {
        self.verb = verb
        self.target = target
        self.text = text
        self.mode = mode
        self.to = to
        self.place = place
    }
}

// MARK: - The reply

/// What a verb answers with.
///
/// `text` answers in prose with the screen. `detail` carries diagnostics and
/// workspace-owned exact references, including frame IDs and selection receipts;
/// ordinary named actions resolve their targets from a fresh observation.
public struct MacFourVerbsReply: Sendable, Equatable {
    public let ok: Bool
    public let text: String
    public let detail: [String: JSONValue]

    /// Effect comparison keeps complete readouts internally. The agent sees
    /// their bounded SAYS rendering and can ask screen(part:) for more, rather
    /// than receiving the same strings twice more in diagnostic arrays.
    public var agentDetail: [String: JSONValue] {
        var visible = detail.filter { $0.key != "vision_value_text" && $0.key != "vision_effect_value_text" }
        // Keep the motor's typed settlement vocabulary inside the runtime;
        // the receipt says plainly what its observed verdict means.
        if visible["verification"] == .string("satisfied") { visible["verification"] = .string("verified") }
        return visible
    }

    public init(ok: Bool, text: String, detail: [String: JSONValue] = [:]) {
        self.ok = ok
        self.text = text
        var detail = detail
        for key in ["error", "reason", "failure_code"] {
            if detail[key] == .string("ax_untrusted") || detail[key] == .string("accessibility_untrusted") {
                detail[key] = .string("accessibility_not_trusted")
            }
        }
        if !ok, detail["remedy"] == nil, case .string(let code)? = detail["error"] {
            detail["remedy"] = Self.privacyRemedy(code)
        }
        self.detail = detail
    }

    public static func privacyRemedy(_ code: String) -> JSONValue? {
        let pane: String, capability: String
        switch code {
        case "accessibility_not_trusted", "ax_untrusted", "accessibility_untrusted":
            pane = "Accessibility"; capability = "accessibility"
        case "screen_recording_not_trusted":
            pane = "Screen Recording"; capability = "screenRecording"
        default: return nil
        }
        return Repair.remedy(owner: "macOS \(pane) grant", nextCall: .object([
            "tool": .string("app"), "input": .object(["action": .string("permissions.request"), "args": .object([
                "capability": .string(capability), "why": .string("NativeAgent needs \(pane) to \(capability == "accessibility" ? "click and type for you" : "see your screen"). Allow?"),
            ])]),
        ]), tap: "Allow \(pane) on the permission card in NativeAgent")
    }
}
