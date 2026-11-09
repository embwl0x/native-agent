import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MacFourVerbsContracts.swift` | `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement`, `MacFourVerbsSupplementalPerceptionSource`; four verbs dispatch through `MacControlClient`; permissionRemedy is the shared macOS grant remedy builder consumed by SystemPermissionPreflight and lower-level MacControl producers |

/// Vision addressing tokens stay private; the model addresses labels or role ordinals, not motor coordinates.
public struct MacFourVerbsSupplementalTarget: Sendable, Equatable {
    public let role: String?
    public let actions: [String]
    public let settableAttributes: [String]
    /// AX identity is private fusion evidence, never an action authority; nil means pixel-only evidence.
    public let sourceAXPath: [Int]?
    public let enabled: Bool?
    public let label: MacScreenText?
    /// Aliases share one target and ordinary ambiguity rules; they do not create another address.
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
    /// Pixel-only evidence permits literal gestures, never inferred type/select/toggle/dismiss semantics.
    public let physicalOnly: Bool
    /// Unresolved motion may earn bounded fresh frames before a time-sensitive click.
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
        enabled: Bool? = true,
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

/// Vision adds evidence without replacing AX; semantic targets win where both describe the same region.
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
    /// Occluding windows bound where physical acts may land or pass, regardless of the pixels’ source.
    public let obstructions: [MacAXFrame]
    /// Capture omissions remain visible; fusion telemetry supplies no action authority.
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
    func observe(app: String?, turn: Turn, context: MacOperationContext) async -> MacFourVerbsSupplement?
    /// Discard supplements from another window so retained pixels cannot contaminate this look.
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

/// Image points stay in delivered-image pixels; only the hands resolve them to screen coordinates.
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

/// Batch steps share single-act addressing and held-input semantics; repeats belong outside the step.
public struct MacActStep: Sendable, Equatable {
    public let verb: String
    public let target: String
    public let text: String?
    public let mode: MacTypeMode
    public let to: String?
    public let place: MacImagePlace?
    public let holding: String?
    public let button: String?
    public let handle: String?
    public let frameID: String?

    public init(verb: String, target: String, text: String? = nil, mode: MacTypeMode = .replace,
                to: String? = nil, place: MacImagePlace? = nil, holding: String? = nil, button: String? = nil,
                handle: String? = nil, frameID: String? = nil) {
        self.verb = verb
        self.target = target
        self.text = text
        self.mode = mode
        self.to = to
        self.place = place
        self.holding = holding
        self.button = button
        self.handle = handle
        self.frameID = frameID
    }
}

// MARK: - The reply

/// Diagnostics retain workspace-owned exact references; named actions still resolve against a fresh observation.
public struct MacFourVerbsReply: Sendable, Equatable {
    public let ok: Bool
    public let text: String
    public let detail: [String: JSONValue]

    /// Keep complete readouts for effect comparison; render bounded SAYS text once and expose the rest through screen(part:).
    public var agentDetail: [String: JSONValue] {
        var visible = detail.filter { $0.key != "vision_value_text" && $0.key != "vision_effect_value_text" }
        // Keep motor settlement types private while the receipt explains the observed verdict.
        if visible["verification"] == .string("satisfied") { visible["verification"] = .string("verified") }
        return visible
    }

    public init(ok: Bool, text: String, detail: [String: JSONValue] = [:]) {
        self.ok = ok
        self.text = text
        var detail = detail
        if !ok, detail["remedy"] == nil, case .string(let code)? = detail["error"] {
            detail["remedy"] = Self.privacyRemedy(code)
        }
        self.detail = detail
    }

    public static func privacyRemedy(_ code: String) -> JSONValue? {
        let pane: String, capability: String
        switch code {
        case "accessibility_not_trusted", "accessibility_permission_missing":
            pane = accessibilityGrantName; capability = "privacy:accessibility"
        case "screen_recording_not_trusted":
            pane = "Screen Recording"; capability = "privacy:screenRecording"
        default: return nil
        }
        return permissionRemedy(capability, name: pane)
    }

    /// The name the person sees for the Accessibility grant: macOS 27 calls it Device Control and Data Access. Its pane anchor and TCC service are
    /// unchanged. SystemPermissionPreflight's grant vocabulary reads this one name.
    public static let accessibilityGrantName = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) ? "Device Control and Data Access" : "Accessibility"

    /// MacControl cannot import its dependent MacIntegration module, so both share this remedy builder. `capability` is the card's own target:
    /// privacy:<grant> or applescript:<bundle_id>, which permissions.request hands to its card unchanged.
    public static func permissionRemedy(_ capability: String, name: String,
                                        mode: InlineInteraction.AccessMode? = nil) -> JSONValue {
        var args: [String: JSONValue] = ["capability": .string(capability),
            "why": .string("NativeAgent needs \(name) for this work. Allow?")]
        if let mode { args["mode"] = .string(mode.rawValue) }
        return Repair.remedy(owner: "macOS \(name) grant", nextCall: .object([
            "tool": .string("app"), "input": .object(["action": .string("permissions.request"), "args": .object(args)]),
        ]), tap: "Allow \(name) on the permission card in NativeAgent")
    }
}
