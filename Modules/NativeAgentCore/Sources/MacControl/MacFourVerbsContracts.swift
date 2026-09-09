import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Seams

/// The organ surface the four verbs drive. `SwiftNativeMacControl` conforms
/// below; a test drives the REAL client with the same synthetic AX seams
/// `MacActClosedLoopTests` uses, so nothing about the act path is faked out
/// from under these verbs.
public protocol MacFourVerbsHost: Sendable {
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult
}

extension SwiftNativeMacControl: MacFourVerbsHost {}

/// A target discovered by the fused screenshot/vision lane. The addressing
/// tokens remain on this side of the four-verb wall: the model sees the label
/// or role ordinal, while the implementation may use a current view mark or a
/// confidence-gated physical point.
public struct MacFourVerbsSupplementalTarget: Sendable, Equatable {
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
        enabled: Bool = true
    ) {
        self.label = label
        self.aliases = aliases
        self.kind = kind
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
        self.diagnostics = diagnostics
    }
}

public protocol MacFourVerbsSupplementalPerceptionSource: Sendable {
    func observe() async -> MacFourVerbsSupplement?
    func observe(app: String?) async -> MacFourVerbsSupplement?
}

public extension MacFourVerbsSupplementalPerceptionSource {
    func observe(app: String?) async -> MacFourVerbsSupplement? {
        guard app == nil else { return nil }
        return await observe()
    }
}

/// PATIENCE's clock. Injectable for exactly one reason: a `wait` test must run
/// instantly and must be able to model a screen that never settles.
public protocol MacFourVerbsClock: Sendable {
    func now() -> Date
    func monotonicSeconds() -> Double
    func sleep(seconds: Double) async
}

public struct SystemMacFourVerbsClock: MacFourVerbsClock {
    public init() {}
    public func now() -> Date { Date() }
    public func monotonicSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - The reply

/// What a verb answers with.
///
/// `text` IS the reply — one line of answer followed by the screen render. A
/// reply that requires her to parse nested JSON is a bug, so `detail` is a
/// side-channel for a caller's telemetry and carries NO handle and NO frame id
/// either: if she never sees one, it can never go stale on her.
public struct MacFourVerbsReply: Sendable, Equatable {
    public let ok: Bool
    public let text: String
    public let detail: [String: JSONValue]

    /// Effect comparison keeps complete readouts internally. The agent sees
    /// their bounded SAYS rendering and can ask screen(part:) for more, rather
    /// than receiving the same strings twice more in diagnostic arrays.
    public var agentDetail: [String: JSONValue] {
        detail.filter { $0.key != "vision_value_text" && $0.key != "vision_effect_value_text" }
    }

    public init(ok: Bool, text: String, detail: [String: JSONValue] = [:]) {
        self.ok = ok
        self.text = text
        self.detail = detail
    }
}
