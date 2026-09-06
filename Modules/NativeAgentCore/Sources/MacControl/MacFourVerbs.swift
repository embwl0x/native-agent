import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - THE FOUR VERBS — screen · act · go · wait (docs/build_plans/four-verbs.md)
//
// User, verbatim: "she needs a live screen to look at and hands to use it, in a
// native LLM way… give her exactly that, that's it nothing more."
//
// Ten acceptance rounds proved the snapshot model wrong. `mac_look` hands back a
// `frame_id` and opaque handle tokens; `mac_act` demands both back; and nearly
// every failure lived in that bookkeeping — `stale_frame`, `handle_drifted`,
// `window_not_key` — rather than in the work she was doing. THIS FILE IS THE
// REPLACEMENT SURFACE, and its whole contract is stated in one line:
//
//     SHE NEVER SEES a frame id, a handle token, a drift code, or a refusal she
//     cannot act on.
//
// EYES `screen(part:)` · HANDS `act(verb:target:text:)` · LEGS `go(name:)` ·
// PATIENCE `wait(until:seconds:)`. Nothing else.
//
// ORCHESTRATION, NOT REIMPLEMENTATION. Every one of these four calls the organs
// that already exist, through the client's own public `dispatch`:
//
//   screen → `look` + fused AX/view/vision perception → MacScreenRender
//   act    → semantic `act` when AX can name the target, otherwise the existing
//            hand repertoire aimed at a fused screen region; then a fresh screen
//   go     → `focus_app` or canonical `open_target`; then screen
//   wait   → screen, on a bounded loop against an injectable clock
//
// So there is NO new gate, NO new guard, NO new verdict class and NO second
// resolver here. The honesty and safety layers live BELOW this file and every
// call passes straight through them. What this file adds is exactly two things
// the layers below deliberately do not do: RESOLVE A NAME AGAINST THE SCREEN AT
// THE MOMENT OF ACTING, and SAY THE ANSWER IN WORDS.
//
// NO APP-SPECIFIC LOGIC. Not one branch here tests what app it is looking at
// (feedback_build_the_general_capability). A game is simply a screen whose
// dominant content types as CANVAS.
//
// REDACTION IS NOT RE-IMPLEMENTED HERE, and cannot be bypassed here. Every
// SCREEN-DERIVED string this file prints comes out of `MacScreenRender` via
// `MacScreenText`, carrying the compiler's own redaction verdict (the
// `label`/`value`/`text` JSON the look emitted). A withheld string prints as
// `⟨redacted⟩` and — this is the part that matters for the hands — CANNOT BE
// NAMED: resolution matches only against `display` text, so a control whose
// label redaction withheld is unaddressable by name rather than addressable by
// a secret. The other reply strings are the caller's own target/destination
// and fixed operation guidance; typed text is never echoed.
//
// THE PHYSICAL TIER IS INTERNAL. `act` can move, hover, hold, drag, press keys,
// and aim at regions discovered by the fused screen. Coordinates, view ids, and
// mark ids remain private implementation details; uncertain vision rows stay
// visible but are deliberately not promoted to actionable targets.

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

// MARK: - The four verbs

public struct MacFourVerbs: Sendable {
    private let host: any MacFourVerbsHost
    private let clock: any MacFourVerbsClock
    private let supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)?
    private let options: MacScreenRender.Options
    private let namedLocationRoots: [URL]
    /// fable51 item 31 — the two subscriptions `wait` ends on. They are seams
    /// here rather than inside the client because `wait` is the only caller and
    /// because the WAITING is paced by `clock`, which is a seam of this type:
    /// a host that blocked on real time would take the fake clock out of the
    /// loop and make a 60-second budget cost 60 real seconds in a test.
    ///
    /// AUTHORITY, explicitly: subscribing is not perception. Nothing is
    /// installed until the first `sight()` has SUCCEEDED, and that sight goes
    /// through `host.dispatch("look")`, which runs the full gate pre-flight
    /// (accessibility category + an active Full Mac window). A refused look
    /// returns blind before a single observer exists.
    private let effectObserverSource: any MacAXEffectObserverSource
    private let appActivationSource: any MacAppActivationObserverSource

    public init(
        host: any MacFourVerbsHost,
        clock: any MacFourVerbsClock = SystemMacFourVerbsClock(),
        supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)? = nil,
        options: MacScreenRender.Options = .default,
        namedLocationRoots: [URL]? = nil,
        effectObserverSource: any MacAXEffectObserverSource = defaultMacAXEffectObserverSource(),
        appActivationSource: any MacAppActivationObserverSource = defaultMacAppActivationObserverSource()
    ) {
        self.host = host
        self.clock = clock
        self.supplementalSource = supplementalSource
        self.options = options
        self.namedLocationRoots = namedLocationRoots ?? Self.commonHomeLocationRoots()
        self.effectObserverSource = effectObserverSource
        self.appActivationSource = appActivationSource
    }

    // MARK: 1 — EYES

    /// A FRESH look, rendered in the one canonical structure.
    ///
    /// `part` zooms: "the list", "the toolbar", "the Send button". Same shape,
    /// scoped, more detail for that part. ORDINALS ARE NEVER RENUMBERED by a
    /// zoom — row 3 is row 3 whether or not the render is scoped, because an
    /// ordinal that means something different in a zoomed view is the same
    /// class of bookkeeping trap the handles were. So a zoom onto content shows
    /// the section WHOLE (its cap raised) and names which rows matched; a zoom
    /// onto controls, which carry no ordinals, filters them.
    ///
    /// fable51 item 32a — `app` GLANCES SIDEWAYS. Naming a running app reads
    /// ITS front window without activating it: no focus steal, no window flip
    /// on User's screen, no three-call `go there / look / go back` dance. What
    /// comes back says plainly that the window is not in front, because whether
    /// it is in front decides whether she may act on it: `act` and `go` are
    /// still frontmost verbs, and a background sighting is a LOOK, not a
    /// license.
    public func screen(part: String? = nil, app: String? = nil) async -> MacFourVerbsReply {
        switch await sight(part: part, app: app) {
        case .blind(let reply):
            return reply
        case .seen(let sighting):
            var lead = "Looking at " + sighting.place + "."
            if let part, let note = sighting.zoomNote {
                lead = "Zoomed on \"\(part)\" in " + sighting.place + ". " + note
            }
            if app != nil {
                lead += " I read it where it sits — nothing was brought to the front."
            }
            return MacFourVerbsReply(
                ok: true,
                text: lead + "\n" + sighting.render,
                detail: sighting.detail
            )
        }
    }

    // MARK: 2 — HANDS

    /// The core: perceive → resolve a NAME → act → say what changed → show the
    /// fresh screen. All inside ONE call, so there is nothing for her to carry
    /// between turns. A bounded repeat is still one natural act: every attempt
    /// re-sees and re-resolves the named target, so a moving visual region is
    /// followed rather than clicked at an old coordinate.
    ///
    /// Ambiguity is an ANSWER, not an error: two matches return the candidates
    /// as a question and act on NOTHING.
    public func act(
        verb rawVerb: String,
        target: String,
        text: String? = nil,
        to destination: String? = nil,
        /// fable51 item 32b — WHOSE window `to` lives in. Absent (the ordinary
        /// case) is the single-window drag, byte-for-byte as it was.
        toApp destinationApp: String? = nil,
        seconds: Double? = nil,
        repeat requestedRepeat: Int? = nil,
        interval: Double? = nil,
        holding: String? = nil,
        button: String? = nil,
        scrollAmount: Int? = nil
    ) async -> MacFourVerbsReply {
        let requestedInput = requestedRepeat ?? 1
        let requested = max(1, requestedInput)
        let accepted = min(requested, Self.maximumActRepeats)
        let pause = max(0, min(interval ?? 0, Self.maximumActIntervalSeconds))
        let perAttemptBudget = max(0, min(seconds ?? 0, 10)) + pause
        let durationBound = perAttemptBudget > 0
            ? max(1, Int(Self.maximumActBurstSeconds / perAttemptBudget))
            : Self.maximumActRepeats
        let attempts = min(accepted, durationBound)
        if attempts == 1 {
            return await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                to: destination,
                toApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                scrollAmount: scrollAmount,
                attention: nil
            )
        }

        let attention: BurstAttention
        switch await beginBurstAttention() {
        case .success(let lease): attention = lease
        case .failure(let message):
            return MacFourVerbsReply(
                ok: false,
                text: "I couldn't start a continuous act safely. \(message)",
                detail: ["error": .string("continuous_attention_unavailable")]
            )
        }
        let burstStartedAt = clock.monotonicSeconds()
        var completed = 0
        var visiblyVerified = 0
        var runtimeLimited = false
        var finalReply: MacFourVerbsReply?
        for attempt in 1...attempts {
            guard !Task.isCancelled else { break }
            if attempt > 1,
               clock.monotonicSeconds() - burstStartedAt >= Self.maximumActBurstSeconds {
                runtimeLimited = true
                break
            }
            let reply = await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                to: destination,
                toApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                scrollAmount: scrollAmount,
                attention: attention
            )
            finalReply = reply
            guard reply.ok else { break }
            completed += 1
            if Self.string(reply.detail["verification"]) == MotorVerificationState.satisfied.rawValue {
                visiblyVerified += 1
            }
            if attempt < attempts, pause > 0 {
                let elapsed = max(0, clock.monotonicSeconds() - burstStartedAt)
                let remaining = max(0, Self.maximumActBurstSeconds - elapsed)
                guard remaining > 0 else {
                    runtimeLimited = true
                    break
                }
                await clock.sleep(seconds: min(pause, remaining))
            }
        }
        if attention.owned {
            _ = try? await host.dispatch(action: "attention", body: ["mode": .string("stop")])
        }

        guard let finalReply else {
            return MacFourVerbsReply(
                ok: false,
                text: "The repeated act was cancelled before the first attempt.",
                detail: ["error": .string("cancelled")]
            )
        }
        var detail = finalReply.detail
        detail["repeat_requested"] = .int(Int64(requested))
        detail["repeat_requested_input"] = .int(Int64(requestedInput))
        detail["repeat_accepted"] = .int(Int64(accepted))
        detail["repeat_planned"] = .int(Int64(attempts))
        detail["repeat_completed"] = .int(Int64(completed))
        detail["repeat_visibly_verified"] = .int(Int64(visiblyVerified))
        detail["repeat_stopped_early"] = .bool(completed < requested)
        let elapsed = max(0, clock.monotonicSeconds() - burstStartedAt)
        detail["repeat_elapsed_seconds"] = .double(elapsed)
        detail["repeat_runtime_limited"] = .bool(runtimeLimited)
        if let holding { detail["holding"] = .string(holding) }
        if let button { detail["button"] = .string(button) }
        if completed == attempts, visiblyVerified == completed {
            detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
            detail["verification_evidence"] = .string("fresh_visible_evidence_for_every_burst_attempt")
        } else if finalReply.ok {
            detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
            detail.removeValue(forKey: "verification_evidence")
        }

        let hardCapNote = accepted < requested
            ? " The \(Self.maximumActRepeats)-attempt safety cap limited this burst before execution."
            : ""
        let durationNote = attempts < accepted
            ? " The 30-second safety bound limited this burst to \(attempts)."
            : ""
        let runtimeNote = runtimeLimited
            ? " The 30-second runtime boundary stopped the burst before another attempt."
            : ""
        let proof: String
        if completed == 0 {
            proof = "No attempt completed."
        } else if visiblyVerified == completed {
            proof = "Every completed attempt had fresh visible proof."
        } else {
            proof = "\(visiblyVerified) had fresh visible proof; \(completed - visiblyVerified) remained unverified."
        }
        let lead: String
        if completed == attempts {
            lead = "Completed \(completed)/\(requested) requested attempts. \(proof)\(hardCapNote)\(durationNote)\(runtimeNote)"
        } else {
            lead = "Stopped after \(completed)/\(requested) requested attempts. \(proof)\(hardCapNote)\(durationNote)\(runtimeNote)"
        }
        return MacFourVerbsReply(
            ok: finalReply.ok && completed == attempts,
            text: lead + "\n" + finalReply.text,
            detail: detail
        )
    }

    static let maximumActRepeats = 12
    static let maximumActIntervalSeconds = 2.0
    static let maximumActBurstSeconds = 30.0

    struct BurstAttention: Sendable {
        let session: String
        let userSequence: Int64
        let owned: Bool
    }

    enum BurstAttentionStart {
        case success(BurstAttention)
        case failure(String)
    }

    private func beginBurstAttention() async -> BurstAttentionStart {
        func lease(from result: MacControlResult, owned: Bool) -> BurstAttention? {
            guard result.ok else { return nil }
            let output = Self.object(result.output)
            let attention = Self.object(output["attention"])
            guard let session = Self.string(attention["session"]),
                  let userSequence = Self.int(attention["user_sequence"]),
                  Self.bool(attention["yield_required"]) != true,
                  Self.bool(attention["refresh_required"]) != true else { return nil }
            return BurstAttention(session: session, userSequence: userSequence, owned: owned)
        }

        do {
            let status = try await host.dispatch(action: "attention", body: ["mode": .string("status")])
            if Self.bool(Self.object(status.output)["active"]) == true {
                guard let current = lease(from: status, owned: false) else {
                    return .failure("The existing attention session needs a fresh observation first.")
                }
                return .success(current)
            }
            let started = try await host.dispatch(action: "attention", body: [
                "mode": .string("start"),
                "duration_seconds": .int(Int64(Self.maximumActBurstSeconds)),
            ])
            guard let created = lease(from: started, owned: true) else {
                return .failure("The Mac's bounded human-takeover observer did not become ready.")
            }
            return .success(created)
        } catch {
            return .failure("The human-takeover observer refused: \(error).")
        }
    }

    static func addAttention(_ attention: BurstAttention?, to body: inout [String: JSONValue]) {
        guard let attention else { return }
        body["attention_session"] = .string(attention.session)
        body["attention_user_sequence"] = .int(attention.userSequence)
    }

    private func actOnce(
        verb rawVerb: String,
        target: String,
        text: String?,
        to destination: String?,
        toApp destinationApp: String?,
        seconds: Double?,
        holding: String?,
        button rawButton: String?,
        scrollAmount: Int?,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        let (verbName, parsedDirection) = Self.parseVerb(rawVerb)
        // fable51 item 32b — `to_app` says whose window the DROP lands in, so
        // it is meaningless anywhere but a drag. Refused before a look, because
        // silently ignoring it would let the model believe a cross-app act
        // happened when a same-window one did.
        let namedDestinationApp = destinationApp
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let namedDestinationApp {
            guard verbName == PhysicalVerb.drag.rawValue else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.verbNotDraggableWords(verbName),
                    detail: ["error": .string(MacCrossAppDrag.verbNotDraggableReason)]
                )
            }
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.missingDestinationWords(namedDestinationApp),
                    detail: ["error": .string(MacCrossAppDrag.missingDestinationReason)]
                )
            }
        }
        let amount = scrollAmount ?? 0
        guard (0...120).contains(amount), amount == 0 || verbName == "scroll" else {
            return MacFourVerbsReply(ok: false,
                text: "Scroll amount must be 1–120 lines, or 0 for the ordinary/default action. I haven't sent input.",
                detail: ["error": .string("invalid_scroll_amount")])
        }
        let normalizedButton = rawButton?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Some tool bindings require every declared field. An explicit auto
        // value preserves ordinary semantic/key/hover actions in those bindings.
        let button = normalizedButton == "auto" ? nil : normalizedButton
        if let button {
            guard MacMouseButton(rawValue: button) != nil,
                  ["click", "open", "drag", "hold"].contains(verbName),
                  !(verbName == "hold" && Self.keySpec(target) != nil) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "Use auto for the ordinary action, or left/right on a click, open, drag, or pointer hold. I haven't sent input.",
                    detail: ["error": .string("invalid_mouse_button_action")]
                )
            }
        }
        let direction: ScrollDirection = {
            guard verbName == MacActVerb.scroll.rawValue else { return parsedDirection }
            let hint = Self.normalize(text ?? "")
            if hint == "up" || hint.contains("scroll up") { return .up }
            if hint == "down" || hint.contains("scroll down") { return .down }
            if hint == "left" || hint.contains("scroll left") { return .left }
            if hint == "right" || hint.contains("scroll right") { return .right }
            return parsedDirection
        }()
        if let physical = PhysicalVerb(rawValue: verbName) {
            return await performPhysical(
                physical,
                target: target,
                destination: destination,
                destinationApp: namedDestinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                attention: attention
            )
        }
        guard let verb = MacActVerb(rawValue: verbName) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I don't have a \"\(rawVerb.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                    + "hand yet. What I can do: "
                    + (MacActVerb.allCases.map(\.rawValue) + PhysicalVerb.allCases.map(\.rawValue))
                        .joined(separator: ", ") + ".",
                detail: ["error": .string("unknown_verb"), "verb": .string(rawVerb)]
            )
        }
        if verb == .type, (text ?? "").isEmpty {
            return MacFourVerbsReply(
                ok: false,
                text: "Nothing to type — give me the words and I'll put them in \"\(target)\".",
                detail: ["error": .string("missing_text")]
            )
        }

        // a. A FRESH percept. Never a stored one: resolution happens against the
        //    screen as it is at the moment of acting, which is the entire reason
        //    `frame_id` can leave her hands.
        var sighting: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let hit): sighting = hit
        }

        // b. RESOLVE BY NAME.
        var resolution = verb == .scroll
            ? Self.resolveScrollTarget(target, among: sighting.targets)
            : Self.resolve(target, among: sighting.targets)
        var reobservedAfterTransientMiss = false
        var acquisitionSamples = 0
        if case .none = resolution, Self.isPotentialDynamicVisualReference(target) {
            // Fast appearance-only association needs a third frame to establish
            // motion. Spend the same two-frame acquisition budget on a temporal
            // name that cannot exist yet, without stripping its qualifier.
            let temporal = Self.hasTemporalQualifier(target)
            let sampledApp = sighting.bundleIdentifier ?? sighting.appName
            var previousTargets = sighting.targets
            for sample in 0..<(temporal ? 3 : 1) {
                guard case .none = resolution else { break }
                if sample == 2, !Self.canConfirmTemporalTurn(target, previous: previousTargets, current: sighting.targets) { break }
                if temporal { await clock.sleep(seconds: 0.06) }
                switch await sight(part: nil) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return Self.motionAppChangedReply(screen: refreshed.render)
                    }
                    previousTargets = sighting.targets
                    sighting = refreshed
                    resolution = verb == .scroll
                        ? Self.resolveScrollTarget(target, among: sighting.targets)
                        : Self.resolve(target, among: sighting.targets)
                    acquisitionSamples += 1
                    reobservedAfterTransientMiss = true
                }
            }
        }
        if verb == .click || verb == .open {
            // A model round trip can leave only one usable motion sample.
            // Acquire at most two more, inside this act, and always resolve
            // again against the newest evidence. No click is sent while the
            // target is absent/ambiguous, and no remembered point is reused.
            let sampledApp = sighting.bundleIdentifier ?? sighting.appName
            for _ in 0..<max(0, 2 - acquisitionSamples) {
                guard case .hit(let candidate) = resolution,
                      candidate.physicalOnly, candidate.motionUncertain else { break }
                switch await sight(part: nil) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return MacFourVerbsReply(
                            ok: false,
                            text: "The foreground app changed while I was observing motion. I haven't clicked.\n" + refreshed.render,
                            detail: ["error": .string("motion_sampling_app_changed")]
                        )
                    }
                    sighting = refreshed
                    resolution = Self.resolve(target, among: refreshed.targets)
                }
            }
        }
        switch resolution {
        case .none(let nearest):
            var line = "Nothing on this screen is called \"\(target)\"."
            if !nearest.isEmpty {
                line += " What I can see: " + nearest.joined(separator: " · ") + "."
            } else {
                line += " Nothing here is named at all — the screen below is everything I can read."
            }
            return MacFourVerbsReply(
                ok: false,
                text: line + "\n" + sighting.render,
                detail: [
                    "error": .string("no_match"),
                    "target": .string(target),
                    "dynamic_reobserved": .bool(reobservedAfterTransientMiss),
                ]
            )

        case .ambiguous(let candidates):
            // The reply IS the question. Nothing is acted on.
            let listed = candidates.map { candidate -> String in
                Self.recoveryName(candidate) + " (\(candidate.kind))"
            }
            return MacFourVerbsReply(
                ok: false,
                text: "\(candidates.count) things match \"\(target)\": "
                    + listed.joined(separator: ", ")
                    + ". Which one? I haven't touched anything.\n" + sighting.render,
                detail: [
                    "error": .string("ambiguous"),
                    "target": .string(target),
                    "candidates": .array(listed.map { .string($0) }),
                ]
            )

        case .hit(let candidate):
            guard candidate.enabled else {
                return MacFourVerbsReply(
                    ok: false, text: "\(Self.name(candidate)) is disabled. I haven't touched it.\n" + sighting.render,
                    detail: ["error": .string("target_disabled"), "target": .string(target)]
                )
            }
            if candidate.regionOnly, verb != .scroll {
                return MacFourVerbsReply(
                    ok: false,
                    text: "\(Self.name(candidate)) is a region, not a control. I can scroll it; name a visible thing inside it to click, open, type, select, toggle, or dismiss.",
                    detail: ["error": .string("region_needs_inner_target")]
                )
            }
            if candidate.physicalOnly,
               ![MacActVerb.click, .open, .scroll].contains(verb) {
                return MacFourVerbsReply(
                    ok: false,
                    text: "\(Self.name(candidate)) is an unlabeled visual region, so I can physically click, open, scroll, move, hover, hold, or drag there without pretending I know its semantic role.",
                    detail: ["error": .string("visual_region_needs_physical_action")]
                )
            }
            // Scrolling a scroll container is a physical wheel gesture aimed at
            // that region. The semantic closed-loop meaning of scroll is
            // "bring this element into view", which is inert when the named
            // thing is the web area/list itself. Route containers through the
            // same hand so a page or game surface actually moves.
            if verb == .scroll,
               (amount > 0 || direction.isHorizontal || Self.physicalScrollKinds.contains(candidate.kind)),
               amount > 0 || direction.isHorizontal || candidate.kind == "web area" || candidate.frame != nil {
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
            }
            if holding != nil || button != nil {
                guard verb != .type else {
                    return MacFourVerbsReply(
                        ok: false,
                        text: "I can't hold keys while typing text; use a key or chord action instead.",
                        detail: ["error": .string("holding_not_supported_for_type")]
                    )
                }
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    button: button,
                    attention: attention,
                    before: sighting
                )
            }
            if candidate.isSupplemental {
                let reply = await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    scrollAmount: amount,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
                guard reobservedAfterTransientMiss else { return reply }
                var detail = reply.detail
                detail["dynamic_reobserved"] = .bool(true)
                return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
            }
            // c. DRIVE THE EXISTING ACT PATH. The handle and the frame id are
            //    OURS — they are read off the look we just took and never
            //    appear in the reply. Raise/focus setup, the observer, the
            //    diff and every gate are the closed loop's, unchanged.
            var body: [String: JSONValue] = [
                "verb": .string(verb.rawValue),
                "handle": .string(candidate.handle),
                "frame_id": .string(sighting.frameId),
            ]
            if let text { body["text"] = .string(text) }
            if verb == .scroll { body["direction"] = .string(direction.rawValue) }
            Self.addAttention(attention, to: &body)

            let result: MacControlResult
            do {
                result = try await host.dispatch(action: "act", body: body)
            } catch {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I couldn't \(verb.rawValue) \(Self.name(candidate)): \(error).",
                    detail: ["error": .string("\(error)")]
                )
            }
            let output = Self.object(result.output)

            // d. THE REPLY, IN WORDS — then the fresh screen.
            guard result.ok else {
                // A refusal from below is translated, never echoed as a code.
                // Its own `guidance` is already plain words written for her, so
                // it is used when present rather than paraphrased.
                let mechanism = Self.plainWords(
                    Self.string(output["guidance"]) ?? Self.string(output["message"])
                ) ?? Self.refusalWords(result.error ?? "unknown")
                let after = await sight(part: nil)
                var line = "Didn't \(verb.rawValue) \(Self.name(candidate)). " + mechanism
                if case .seen(let hit) = after { line += "\n" + hit.render }
                return MacFourVerbsReply(
                    ok: false,
                    text: line,
                    detail: Self.operationDetail(result).merging([
                        "error": .string(result.error ?? "refused"),
                        "verb": .string(verb.rawValue),
                        "target": .string(target),
                    ]) { current, _ in current }
                )
            }

            var effect = Self.effectWords(output: output, verb: verb, typed: text)
            let after = await sight(part: nil)
            let stayedInApp: Bool = {
                guard case .seen(let hit) = after else { return false }
                if let beforeID = sighting.bundleIdentifier, let afterID = hit.bundleIdentifier {
                    return beforeID == afterID
                }
                return sighting.appName.map(Self.normalize) == hit.appName.map(Self.normalize)
            }()
            if effect.status == "acted", !stayedInApp {
                effect = EffectWords(
                    sentence: "The fresh screen is in a different app, so that outcome is not verified.",
                    status: "acted_unobserved"
                )
            }
            var line = (effect.status == "acted"
                ? Self.pastTense(verb, direction: direction)
                : Self.attempted(verb, direction: direction))
                + " " + Self.name(candidate) + ". " + effect.sentence
            if case .seen(let hit) = after { line += "\n" + hit.render }
            var detail = Self.operationDetail(result)
            detail["verb"] = .string(verb.rawValue)
            detail["target"] = .string(target)
            detail["matched"] = .string(Self.name(candidate))
            detail["status"] = .string(effect.status)
            detail["dynamic_reobserved"] = .bool(reobservedAfterTransientMiss)
            // `acted` is the closed loop's semantic verdict, not merely "an
            // event was emitted": navigation moved structurally and matched
            // its destination; typing read the intended edit back from the
            // field; other verbs produced an observed app reaction. Promote
            // that evidence on the model-facing receipt while leaving every
            // acted_unobserved branch honestly unverified.
            if effect.status == "acted" {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("closed_loop_semantic_effect")
            } else {
                detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
                detail.removeValue(forKey: "verification_evidence")
            }
            return MacFourVerbsReply(
                ok: true,
                text: line,
                detail: detail
            )
        }
    }

    enum PhysicalVerb: String, CaseIterable {
        case hover
        case drag
        case hold
        case key
        case move
    }

    static let physicalScrollKinds: Set<String> = [
        "web area", "scroll area", "scroll bar", "table", "outline", "list", "collection",
    ]

    private func performPhysical(
        _ verb: PhysicalVerb,
        target: String,
        destination: String?,
        destinationApp: String? = nil,
        seconds: Double?,
        holding: String?,
        button: String?,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        if verb == .hold, Self.keySpec(target) != nil, holding != nil {
            return MacFourVerbsReply(
                ok: false,
                text: "A keyboard hold already keeps its key set down; include all keys in that target instead of a second held-key set.",
                detail: ["error": .string("nested_hold_not_supported")]
            )
        }
        // Keys are physical but not on-screen targets. A key spec uses the same
        // syntax as mac_keystroke: `w`, `space`, `cmd+s`, `shift+1`.
        if verb == .key || (verb == .hold && Self.keySpec(target) != nil) {
            let spec = Self.keySpec(target) ?? target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spec.isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Which key or chord should I use?")
            }
            let before: Sighting
            switch await sight(part: nil) {
            case .blind(let reply): return reply
            case .seen(let seen): before = seen
            }
            var body: [String: JSONValue] = [
                "gesture": .string(verb == .hold ? "hold_key" : "key"),
                "keys": .string(spec),
            ]
            if let seconds { body["seconds"] = .double(seconds) }
            if let holding { body["holding"] = .string(holding) }
            return await performHand(
                body: body,
                description: verb == .hold ? "Held \(target)." : "Pressed \(target).",
                attention: attention,
                before: before
            )
        }

        var before: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let seen): before = seen
        }
        var resolution = Self.resolve(target, among: before.targets)
        var reobservedAfterTransientMiss = false
        if case .none = resolution, Self.isPotentialDynamicVisualReference(target) {
            let temporal = Self.hasTemporalQualifier(target)
            let sampledApp = before.bundleIdentifier ?? before.appName
            var previousTargets = before.targets
            for sample in 0..<(temporal ? 3 : 1) {
                guard case .none = resolution else { break }
                if sample == 2, !Self.canConfirmTemporalTurn(target, previous: previousTargets, current: before.targets) { break }
                if temporal { await clock.sleep(seconds: 0.06) }
                switch await sight(part: nil) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return Self.motionAppChangedReply(screen: refreshed.render)
                    }
                    previousTargets = before.targets
                    before = refreshed
                    resolution = Self.resolve(target, among: before.targets)
                    reobservedAfterTransientMiss = true
                }
            }
        }
        if !reobservedAfterTransientMiss,
           verb == .drag,
           // fable51 item 32b — a cross-app destination is NOT expected in this
           // window, so "it dropped out of the frontmost sighting" is not a
           // transient miss to chase. Its own anchored sight resolves it.
           destinationApp == nil,
           let destination,
           case .hit = resolution,
           case .none = Self.resolve(destination, among: before.targets),
           Self.isPotentialDynamicVisualReference(destination) {
            // A drag needs two current points. If only its moving destination
            // dropped out, refresh the entire sight and resolve both ends
            // again so an old source coordinate is never paired with a fresh
            // destination.
            let temporal = Self.hasTemporalQualifier(destination)
            let sampledApp = before.bundleIdentifier ?? before.appName
            var previousTargets = before.targets
            for sample in 0..<(temporal ? 3 : 1) {
                guard case .hit = resolution,
                      case .none = Self.resolve(destination, among: before.targets) else { break }
                if sample == 2, !Self.canConfirmTemporalTurn(destination, previous: previousTargets, current: before.targets) { break }
                if temporal { await clock.sleep(seconds: 0.06) }
                switch await sight(part: nil) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    guard (refreshed.bundleIdentifier ?? refreshed.appName) == sampledApp else {
                        return Self.motionAppChangedReply(screen: refreshed.render)
                    }
                    previousTargets = before.targets
                    before = refreshed
                    resolution = Self.resolve(target, among: before.targets)
                    reobservedAfterTransientMiss = true
                }
            }
        }
        let source: ActTarget
        switch resolution {
        case .hit(let hit): source = hit
        case .none(let nearest):
            return unresolvedPhysical(target, nearest: nearest, screen: before.render)
        case .ambiguous(let candidates):
            return ambiguousPhysical(target, candidates: candidates, screen: before.render)
        }
        guard source.enabled else {
            return MacFourVerbsReply(ok: false, text: "\(Self.name(source)) is disabled.\n" + before.render)
        }
        if source.regionOnly, verb != .hover, verb != .move, verb != .drag {
            return MacFourVerbsReply(
                ok: false,
                text: "\(Self.name(source)) is a region rather than an object I can \(verb.rawValue). I can move to it, hover over it, or drag across it; name a visible thing inside it for other gestures.",
                detail: ["error": .string("region_needs_inner_target")]
            )
        }
        guard let sourceFrame = Self.visiblePortion(of: source.frame, within: before.visibleFrame) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I can name \(Self.name(source)), but this screen did not publish a safe physical point for it.\n"
                    + before.render,
                detail: ["error": .string("target_has_no_physical_point")]
            )
        }
        let exactSourceAlias = source.aliases.contains {
            Self.normalize($0) == Self.normalize(target)
        }
        guard let start = Self.safeAimPoint(for: source, in: sourceFrame,
            describedBy: exactSourceAlias ? "" : target) else {
            return Self.obstructedPointReply(screen: before.render)
        }
        let spokenSource = Self.spokenName(source, requestedAs: target)

        // fable51 item 32b — TWO ANCHORS. The source has just been resolved in
        // the frontmost window; when `to_app` names somebody else's window the
        // destination is resolved THERE, without focus, and the whole drag is
        // handled below. Nothing above this line changed, and with `to_app`
        // absent nothing below it runs.
        if verb == .drag, let destinationApp, let destination {
            return await performCrossAppDrag(
                source: source,
                spokenSource: spokenSource,
                start: start,
                destination: destination,
                destinationApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                attention: attention,
                before: before
            )
        }

        var body: [String: JSONValue] = [
            "gesture": .string(verb.rawValue),
            "x": .double(start.x),
            "y": .double(start.y),
        ]
        if verb == .drag {
            body["travel_seconds"] = .double(seconds ?? 0)
        } else if let seconds { body["seconds"] = .double(seconds) }
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        var description: String
        if verb == .drag {
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Where should I drag \(spokenSource) to?")
            }
            let endTarget: ActTarget
            switch Self.resolve(destination, among: before.targets) {
            case .hit(let hit): endTarget = hit
            case .none(let nearest):
                return unresolvedPhysical(destination, nearest: nearest, screen: before.render)
            case .ambiguous(let candidates):
                return ambiguousPhysical(destination, candidates: candidates, screen: before.render)
            }
            guard let endFrame = Self.visiblePortion(of: endTarget.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can name \(Self.name(endTarget)), but it has no safe physical point.\n" + before.render,
                    detail: ["error": .string("destination_has_no_physical_point")]
                )
            }
            let exactDestinationAlias = endTarget.aliases.contains {
                Self.normalize($0) == Self.normalize(destination)
            }
            guard let end = Self.safeAimPoint(for: endTarget, in: endFrame,
                describedBy: exactDestinationAlias ? "" : destination) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            guard MacRegionAim.pathIsClear(from: start, to: end,
                excluding: source.excludedFrames + endTarget.excludedFrames) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            body["to_x"] = .double(end.x)
            body["to_y"] = .double(end.y)
            description = "\(button == "right" ? "Right-dragged" : "Dragged") \(spokenSource) to \(Self.spokenName(endTarget, requestedAs: destination))."
        } else {
            switch verb {
            case .hover: description = "Hovered over \(spokenSource)."
            case .hold: description = button == "right" ? "Held the right button on \(spokenSource)." : "Held \(spokenSource)."
            case .move: description = "Moved to \(spokenSource)."
            case .drag, .key: description = "Used \(spokenSource)."
            }
        }
        let reply = await performHand(
            body: body,
            description: description,
            attention: attention,
            before: before,
            allowGenericScreenChangeVerification: !source.physicalOnly,
            afterPart: source.physicalOnly ? "visual surface" : nil,
            pointerTarget: (verb == .hover || verb == .move) ? target : nil
        )
        var detail = reply.detail
        if reobservedAfterTransientMiss { detail["dynamic_reobserved"] = .bool(true) }
        if let button { detail["button"] = .string(button) }
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    // MARK: - fable51 item 32b — the two-anchor drag

    /// `act(drag, target:, to:, to_app:)` — the source in the window in front,
    /// the destination in a NAMED app's front window, and one drag across the
    /// two. The order of operations is the whole design:
    ///
    ///   1. RESOLVE the destination through the background sight. No focus
    ///      moves for a resolution, so a refusal here — not running, ambiguous,
    ///      our own process, no such thing in that window — costs User nothing
    ///      and leaves his screen exactly as it was.
    ///   2. REFUSE what must not be dragged: a password field at either end of
    ///      the line, or on it.
    ///   3. RAISE, once, only if the drop needs it, and SAY SO. A window behind
    ///      another cannot receive a drop; that is the reason focus moved, it
    ///      goes in the sentence and on the receipt, and if raising would bury
    ///      the source instead this refuses before anything moves.
    ///   4. DRAG, once.
    ///
    /// The pre-drag reading of the DESTINATION window is what the post-act look
    /// is compared against — so "did the drop land" is judged against the
    /// window that received it, not against the source window we left behind.
    private func performCrossAppDrag(
        source: ActTarget,
        spokenSource: String,
        start: MacPointerPosition,
        destination: String,
        destinationApp: String,
        seconds: Double?,
        holding: String?,
        button: String?,
        attention: BurstAttention?,
        before: Sighting
    ) async -> MacFourVerbsReply {
        // 1. THE SECOND ANCHOR. `sight(app:)` walks that app's front window and
        //    activates nothing; the look handler already answers not-running,
        //    ambiguous and self-process in MacBackgroundSight's own words.
        let anchored: Sighting
        switch await sight(part: nil, app: destinationApp) {
        case .seen(let seen): anchored = seen
        case .blind(let reply):
            let why = Self.string(reply.detail["message"])
            return MacFourVerbsReply(
                ok: false,
                text: "I can't drop into \(destinationApp). "
                    + (why ?? reply.text)
                    + " I haven't raised anything or sent input.",
                detail: reply.detail
            )
        }
        let destinationAppName = anchored.appName ?? destinationApp

        // gpt-5.5 review — EVERY refusal below is about a window User did not
        // bring forward. None of them may print `anchored.render`: that is the
        // whole background window — its rows, its readouts, its values — and
        // appending it to "there is nothing called X here" made a target that
        // cannot match into a way to read any running app's front window.
        // `MacCrossAppDrag` owns the bound; these say the app, the window, and
        // at most a capped list of names.
        let endTarget: ActTarget
        switch Self.resolve(destination, among: anchored.targets) {
        case .hit(let hit): endTarget = hit
        case .none(let nearest):
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.unresolvedDestinationWords(
                    destination, in: destinationAppName, nearest: nearest
                ),
                detail: [
                    "error": .string(MacCrossAppDrag.unresolvedDestinationReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        case .ambiguous(let candidates):
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.ambiguousDestinationWords(
                    destination, in: destinationAppName,
                    candidates: candidates.map(Self.recoveryName)
                ),
                detail: [
                    "error": .string(MacCrossAppDrag.ambiguousDestinationReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }
        guard let endFrame = Self.visiblePortion(of: endTarget.frame, within: anchored.visibleFrame) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationNoPointWords(
                    Self.spokenName(endTarget, requestedAs: destination), in: destinationAppName
                ),
                detail: [
                    "error": .string(MacCrossAppDrag.destinationNoPointReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }
        let exactDestinationAlias = endTarget.aliases.contains {
            Self.normalize($0) == Self.normalize(destination)
        }
        guard let end = Self.safeAimPoint(for: endTarget, in: endFrame,
            describedBy: exactDestinationAlias ? "" : destination) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationObstructedWords(in: destinationAppName),
                detail: [
                    "error": .string(MacCrossAppDrag.destinationObstructedReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }

        // 2. SECURE INPUT. Dropping into a credential box is the same boundary
        //    `type` refuses at, and a drag that merely CROSSES one can
        //    spring-load it open on the way past. Both ends and the line
        //    between them, before anything is raised.
        if MacCrossAppDrag.isSecureKind(endTarget.kind) {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationIsSecureWords(
                    destination: Self.spokenName(endTarget, requestedAs: destination)
                ),
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            )
        }
        let secureFrames = (before.targets + anchored.targets)
            .filter { MacCrossAppDrag.isSecureKind($0.kind) }
            .compactMap(\.frame)
        guard MacRegionAim.pathIsClear(from: start, to: end, excluding: secureFrames) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.pathCrossesSecureWords(destinationApp: destinationAppName),
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            )
        }
        guard MacRegionAim.pathIsClear(from: start, to: end,
            excluding: source.excludedFrames + endTarget.excludedFrames) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationObstructedWords(in: destinationAppName),
                detail: [
                    "error": .string(MacCrossAppDrag.destinationObstructedReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }

        // 3. THE RAISE. Measured, not assumed: `anchored.isFront` is the fact
        //    the look published about the window it actually read.
        let raise = MacCrossAppDrag.raise(
            destinationApp: destinationAppName,
            destinationIsFront: anchored.isFront
        )
        var raiseDetail: [String: JSONValue] = [
            "cross_app_drag": .bool(true),
            "destination_app": .string(destinationAppName),
            "destination_resolved_without_focus": .bool(true),
            "raise_reason": .string(raise.reason),
        ]
        if let bundle = anchored.bundleIdentifier {
            raiseDetail["destination_app_bundle"] = .string(bundle)
        }
        // What the drag actually lets go of, and where. Re-derived after the
        // raise (below) because raising re-lays a window: the pre-raise point
        // is a resolution, not yet an aim.
        var dropPoint = end
        var dropTarget = endTarget
        var anchoredAfterRaise = anchored
        if raise.needed {
            // gpt-5.5 review — WHAT COVERS THE SOURCE IS THE WINDOW, not the
            // union of the elements read inside it. A window whose title bar,
            // toolbar or blank body sits over `start` publishes no target there,
            // so the union missed it, this guard passed, and the post-raise
            // mouse-down landed on the destination window instead of on the
            // thing being picked up. Ask the window's own frame first.
            guard !MacCrossAppDrag.raiseWouldCoverSource(
                start,
                destinationBounds: MacCrossAppDrag.coverageBounds(
                    windowFrame: anchored.windowFrame,
                    targetFrames: anchored.targets.compactMap(\.frame)
                )
            ) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.coveredSourceWords(
                        source: spokenSource, destinationApp: destinationAppName
                    ),
                    detail: raiseDetail.merging([
                        "raised": .bool(false),
                        "error": .string(MacCrossAppDrag.coveredSourceReason),
                    ]) { current, _ in current }
                )
            }
            let focused: MacControlResult
            do {
                focused = try await host.dispatch(
                    action: "focus_app",
                    body: ["app": .string(destinationAppName)]
                )
            } catch {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.raiseFailedWords(destinationAppName, because: "\(error)"),
                    detail: raiseDetail.merging([
                        "raised": .bool(false),
                        "error": .string(MacCrossAppDrag.raiseFailedReason),
                    ]) { current, _ in current }
                )
            }
            guard focused.ok else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.raiseFailedWords(destinationAppName, because: focused.error),
                    detail: raiseDetail.merging([
                        "raised": .bool(false),
                        "error": .string(MacCrossAppDrag.raiseFailedReason),
                    ]) { current, _ in current }
                )
            }

            // gpt-5.5 review — LOOK AGAIN BEFORE AIMING. Everything above was
            // resolved against a window that was BEHIND another one. Bringing it
            // forward is a layout event: the window can move, resize, or arrive
            // somewhere it was not, and a point computed before that is a point
            // about a screen that no longer exists. So the destination window is
            // re-read once, the endpoint re-resolved in it, and the coverage
            // question asked again of the frame it actually landed on — and if
            // any of those answers changed, this stops rather than pressing the
            // mouse down on a guess. Focus has moved by then, and each refusal
            // says so.
            let reread: Sighting
            switch await sight(part: nil, app: destinationAppName) {
            case .seen(let seen): reread = seen
            case .blind(let reply):
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationMovedWords(destination, in: destinationAppName),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.destinationMovedReason),
                        "reread_error": reply.detail["error"] ?? .string("look_failed"),
                    ]) { current, _ in current }
                )
            }
            anchoredAfterRaise = reread

            func movedRefusal() -> MacFourVerbsReply {
                MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationMovedWords(destination, in: destinationAppName),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.destinationMovedReason),
                    ]) { current, _ in current }
                )
            }

            guard case .hit(let rereadTarget) = Self.resolve(destination, among: reread.targets) else {
                return movedRefusal()
            }
            guard let rereadFrame = Self.visiblePortion(
                of: rereadTarget.frame, within: reread.visibleFrame
            ) else { return movedRefusal() }
            let rereadExactAlias = rereadTarget.aliases.contains {
                Self.normalize($0) == Self.normalize(destination)
            }
            guard let rereadPoint = Self.safeAimPoint(
                for: rereadTarget, in: rereadFrame,
                describedBy: rereadExactAlias ? "" : destination
            ) else { return movedRefusal() }

            // The window is in front NOW. If its real frame covers the pick-up
            // point, the mouse-down would land on it — the exact failure the
            // pre-raise guard exists to prevent, asked again of the truth.
            guard !MacCrossAppDrag.raiseWouldCoverSource(
                start,
                destinationBounds: MacCrossAppDrag.coverageBounds(
                    windowFrame: reread.windowFrame,
                    targetFrames: reread.targets.compactMap(\.frame)
                )
            ) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.coveredSourceAfterRaiseWords(
                        source: spokenSource, destinationApp: destinationAppName
                    ),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.coveredSourceAfterRaiseReason),
                    ]) { current, _ in current }
                )
            }

            // The secure boundary is re-drawn on the line that will actually be
            // travelled: a raise can bring a password field onto it.
            let rereadSecureFrames = (before.targets + reread.targets)
                .filter { MacCrossAppDrag.isSecureKind($0.kind) }
                .compactMap(\.frame)
            if MacCrossAppDrag.isSecureKind(rereadTarget.kind) {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationIsSecureWords(
                        destination: Self.spokenName(rereadTarget, requestedAs: destination)
                    ),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.secureCrossingReason),
                    ]) { current, _ in current }
                )
            }
            guard MacRegionAim.pathIsClear(
                from: start, to: rereadPoint, excluding: rereadSecureFrames
            ) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.pathCrossesSecureWords(destinationApp: destinationAppName),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.secureCrossingReason),
                    ]) { current, _ in current }
                )
            }

            dropTarget = rereadTarget
            dropPoint = rereadPoint
            raiseDetail["reread_after_raise"] = .bool(true)
        }
        raiseDetail["raised"] = .bool(raise.needed)
        if raise.needed { raiseDetail["raised_app"] = .string(destinationAppName) }

        // 4. ONE DRAG.
        var body: [String: JSONValue] = [
            "gesture": .string(PhysicalVerb.drag.rawValue),
            "x": .double(start.x),
            "y": .double(start.y),
            "to_x": .double(dropPoint.x),
            "to_y": .double(dropPoint.y),
            "travel_seconds": .double(seconds ?? 0),
        ]
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        let spokenDestination = Self.spokenName(dropTarget, requestedAs: destination)
        let description = "\(button == "right" ? "Right-dragged" : "Dragged") \(spokenSource) "
            + "into \(destinationAppName) — onto \(spokenDestination). \(raise.words)"
        // The pre-act reading passed here is the DESTINATION window's, taken
        // after the raise when there was one: the post-act look lands on that
        // same window, so the comparison is drop evidence rather than the noise
        // of the window order having changed underneath it.
        let reply = await performHand(
            body: body,
            description: description,
            attention: attention,
            before: anchoredAfterRaise,
            allowGenericScreenChangeVerification: !dropTarget.physicalOnly
        )
        var detail = reply.detail
        for (key, value) in raiseDetail { detail[key] = value }
        if let button { detail["button"] = .string(button) }
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    private func performSupplementalSemantic(
        _ verb: MacActVerb,
        direction: ScrollDirection,
        scrollAmount: Int = 0,
        candidate: ActTarget,
        target: String,
        text: String?,
        holding: String?,
        button: String? = nil,
        attention: BurstAttention?,
        before: Sighting
    ) async -> MacFourVerbsReply {
        let spokenTarget = Self.spokenName(candidate, requestedAs: target)
        if let viewId = candidate.viewId, let mark = candidate.mark,
           verb != .open, verb != .scroll, holding == nil, button == nil {
            var body: [String: JSONValue] = [
                "view": .string(viewId),
                "mark": .int(Int64(mark)),
            ]
            if verb == .type {
                guard let text, !text.isEmpty else {
                    return MacFourVerbsReply(ok: false, text: "Nothing to type into \(spokenTarget).")
                }
                body["value"] = .string(text)
            } else {
                body["action"] = .string("AXPress")
            }
            return await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + spokenTarget + ".",
                before: before,
                target: target,
                verb: verb.rawValue,
                attention: attention
            )
        }

        var body: [String: JSONValue] = [:]
        let usesPageKey = verb == .scroll && candidate.kind == "web area"
            && !direction.isHorizontal && scrollAmount == 0
        if !usesPageKey {
            guard let candidateFrame = Self.visiblePortion(of: candidate.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can see \(spokenTarget), but I do not have a safe point for it.",
                    detail: ["error": .string("target_has_no_physical_point")]
                )
            }
            let exactAppearanceAlias = candidate.aliases.contains {
                Self.normalize($0) == Self.normalize(target)
            }
            guard let point = Self.safeAimPoint(for: candidate, in: candidateFrame,
                describedBy: exactAppearanceAlias ? "" : target) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            body["x"] = .double(point.x)
            body["y"] = .double(point.y)
        }
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        switch verb {
        case .click, .select, .toggle, .dismiss:
            body["gesture"] = .string("click")
        case .open:
            body["gesture"] = .string("double_click")
        case .type:
            guard let text, !text.isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Nothing to type into \(spokenTarget).")
            }
            body["gesture"] = .string("click_type")
            body["text"] = .string(text)
        case .scroll:
            if usesPageKey {
                // Live Chrome proof: synthesized wheel events were accepted
                // but inert on the AX web area, while the ordinary Page key
                // moved the same visible document and produced fresh proof.
                // Keep that physical distinction below the natural scroll
                // verb; the caller still names the region and direction.
                body["gesture"] = .string("key")
                body["keys"] = .string(direction == .up ? "pageup" : "pagedown")
            } else {
                body["gesture"] = .string("scroll")
                let magnitude = Int64(scrollAmount == 0 ? 6 : scrollAmount)
                body["dx"] = .int(direction == .left ? magnitude : direction == .right ? -magnitude : 0)
                body["dy"] = .int(direction == .up ? magnitude : direction == .down ? -magnitude : 0)
            }
        }
        let reply = await performHand(
            body: body,
            description: (button == "right" ? (verb == .open ? "Double-right-clicked" : "Right-clicked")
                : Self.pastTense(verb, direction: direction)) + " " + spokenTarget + ".",
            unverifiedDescription: verb == .scroll
                ? "Tried to scroll \(direction.rawValue) in \(spokenTarget)."
                : nil,
            attention: attention,
            before: before,
            allowGenericScreenChangeVerification: !candidate.physicalOnly,
            afterPart: candidate.physicalOnly ? "visual surface" : nil
        )
        var detail = reply.detail
        detail["verb"] = .string(verb.rawValue)
        if let button { detail["button"] = .string(button) }
        detail["target"] = .string(target)
        detail["matched"] = .string(Self.name(candidate))
        let physicalRoute: String
        switch verb {
        case .click, .select, .toggle, .dismiss: physicalRoute = "click"
        case .open: physicalRoute = "double_click"
        case .type: physicalRoute = "click_type"
        case .scroll: physicalRoute = usesPageKey ? "page_key" : "wheel"
        }
        detail["physical_route"] = .string(physicalRoute)
        detail["status"] = .string(
            Self.string(detail["verification"]) == MotorVerificationState.satisfied.rawValue
                ? "acted"
                : "acted_unobserved"
        )
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    private func performObservedDispatch(
        action: String,
        body: [String: JSONValue],
        description: String,
        before: Sighting,
        target: String,
        verb: String,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        do { result = try await host.dispatch(action: action, body: request) }
        catch {
            return MacFourVerbsReply(ok: false, text: "I couldn't act on \(target): \(error).")
        }
        guard result.ok else {
            return MacFourVerbsReply(
                ok: false,
                text: "Didn't \(verb) \"\(target)\". \(result.error ?? "The Mac refused the action.")\n" + before.render,
                detail: Self.operationDetail(result).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        return await observedReply(result: result, description: description, before: before)
    }

    private func performHand(
        body: [String: JSONValue],
        description: String,
        unverifiedDescription: String? = nil,
        attention: BurstAttention? = nil,
        before: Sighting?,
        allowGenericScreenChangeVerification: Bool = true,
        afterPart: String? = nil,
        pointerTarget: String? = nil
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
        // This composed physical-only act already owns a fresh pre-observation
        // and the mandatory observedReply below. Recapturing inside the hand
        // delays input after its motion-compensated point was calculated.
        if before != nil, afterPart == "visual surface", !allowGenericScreenChangeVerification {
            request["defer_visual_verification"] = .bool(true)
        }
        do { result = try await host.dispatch(action: "hand", body: request) }
        catch { return MacFourVerbsReply(ok: false, text: "I couldn't use that hand: \(error).") }
        guard result.ok else {
            return MacFourVerbsReply(
                ok: false,
                text: "Couldn't do that. \(result.error ?? "The Mac refused the gesture.")"
                    + (before.map { "\n" + $0.render } ?? ""),
                detail: Self.operationDetail(result).merging(["error": .string(result.error ?? "refused")]) { current, _ in current }
            )
        }
        return await observedReply(
            result: result,
            description: description,
            unverifiedDescription: unverifiedDescription,
            before: before,
            allowGenericScreenChangeVerification: allowGenericScreenChangeVerification,
            afterPart: afterPart,
            pointerTarget: pointerTarget
        )
    }

    private func observedReply(
        result: MacControlResult,
        description: String,
        unverifiedDescription: String? = nil,
        before: Sighting?,
        allowGenericScreenChangeVerification: Bool = true,
        afterPart: String? = nil,
        pointerTarget: String? = nil
    ) async -> MacFourVerbsReply {
        switch await sight(part: afterPart) {
        case .blind(let reply):
            return MacFourVerbsReply(
                ok: true,
                text: (unverifiedDescription ?? description)
                    + " The input went out, but I couldn't take the confirming look. " + reply.text,
                detail: Self.operationDetail(result).merging(["observed_after": .bool(false)]) { current, _ in current }
            )
        case .seen(let after):
            // A scoped post-action render is intentionally shaped differently
            // from the full pre-action screen. That difference is presentation,
            // not effect evidence; visible values and handler evidence remain
            // independently comparable.
            let structuralChanged = afterPart == nil
                ? before.map { $0.effectRender != after.effectRender }
                : nil
            let handlerEvidence = Self.bool(Self.object(result.output)["verified"]) == true
            let changed = structuralChanged.map { $0 || handlerEvidence }
            let visibleValueChanged: Bool = {
                guard let before,
                      let beforeValues = Self.visionValueTexts(before.detail),
                      let afterValues = Self.visionValueTexts(after.detail) else { return false }
                return beforeValues != afterValues
            }()
            let pointerOnTarget: Bool? = {
                guard let pointerTarget, let before,
                      before.bundleIdentifier == after.bundleIdentifier,
                      before.appName == after.appName,
                      let pointer = after.pointer,
                      case .hit(let target) = Self.resolve(pointerTarget, among: after.targets),
                      let frame = target.observedFrame else { return nil }
                return pointer.isInside(frame) && !target.excludedFrames.contains { pointer.isInside($0) }
            }()
            let observation: String
            if pointerOnTarget == true { observation = " The system pointer is inside the target's freshly observed bounds." }
            else if pointerOnTarget == false { observation = " The system pointer is outside the target's freshly observed bounds." }
            else if visibleValueChanged { observation = " A value the fresh screen says changed after it." }
            else if structuralChanged == true { observation = " The fresh screen changed after it." }
            else if handlerEvidence && allowGenericScreenChangeVerification {
                observation = " The fresh fused view changed after it, although the structural words stayed the same."
            }
            else if changed == false { observation = " The fresh screen did not visibly change." }
            else { observation = " This is the fresh screen afterward." }
            var detail = Self.operationDetail(result)
            let mechanism = Self.object(result.output)
            if let neutral = Self.bool(mechanism["hand_neutral"]) {
                detail["hand_neutral"] = .bool(neutral)
            }
            detail["observed_after"] = .bool(true)
            detail["screen_changed"] = changed.map(JSONValue.bool) ?? .null
            // Physical input starts unverified because emitting HID is not
            // evidence. An immediate fresh fused screen delta is independent
            // evidence that the visible computer reacted, so settle THAT claim
            // (not the caller's larger goal). An unchanged screen remains
            // explicitly unverified.
            if pointerTarget != nil {
                detail["pointer_on_target"] = pointerOnTarget.map(JSONValue.bool) ?? .null
                detail["verification"] = .string(pointerOnTarget == true
                    ? MotorVerificationState.satisfied.rawValue : MotorVerificationState.unverified.rawValue)
                detail.removeValue(forKey: "verification_evidence")
                if pointerOnTarget == true {
                    detail["verification_evidence"] = .string("fresh_system_pointer_in_observed_target")
                    detail["verification_scope"] = .string("pointer_position_only")
                }
            } else if visibleValueChanged {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_visible_value_change")
            } else if changed == true, allowGenericScreenChangeVerification {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_visible_screen_change")
            } else if !allowGenericScreenChangeVerification {
                detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
                detail.removeValue(forKey: "verification_evidence")
            }
            let truthfulDescription = visibleValueChanged
                    || (changed == true && allowGenericScreenChangeVerification)
                ? description
                : (unverifiedDescription ?? description)
            let neutralObservation = mechanism["holding"] != nil
                && mechanism["holding"] != .null
                && Self.bool(mechanism["hand_neutral"]) == true
                ? " The held keys were released and the hand returned neutral."
                : ""
            return MacFourVerbsReply(
                ok: true,
                text: truthfulDescription + observation + neutralObservation + "\n" + after.render,
                detail: detail
            )
        }
    }

    private func unresolvedPhysical(_ target: String, nearest: [String], screen: String) -> MacFourVerbsReply {
        var line = "Nothing on this screen is called \"\(target)\"."
        if !nearest.isEmpty { line += " What I can see: " + nearest.joined(separator: " · ") + "." }
        return MacFourVerbsReply(ok: false, text: line + "\n" + screen, detail: ["error": .string("no_match")])
    }

    private func ambiguousPhysical(_ target: String, candidates: [ActTarget], screen: String) -> MacFourVerbsReply {
        let names = candidates.map(Self.recoveryName).joined(separator: ", ")
        return MacFourVerbsReply(
            ok: false,
            text: "More than one thing matches \"\(target)\": \(names). Which one? I haven't touched anything.\n" + screen,
            detail: ["error": .string("ambiguous")]
        )
    }

    static func keySpec(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["key ", "key:", "chord ", "chord:"] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: 3 — LEGS

    /// Get her THERE. A running app is raised through the existing focus organ,
    /// an installed one is launched, a path or a URL is opened. The reply is
    /// where she landed, as `screen()`.
    public func go(_ name: String) async -> MacFourVerbsReply {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MacFourVerbsReply(ok: false, text: "Where to? Give me an app, a folder, a file or a link.")
        }

        // AppKit cannot raise an app over loginwindow. In User's ordinary setup
        // that is the screensaver layer, and the existing wake organ is the
        // safe, bounded way through it. A four-verb caller should never have to
        // discover a fifth tool or translate `loginwindow` into that action.
        // `sight` nudges only when it actually observes that layer and keeps all
        // wake/injection gates below this surface.
        if case .blind(let readiness) = await sight(part: nil),
           readiness.detail["error"] == .string("display_obstructed") {
            return readiness
        }

        let result: MacControlResult
        let moved: String
        var verificationDestination = trimmed
        var settlesAsynchronously = false
        if let url = Self.webURL(trimmed) {
            do {
                result = try await host.dispatch(action: "open_target", body: ["url": .string(url.absoluteString)])
            } catch {
                return await landingFailure("I couldn't ask the Mac to open that link.")
            }
            moved = "The Mac accepted the request to open \(trimmed)."
            settlesAsynchronously = true
        } else if let path = Self.filePath(trimmed) {
            do {
                result = try await host.dispatch(action: "open_target", body: ["url": .string(path.absoluteString)])
            } catch {
                return await landingFailure("I couldn't ask the Mac to open that path.")
            }
            moved = "The Mac accepted the request to open \(path.path)."
            settlesAsynchronously = true
        } else {
            do {
                // The existing app-control organ both launches and raises, then
                // independently verifies that the requested app is frontmost.
                let appResult = try await host.dispatch(action: "focus_app", body: ["app": .string(trimmed)])
                if appResult.ok {
                    result = appResult
                    moved = "Switched to \(trimmed)."
                } else {
                    switch Self.namedFolder(trimmed, under: namedLocationRoots) {
                    case .unique(let folder):
                        result = try await host.dispatch(
                            action: "open_target",
                            body: ["url": .string(folder.absoluteString)]
                        )
                        moved = "The Mac accepted the request to open \(folder.path)."
                        verificationDestination = folder.path
                        settlesAsynchronously = true
                    case .ambiguous(let parents):
                        let places = parents.joined(separator: " and ")
                        return await landingFailure(
                            "More than one common folder is named \"\(trimmed)\" (in \(places)). Which one? I haven't opened any of them.",
                            detail: ["error": .string("named_location_ambiguous")]
                        )
                    case .none:
                        result = appResult
                        moved = "Switched to \(trimmed)."
                    }
                }
            } catch {
                return await landingFailure("I couldn't switch to \(trimmed).")
            }
        }
        var landing = await sight(part: nil)
        if settlesAsynchronously,
           case .seen(let first) = landing,
           Self.destination(verificationDestination, matches: first) != true {
            await clock.sleep(seconds: 0.5)
            landing = await sight(part: nil)
        }
        switch landing {
        case .blind(let reply):
            return MacFourVerbsReply(
                ok: result.ok,
                text: (result.ok ? moved : "I couldn't confirm that I got to \(trimmed).") + " " + reply.text,
                detail: Self.operationDetail(result).merging(reply.detail) { current, _ in current }
            )
        case .seen(let hit):
            let landed = Self.destination(verificationDestination, matches: hit)
            var detail = Self.operationDetail(result).merging(hit.detail) { current, _ in current }
            detail["observed_destination"] = landed.map(JSONValue.bool) ?? .null
            if landed == true {
                if result.ok == false {
                    detail["mechanism_operation_state"] = detail["operationState"] ?? .null
                    detail["mechanism_verification"] = detail["verification"] ?? .null
                    detail["operationState"] = .string(MacControlOperationState.completed.rawValue)
                    detail["outcome_reconciled"] = .bool(true)
                }
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_screen_destination_match")
                return MacFourVerbsReply(
                    ok: true,
                    text: (result.ok
                        ? moved
                        : "The activation report lagged, but the fresh screen shows I arrived at \(trimmed).")
                        + " Now looking at " + hit.place + ".\n" + hit.render,
                    detail: detail
                )
            }
            if landed == nil, result.ok {
                return MacFourVerbsReply(
                    ok: true,
                    text: moved + " The fresh screen is " + hit.place
                        + ", but it does not expose enough destination identity to prove the exact landing.\n"
                        + hit.render,
                    detail: detail
                )
            }
            return MacFourVerbsReply(
                ok: false,
                text: "I didn't arrive at \(trimmed). The fresh screen is still " + hit.place + ".\n" + hit.render,
                detail: detail
            )
        }
    }

    // MARK: 4 — PATIENCE

    /// Bounded waiting, ended by a SIGNAL rather than by a stopwatch
    /// (fable51 item 31; NORTHSTAR clause 4).
    ///
    /// Same three outcomes and the same words as before — matched, settled,
    /// timeout, and a timeout is never dressed up as a settle. What changed is
    /// what it costs. The old loop re-rendered every 500 ms, and each render is
    /// a full AX walk plus a screen capture plus (conditionally) OCR: a 60 s
    /// wait was up to 120 captures, nearly all of them of a screen that had not
    /// moved. Now:
    ///
    ///   1. ONE render up front — the baseline it compares against.
    ///   2. Then it SUBSCRIBES (`MacWaitSignals`: the same `AXObserver` the act
    ///      loop already ends on, plus NSWorkspace activation for the app-switch
    ///      signal an AX observer installed on one pid structurally cannot
    ///      carry) and renders again only when a signal actually arrives. A
    ///      burst of notifications is ONE episode and ONE render.
    ///   3. SILENCE IS THE SETTLE. When the subscription is live and nothing
    ///      fires for `settleQuietSeconds`, the screen has stopped changing —
    ///      so the render already in hand is the answer, and a settled wait
    ///      costs one capture instead of two.
    ///
    /// THE SAFETY NET, and exactly what it is for: when NO observer could be
    /// installed (the app publishes nothing subscribable, the look could not
    /// name a pid, or the platform has no observer at all), silence proves
    /// nothing — so this must not report a settle it cannot see. In that case
    /// and only that case, `wait` degrades to a coarse re-render every
    /// `fallbackPollSeconds` and decides settle the old way, by comparing two
    /// renders. That is ten times cheaper than the old poll and still honest.
    public func wait(until: String? = nil, seconds: Double? = nil) async -> MacFourVerbsReply {
        let budget = min(max(seconds ?? Self.defaultWaitSeconds, 0), Self.maxWaitSeconds)
        let needle = until?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let startedAt = clock.now()

        func elapsedNow() -> Double { clock.now().timeIntervalSince(startedAt) }

        func matched(_ hit: Sighting, _ elapsed: Double) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: true,
                text: "\"\(until ?? "")\" appeared after \(Self.seconds(elapsed)).\n" + hit.render,
                detail: ["outcome": .string("matched"), "seconds": .double(elapsed)]
            )
        }
        func settled(_ hit: Sighting, _ elapsed: Double, quiet: Bool) -> MacFourVerbsReply {
            MacFourVerbsReply(
                ok: true,
                text: (needle?.isEmpty == false
                       ? "Settled after \(Self.seconds(elapsed)) and \"\(until ?? "")\" never appeared."
                       : "Settled after \(Self.seconds(elapsed)).") + "\n" + hit.render,
                detail: [
                    "outcome": .string("settled"),
                    "seconds": .double(elapsed),
                    // How the settle was DECIDED. `quiet` means the
                    // subscription went silent; `compared` means there was no
                    // subscription and two renders matched.
                    "settled_by": .string(quiet ? "quiet" : "compared"),
                ]
            )
        }

        // 1 — the baseline. One render, before anything is subscribed to.
        let first: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let seen): first = seen
        }
        var last = first
        var previous = first.render
        var lastRenderAt = clock.now()
        if let needle, !needle.isEmpty, first.render.lowercased().contains(needle) {
            return matched(first, elapsedNow())
        }

        // 2 — subscribe. Installed only AFTER a look succeeded, so the gate has
        // already run; removed on every exit, including a thrown cancellation.
        let signals = MacWaitSignals(
            effects: effectObserverSource,
            activation: appActivationSource,
            pid: first.pid
        )
        defer { signals.stop() }

        while true {
            let remaining = budget - elapsedNow()
            if remaining <= 0 { break }
            let window = min(
                remaining,
                signals.isObserving ? Self.settleQuietSeconds : Self.fallbackPollSeconds
            )
            // THE CAPTURE-RATE FLOOR. A screen that fires notifications
            // continuously (a progress bar, a live log) would otherwise wake
            // this loop on every one and render as fast as the machine can walk
            // and capture — a hot loop, strictly worse than the poll it
            // replaced. So a signal never causes a render sooner than
            // `settleQuietSeconds` after the last one: the old poll's cadence
            // becomes the WORST case instead of the only case.
            let fired = await awaitSignal(
                signals,
                window: window,
                notBefore: lastRenderAt.addingTimeInterval(Self.settleQuietSeconds)
            )
            if !fired, signals.isObserving {
                // Nothing fired for a full quiet window: the screen has stopped
                // changing, and the render in hand already describes it.
                if window >= Self.settleQuietSeconds {
                    return settled(last, elapsedNow(), quiet: true)
                }
                // The budget ran out inside a short final window.
                break
            }
            // 3 — render ONCE, because something happened (or, with no
            // subscription, because the coarse fallback said to look again).
            switch await sight(part: nil) {
            case .blind(let reply): return reply
            case .seen(let seen): last = seen
            }
            lastRenderAt = clock.now()
            let elapsed = elapsedNow()
            if let needle, !needle.isEmpty, last.render.lowercased().contains(needle) {
                return matched(last, elapsed)
            }
            if previous == last.render {
                // A signal that changed nothing visible, or the fallback's two
                // identical renders. Either way the screen has settled.
                return settled(last, elapsed, quiet: false)
            }
            previous = last.render
        }

        let elapsed = elapsedNow()
        let ending = needle?.isEmpty == false
            ? "Timed out after \(Self.seconds(elapsed)) — \"\(until ?? "")\" never appeared and the screen is still changing."
            : "Timed out after \(Self.seconds(elapsed)) — the screen is still changing."
        return MacFourVerbsReply(
            ok: false,
            text: ending + "\n" + last.render,
            detail: ["outcome": .string("timeout"), "seconds": .double(elapsed)]
        )
    }

    /// Wait until a signal arrives or `window` elapses. The granularity is a
    /// lock-guarded read of an in-process collector — no AX walk, no capture —
    /// which is what makes it affordable at 50 ms while the old loop was
    /// unaffordable at 500 ms. It is paced through `clock` so a 60-second
    /// budget stays a 60-second budget in production and costs nothing in a
    /// test.
    private func awaitSignal(
        _ signals: MacWaitSignals,
        window: Double,
        notBefore: Date
    ) async -> Bool {
        let deadline = clock.now().addingTimeInterval(window)
        var fired = false
        while clock.now() < deadline {
            if signals.consume() { fired = true }
            // Latched, but held until the capture-rate floor passes. Holding
            // rather than dropping is what keeps a fast signal from being lost:
            // the wake still happens, it just happens on the floor.
            if fired, clock.now() >= notBefore { return true }
            await clock.sleep(seconds: min(Self.signalPollSeconds, window))
        }
        if signals.consume() { fired = true }
        return fired
    }

    static let defaultWaitSeconds: Double = 10
    static let maxWaitSeconds: Double = 60
    /// Silence this long, with a live subscription, IS a settle. The same
    /// half-second the old loop encoded as "two identical renders 500 ms
    /// apart" — the meaning is unchanged, only the evidence got cheaper.
    static let settleQuietSeconds: Double = 0.5
    /// The SAFETY NET cadence, used only when no observer could be installed.
    static let fallbackPollSeconds: Double = 5.0
    /// How often the wait drains the collector. A lock read, not a look.
    static let signalPollSeconds: Double = 0.05

    // MARK: - One sighting

    /// Everything ONE verb call needs from ONE look: the render she reads, the
    /// resolvable targets behind it, and the bookkeeping (frame id, handles)
    /// that stays on this side of the wall. Scratch for the duration of a single
    /// call — never stored, never carried across calls.
    /// A look either happened or it didn't, and a blind verb answers in words
    /// rather than throwing: "I can't see the screen right now" IS the reply.
    enum Sighted {
        case seen(Sighting)
        case blind(MacFourVerbsReply)
    }

    struct Sighting {
        let render: String
        let effectRender: String
        let pointer: MacPointerPosition?
        let place: String
        let appName: String?
        let bundleIdentifier: String?
        /// fable51 item 31 — the process `wait` installs its AX observer on.
        /// nil when the look could not name one, which the wait reports as "no
        /// observer" rather than installing on a guess.
        let pid: Int32?
        /// fable51 item 32a/b — whether the window this sighting DESCRIBES is
        /// the one in front. Always true for an unanchored look; a measured
        /// fact for an anchored one, and the fact the cross-app drag's raise
        /// decision turns on.
        let isFront: Bool
        let visibleFrame: MacAXFrame?
        /// fable51 item 32b (gpt-5.5 review) — the frame of the WINDOW this
        /// sighting describes, as the look's own anchor reported it. nil when
        /// the host published none. Distinct from `visibleFrame`, which is the
        /// screen's usable area, and from the union of `targets` frames, which
        /// is only what was READ inside the window: a window's title bar,
        /// toolbar and blank areas belong to the window and to neither of
        /// those. The cross-app drag's coverage guard turns on this.
        let windowFrame: MacAXFrame?
        let targets: [ActTarget]
        let frameId: String
        let zoomNote: String?
        let detail: [String: JSONValue]
    }

    /// A resolvable thing on the screen. `label` is the DISPLAY text — what the
    /// renderer printed — so anything redaction withheld cannot be named.
    struct ActTarget: Equatable {
        let sourceAXPath: [Int]?
        let handle: String
        let label: String?
        /// Additional exact natural names for this SAME target. These never
        /// create a second address or carry a second handle; they let transient
        /// state such as keyboard focus name the element already in the model.
        let aliases: [String]
        let kind: String
        /// The content-row ordinal the render printed.
        let ordinal: Int?
        /// A stable one-based ordinal within this target's visible kind. This
        /// is how repeated unnamed controls remain addressable as `button 2`
        /// without pretending that one of them is uniquely named.
        let roleOrdinal: Int?
        let enabled: Bool
        let frame: MacAXFrame?
        let observedFrame: MacAXFrame?
        let excludedFrames: [MacAXFrame]
        let viewId: String?
        let mark: Int?
        let regionOnly: Bool
        let physicalOnly: Bool
        let motionUncertain: Bool

        // A semantic look handle remains the preferred semantic route even
        // after fusion enriches it with a physical frame/mark. Only a target
        // that has no look handle is supplemental-only. This keeps the closed
        // loop's destination/read-back verification while giving the same
        // target a physical point for hover, drag, hold, and movement.
        var isSupplemental: Bool { handle.isEmpty }

        init(
            handle: String,
            label: String?,
            aliases: [String] = [],
            kind: String,
            ordinal: Int?,
            roleOrdinal: Int? = nil,
            enabled: Bool,
            frame: MacAXFrame? = nil,
            observedFrame: MacAXFrame? = nil,
            excludedFrames: [MacAXFrame] = [],
            viewId: String? = nil,
            mark: Int? = nil,
            regionOnly: Bool = false,
            physicalOnly: Bool = false,
            motionUncertain: Bool = false,
            sourceAXPath: [Int]? = nil
        ) {
            self.handle = handle
            self.sourceAXPath = sourceAXPath
            self.label = label
            self.aliases = aliases
            self.kind = kind
            self.ordinal = ordinal
            self.roleOrdinal = roleOrdinal
            self.enabled = enabled
            self.frame = frame
            self.observedFrame = observedFrame ?? frame
            self.excludedFrames = excludedFrames
            self.viewId = viewId
            self.mark = mark
            self.regionOnly = regionOnly
            self.physicalOnly = physicalOnly
            self.motionUncertain = motionUncertain
        }
    }

    // Module-internal so paired perception fixtures can inspect the same
    // private target/render compilation used by screen and act.
    func sight(part: String?, app: String? = nil) async -> Sighted {
        await sight(part: part, app: app, wakeAttemptsRemaining: 2)
    }

    /// A screen saver is an obstruction to perception, not a destination Agent
    /// should reason about. Clear it with the already-gated wake organ and then
    /// start the read again. Two attempts cover the observed macOS teardown
    /// delay without creating an unbounded input loop.
    private func sight(part: String?, app: String?, wakeAttemptsRemaining: Int) async -> Sighted {
        let result: MacControlResult
        do {
            // fable51 item 32a — when `app` is named, the look is ANCHORED to
            // that app's front window and nothing is activated. The dispatch
            // body is the only difference; everything downstream reads the same
            // percept shape, and `front` in the output tells the renderer the
            // truth about what it is describing.
            var body: [String: JSONValue] = ["grade": .string("look")]
            if let app { body["app"] = .string(app) }
            result = try await host.dispatch(action: "look", body: body)
        } catch {
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "I can't see the screen right now: \(error).",
                detail: ["error": .string("\(error)")]
            ))
        }
        let output = Self.object(result.output)
        guard result.ok, let frameId = Self.string(output["frame_id"]) else {
            let why = Self.string(output["message"])
                ?? Self.lookRefusalWords(result.error ?? Self.string(output["status"]) ?? "unknown")
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "I can't see the screen right now. " + why,
                // The refusal's own words, unwrapped. A caller with a different
                // lead sentence (the cross-app drag: "I can't drop into Mail")
                // must not have to strip this one's off the front.
                detail: [
                    "error": .string(result.error ?? "look_failed"),
                    "message": .string(why),
                ]
            ))
        }

        let percept = Self.percept(from: output)
        if percept.app?.bundleIdentifier == MacWakeGuard.loginWindowBundleID {
            guard wakeAttemptsRemaining > 0 else {
                return .blind(MacFourVerbsReply(
                    ok: false,
                    text: "The screensaver is still covering the desktop after I nudged it, so I can't see or use the apps underneath yet.",
                    detail: ["error": .string("display_obstructed")]
                ))
            }

            let wake: MacControlResult
            do {
                wake = try await host.dispatch(action: "wake", body: ["settle_ms": .int(1_000)])
            } catch {
                return .blind(MacFourVerbsReply(
                    ok: false,
                    text: "The screensaver is covering the desktop, and I couldn't send the safe wake nudge: \(error).",
                    detail: ["error": .string("display_obstructed")]
                ))
            }

            let wakeOutput = Self.object(wake.output)
            let wakeReceipt = Self.object(wakeOutput["wake"] ?? .null)
            if wake.ok || wakeReceipt["still_obstructed"] == .bool(true) {
                return await sight(part: part, app: app, wakeAttemptsRemaining: wakeAttemptsRemaining - 1)
            }
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "The screensaver is covering the desktop, and the safe wake nudge was refused before anything moved.",
                detail: Self.operationDetail(wake).merging([
                    "error": .string("display_obstructed")
                ]) { current, _ in current }
            ))
        }

        // An UNANCHORED look is frontmost-anchored by construction, so FRONT is
        // a fact there rather than a guess; how many OTHER windows exist is not
        // something this read can tell, and an unknown is omitted, never zeroed
        // into a claim.
        //
        // fable51 item 32a — an ANCHORED look is a different case: the window
        // it describes is usually BEHIND whatever User is using, and printing
        // "in front" over it would be the render lying about the one fact that
        // decides whether she may act on it. The handler publishes `front`;
        // this reads it, and only falls back to `true` when the field is absent
        // (an older host, where every look really was frontmost).
        let isFront = Self.bool(output["front"]) ?? true
        var full = MacScreenRender.screen(from: percept, isFront: isFront)
        let (rows, controls) = Self.partition(percept)
        var targets: [ActTarget] = []
        var rowRoleOrdinals: [String: Int] = [:]
        // Render limits keep the model's reply bounded; they must never become
        // an input limit. A control or row revealed by a prior zoom remains a
        // valid natural target even when the next full-screen render elides it.
        for (index, row) in rows.enumerated() {
            let kind = MacScreenRender.kindName(role: row.role)
            let roleOrdinal = (rowRoleOrdinals[kind] ?? 0) + 1
            rowRoleOrdinals[kind] = roleOrdinal
            targets.append(ActTarget(
                handle: row.handle,
                label: MacScreenText(row.label, redacted: row.labelJSON).display,
                kind: kind,
                ordinal: index + 1,
                roleOrdinal: roleOrdinal,
                enabled: row.enabled,
                frame: row.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: row.path
            ))
        }
        let controlOrdinals = MacScreenRender.controlRoleOrdinals(for: controls)
        for control in controls {
            let kind = MacScreenRender.kindName(role: control.role)
            let display = MacScreenText(control.label, redacted: control.labelJSON).display
            let roleOrdinal = controlOrdinals[control.handle]
            targets.append(ActTarget(
                handle: control.handle,
                label: display,
                kind: kind,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: control.enabled,
                frame: control.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: control.path
            ))
        }

        // Structural regions are addresses too. They are not click targets—
        // clicking the centre of a sidebar would select an arbitrary row—but
        // they are safe, useful destinations for scroll, move and hover. This
        // closes the gap where SCREEN said WHERE=sidebar and ACT could not name
        // that same visible region.
        var landmarkRoleOrdinals: [String: Int] = [:]
        for landmark in percept.landmarks {
            guard let frame = landmark.frame, frame.w > 0, frame.h > 0 else { continue }
            let label = MacScreenText(
                landmark.label ?? landmark.kind,
                redacted: landmark.labelJSON ?? .string(landmark.kind)
            ).display
            let roleOrdinal = (landmarkRoleOrdinals[landmark.kind] ?? 0) + 1
            landmarkRoleOrdinals[landmark.kind] = roleOrdinal
            targets.append(ActTarget(
                handle: "",
                label: label,
                kind: landmark.kind,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: true,
                frame: frame,
                regionOnly: true,
                sourceAXPath: landmark.path
            ))
        }

        var visibleFrame: MacAXFrame?
        var pointer: MacPointerPosition?
        var pointerFrame: MacAXFrame?
        var supplementalDiagnostics: [String: JSONValue] = [:]
        if let supplement = await supplementalSource?.observe(),
           Self.sameApp(percept: percept, supplement: supplement) {
            visibleFrame = supplement.visibleFrame
            pointer = supplement.pointer
            pointerFrame = supplement.pointerFrame ?? supplement.visibleFrame
            supplementalDiagnostics = supplement.diagnostics
            var addedTargets: [ActTarget] = []
            var mergedAXPaths: Set<[Int]> = []
            var addedAXOrdinals: [[Int]: Int] = [:]
            for candidate in supplement.targets {
                let display = candidate.label?.display
                let combined = targets + addedTargets
                let duplicateIndex = Self.supplementalDuplicateIndex(candidate, among: combined)
                if let duplicateIndex {
                    if let path = candidate.sourceAXPath { mergedAXPaths.insert(path) }
                    // The semantic `look` lane intentionally keeps coordinates
                    // private, while the fused view carries the same element's
                    // frame and mark. Do not discard that richer address merely
                    // because the label already exists: that was why Chrome's
                    // visible link could be named but not hovered. Enrich the
                    // semantic target in place so every visible mark has both
                    // its stable AX handle and a safe physical point.
                    let existing = combined[duplicateIndex]
                    let mergedLabel = existing.label ?? display
                    let mergedFrame = existing.frame ?? candidate.frame
                    // A containing row and its filename are one named item,
                    // but their marks still address DIFFERENT AX elements.
                    // Keep the semantic leaf handle; never donate the row mark.
                    let sameAXElement = existing.sourceAXPath == nil || candidate.sourceAXPath == nil
                        || existing.sourceAXPath == candidate.sourceAXPath
                    let mergedViewId = existing.viewId ?? (sameAXElement ? candidate.viewId : nil)
                    let mergedMark = existing.mark ?? (sameAXElement ? candidate.mark : nil)
                    let enriched = ActTarget(
                        handle: existing.handle,
                        label: mergedLabel,
                        aliases: (existing.aliases + candidate.aliases).reduce(into: []) {
                            if !$0.contains($1) { $0.append($1) }
                        },
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: mergedFrame,
                        observedFrame: existing.observedFrame ?? candidate.observedFrame,
                        excludedFrames: existing.excludedFrames + candidate.excludedFrames,
                        viewId: mergedViewId,
                        mark: mergedMark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly || candidate.physicalOnly,
                        motionUncertain: candidate.motionUncertain,
                        sourceAXPath: existing.sourceAXPath ?? candidate.sourceAXPath
                    )
                    if duplicateIndex < targets.count {
                        targets[duplicateIndex] = enriched
                    } else {
                        addedTargets[duplicateIndex - targets.count] = enriched
                    }
                    continue
                }
                let roleOrdinal = candidate.ordinal ?? Self.nextRoleOrdinal(
                    for: candidate.kind, among: targets + addedTargets
                )
                if let path = candidate.sourceAXPath { addedAXOrdinals[path] = roleOrdinal }
                addedTargets.append(ActTarget(
                    handle: "",
                    label: display,
                    aliases: candidate.aliases,
                    kind: candidate.kind,
                    ordinal: rows.isEmpty ? candidate.ordinal : nil,
                    roleOrdinal: roleOrdinal,
                    enabled: candidate.enabled,
                    frame: candidate.frame,
                    observedFrame: candidate.observedFrame,
                    excludedFrames: candidate.excludedFrames,
                    viewId: candidate.viewId,
                    mark: candidate.mark,
                    regionOnly: candidate.regionOnly,
                    physicalOnly: candidate.physicalOnly,
                    motionUncertain: candidate.motionUncertain,
                    sourceAXPath: candidate.sourceAXPath
                ))
            }
            targets.append(contentsOf: addedTargets)
            let supplementalControls = supplement.controls.compactMap { control -> MacScreenRender.Control? in
                guard let path = control.sourceAXPath else { return control }
                guard !mergedAXPaths.contains(path) else { return nil }
                return MacScreenRender.Control(
                    label: control.label, kind: control.kind,
                    ordinal: addedAXOrdinals[path] ?? control.ordinal,
                    value: control.value, states: control.states, provenance: control.provenance,
                    abstain: control.abstain, sourceAXPath: path
                )
            }
            let supplementalContents = supplement.contents.map { content in
                MacScreenRender.Content(
                    kind: content.kind, noun: content.noun,
                    rows: content.rows.filter { row in
                        row.sourceAXPath.map { !mergedAXPaths.contains($0) } ?? true
                    },
                    totalRows: content.totalRows, scrollable: content.scrollable, canvas: content.canvas
                )
            }
            full = Self.adding(
                contents: supplementalContents,
                controls: supplementalControls,
                values: supplement.values,
                to: full
            )
        }

        // A focused empty text area has no title or value, so it is not an AX
        // affordance — but the look frame deliberately minted a safe handle for
        // it. Make that existing address visible as a role ordinal. This is the
        // Notes case Agent found, expressed by shape rather than app name.
        if let focus = percept.focus, let handle = focus.handle {
            let kind = MacScreenRender.kindName(role: focus.role)
            let label = focus.displayLabel ?? "focused \(kind)"
            if let index = targets.firstIndex(where: { $0.handle == handle }) {
                // A text area can already be an interactive affordance despite
                // having no label. Focus gives that same safe handle a natural
                // name; otherwise the duplicate target would leave it visible
                // yet impossible to address by the focused label.
                let existing = targets[index]
                if existing.label == nil {
                    targets[index] = ActTarget(
                        handle: existing.handle,
                        label: label,
                        aliases: Self.editableKinds.contains(kind)
                            ? Self.focusedEditableAliases(kind: kind)
                            : [],
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: existing.frame,
                        observedFrame: existing.observedFrame,
                        excludedFrames: existing.excludedFrames,
                        viewId: existing.viewId,
                        mark: existing.mark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly,
                        motionUncertain: existing.motionUncertain,
                        sourceAXPath: existing.sourceAXPath
                    )
                    full = Self.adding(
                        controls: [MacScreenRender.Control(
                            label: MacScreenText(label, redacted: .string(label)),
                            kind: kind,
                            states: ["focused", "unnamed"],
                            provenance: .ax
                        )],
                        to: full
                    )
                } else if Self.editableKinds.contains(kind) {
                    targets[index] = ActTarget(
                        handle: existing.handle,
                        label: existing.label,
                        aliases: Self.focusedEditableAliases(kind: kind),
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: existing.frame,
                        observedFrame: existing.observedFrame,
                        excludedFrames: existing.excludedFrames,
                        viewId: existing.viewId,
                        mark: existing.mark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly,
                        motionUncertain: existing.motionUncertain,
                        sourceAXPath: existing.sourceAXPath
                    )
                }
            } else {
                targets.append(ActTarget(
                    handle: handle,
                    label: label,
                    aliases: Self.editableKinds.contains(kind)
                        ? Self.focusedEditableAliases(kind: kind)
                        : [],
                    kind: kind,
                    ordinal: nil,
                    roleOrdinal: Self.nextRoleOrdinal(for: kind, among: targets),
                    enabled: true,
                    frame: nil,
                    viewId: nil,
                    mark: nil,
                    sourceAXPath: focus.path
                ))
                full = Self.adding(
                    controls: [MacScreenRender.Control(
                        label: MacScreenText(label, redacted: .string(label)),
                        kind: kind,
                        states: ["focused", "unnamed"],
                        provenance: .ax
                    )],
                    to: full
                )
            }
        }

        let zoom = part.flatMap { Self.zoom(full, part: $0, options: options) }
        let rendering = MacScreenRender.rendering(zoom?.screen ?? full, options: zoom?.options ?? options)
        let pointerLine: String = {
            guard let pointer else { return "POINTER: position unavailable." }
            guard let frame = pointerFrame else { return "POINTER: observed; surface position unavailable." }
            guard pointer.isInside(frame) else { return "POINTER: outside the observed surface." }
            let x = Int(((pointer.x - frame.x) / frame.w * 100).rounded())
            let y = Int(((pointer.y - frame.y) / frame.h * 100).rounded())
            return "POINTER: \(x)%,\(y)% of the observed surface (system position)."
        }()
        let renderedText = rendering.text + "\n" + pointerLine
        return .seen(Sighting(
            render: renderedText,
            effectRender: rendering.text,
            pointer: pointer,
            place: Self.place(percept),
            appName: percept.app?.name,
            bundleIdentifier: percept.app?.bundleIdentifier,
            pid: percept.app.map(\.processIdentifier).flatMap { $0 == 0 ? nil : $0 },
            isFront: isFront,
            visibleFrame: visibleFrame,
            windowFrame: Self.frame(output["window_frame"]),
            targets: targets,
            frameId: frameId,
            zoomNote: zoom?.note,
            detail: [
                "bytes": .int(Int64(renderedText.utf8.count)),
                "rows_dropped": .int(Int64(rendering.rowsDropped)),
                "controls_dropped": .int(Int64(rendering.controlsDropped)),
                "semantic_targets_omitted": .int(Int64(percept.affordancesOmitted)),
            ].merging(supplementalDiagnostics) { current, _ in current }
        ))
    }

    // MARK: - Zoom

    struct Zoom {
        let screen: MacScreenRender.Screen
        let options: MacScreenRender.Options
        let note: String
    }

    /// Scoping, WITHOUT renumbering. Controls carry no ordinals, so a control
    /// zoom filters them; content rows carry the addresses she acts with, so a
    /// content zoom raises the cap and names the matching ordinals instead of
    /// dropping their neighbours.
    static func zoom(
        _ screen: MacScreenRender.Screen,
        part: String,
        options: MacScreenRender.Options
    ) -> Zoom? {
        let needle = normalize(part)
        guard !needle.isEmpty else { return nil }

        // A visual world is a first-class screen section, not browser chrome.
        // Without this branch, "the open X canvas" can fuzzy-match the tab
        // named X and hide the pixel regions the agent actually asked to see,
        // forcing another full-screen/provider round before acting.
        let words = Set(needle.split(separator: " ").map(String.init))
        let asksForVisualSurface = words.contains("canvas")
            || words.contains("world")
            || words.contains("viewport")
            || needle.contains("visual surface")
        if asksForVisualSurface,
           screen.contents.contains(where: { $0.kind == .canvas }) {
            let visualContents = screen.contents.filter { content in
                content.kind == .canvas || content.rows.contains { $0.provenance.isVision }
            }
            let visualControls = screen.controls.filter { $0.provenance.isVision }
            let visualRows = visualContents.reduce(0) { $0 + $1.rows.count }
            let scoped = MacScreenRender.Screen(
                appName: screen.appName,
                windowTitle: screen.windowTitle,
                isFront: screen.isFront,
                otherWindows: screen.otherWindows,
                provenance: screen.provenance,
                modal: screen.modal,
                whereSteps: screen.whereSteps,
                contents: visualContents,
                controls: visualControls,
                totalControls: visualControls.count,
                unlabeledControls: [:],
                values: screen.values,
                totalValues: screen.totalValues,
                unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
            )
            return Zoom(
                screen: scoped,
                options: MacScreenRender.Options(
                    maxRows: max(options.maxRows, Self.zoomMaxRows),
                    maxControls: options.maxControls,
                    maxValues: options.maxValues,
                    maxWhereSteps: options.maxWhereSteps,
                    // Visual object details carry compact colour, normalized
                    // geometry, and motion. The ordinary 40-character UI
                    // label cap cuts those facts at "at …"; this scoped world
                    // has few rows and can afford the bounded wider field.
                    maxLabelChars: max(options.maxLabelChars, 96)
                ),
                note: "Visual surface retained with \(visualRows + visualControls.count) interpreted region"
                    + (visualRows + visualControls.count == 1 ? "" : "s")
                    + "; surrounding controls omitted."
            )
        }

        let asksForControls = ["controls", "actions", "actionable controls"].contains(needle)
        let matchingControls = asksForControls ? screen.controls
            : screen.controls.filter { matches(needle, $0.label.display, kind: $0.kind) }
        let matchingRows = screen.contents.flatMap { content in
            content.rows.enumerated().filter { matches(needle, $0.element.label?.display, kind: nil) }
                .map { $0.offset + 1 }
        }

        let asksForReadouts = ["hud", "the hud", "values", "readouts", "status text"].contains(needle)
        let matchingValues = asksForReadouts ? screen.values : screen.values.filter {
            matches(needle, $0.text.display, kind: nil)
        }
        if asksForReadouts || (!matchingValues.isEmpty && matchingControls.isEmpty && matchingRows.isEmpty) {
            let scoped = MacScreenRender.Screen(
                appName: screen.appName, windowTitle: screen.windowTitle, isFront: screen.isFront,
                otherWindows: screen.otherWindows, provenance: screen.provenance,
                modal: screen.modal, whereSteps: screen.whereSteps,
                values: matchingValues, totalValues: asksForReadouts ? screen.totalValues : matchingValues.count,
                unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
            )
            return Zoom(screen: scoped, options: MacScreenRender.Options(
                maxRows: options.maxRows, maxControls: options.maxControls,
                maxValues: max(options.maxValues, Self.zoomMaxRows), maxWhereSteps: options.maxWhereSteps,
                maxLabelChars: options.maxLabelChars
            ), note: "\(matchingValues.count) observed readout\(matchingValues.count == 1 ? "" : "s") match; surrounding controls omitted.")
        }

        if asksForControls || (!matchingControls.isEmpty && matchingRows.isEmpty) {
            let scoped = MacScreenRender.Screen(
                appName: screen.appName,
                windowTitle: screen.windowTitle,
                isFront: screen.isFront,
                otherWindows: screen.otherWindows,
                provenance: screen.provenance,
                modal: screen.modal,
                whereSteps: screen.whereSteps,
                contents: [],
                controls: matchingControls,
                totalControls: asksForControls ? screen.totalControls : matchingControls.count,
                unlabeledControls: asksForControls ? screen.unlabeledControls : [:],
                values: screen.values,
                totalValues: screen.totalValues,
                unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
            )
            return Zoom(
                screen: scoped,
                options: MacScreenRender.Options(
                    maxRows: options.maxRows,
                    maxControls: max(options.maxControls, Self.zoomMaxRows),
                    maxValues: options.maxValues,
                    maxWhereSteps: options.maxWhereSteps,
                    maxLabelChars: options.maxLabelChars
                ),
                note: "\(matchingControls.count) of \(screen.totalControls) actionable match; "
                    + "the rest of the screen is unchanged."
            )
        }

        // Content zoom: the whole section, cap raised, ordinals intact.
        let wide = MacScreenRender.Options(
            maxRows: max(options.maxRows, Self.zoomMaxRows),
            maxControls: options.maxControls,
            maxValues: options.maxValues,
            maxWhereSteps: options.maxWhereSteps,
            maxLabelChars: options.maxLabelChars
        )
        if matchingRows.isEmpty {
            return Zoom(
                screen: screen,
                options: wide,
                note: "Nothing here is named \"\(part)\" — this is the whole screen."
            )
        }
        return Zoom(
            screen: screen,
            options: wide,
            note: "Matching row\(matchingRows.count == 1 ? "" : "s"): "
                + matchingRows.map(String.init).joined(separator: ", ") + "."
        )
    }

    static let zoomMaxRows = 60

    // MARK: - Resolution
    //
    // The ladder, and it NEVER falls back to "just click the first match":
    //
    //   1. exact label, case/whitespace-insensitive
    //   2. unique contains-match, either direction
    //   3. ordinal address — "row 3", "button 2", "text area 1", "3" — the
    //      content or role ordinals the render printed
    //   4. a ROLE HINT in the phrase ("the Send button") narrows a multi-match
    //      at every rung, never widens one
    //
    // Unique, or ask.

    enum Resolution {
        case hit(ActTarget)
        case ambiguous([ActTarget])
        case none(nearest: [String])
    }

    static func resolve(_ target: String, among targets: [ActTarget]) -> Resolution {
        let hint = roleHint(in: target)
        let identityTarget = stripWithinTargetAimQualifier(target)
        let qualifier = trailingRoleQualifier(in: identityTarget)
        let needle = qualifier?.label ?? normalize(stripRoleWords(identityTarget))
        guard !needle.isEmpty || hint != nil else { return .none(nearest: nearest(to: "", among: targets)) }

        func narrow(_ matches: [ActTarget], respectingQualifier: Bool = true) -> Resolution? {
            let candidates = respectingQualifier && qualifier != nil
                ? matches.filter { $0.kind == qualifier?.kind }
                : matches
            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return .hit(candidates[0]) }
            if let hint {
                let byRole = candidates.filter { $0.kind == hint }
                if byRole.count == 1 { return .hit(byRole[0]) }
                if byRole.count > 1 { return .ambiguous(byRole) }
            }
            return .ambiguous(candidates)
        }

        // A region's rendered kind is itself a valid name ("web area",
        // "sidebar", "list"). It need not repeat that kind as its label.
        if let hint, normalize(target) == hint,
           let hit = narrow(targets.filter { $0.kind == hint }) {
            return hit
        }

        // Focus is a temporary but exact semantic address. Keep its aliases on
        // the existing target so "focused field" and "focused control" reach
        // the one element the screen says is focused without minting a second
        // handle or letting fuzzy matching choose another control.
        let normalizedTarget = normalize(identityTarget)
        if let hit = narrow(targets.filter { candidate in
            candidate.aliases.contains { normalize($0) == normalizedTarget }
        }, respectingQualifier: false) {
            return hit
        }

        // A literal label can contain role words without describing its role
        // (a row named "Send button", for example). Preserve that exact
        // address before interpreting a trailing kind as a qualifier.
        if let hit = narrow(targets.filter {
            normalize($0.label ?? "") == normalizedTarget && !normalizedTarget.isEmpty
        }, respectingQualifier: false) { return hit }

        // A copied DO/recovery address includes both its ordinal and label,
        // e.g. `button 4 Remove`. Resolve that complete address before fuzzy
        // name matching can discard the number. The label must still agree:
        // a changed screen must not silently redirect a stale address.
        if let address = labeledOrdinalAddress(in: identityTarget) {
            let matches = targets.filter { candidate in
                let ordinalMatches = address.kind == "row"
                    ? candidate.ordinal == address.ordinal
                    : candidate.kind == address.kind && candidate.roleOrdinal == address.ordinal
                return ordinalMatches && candidate.label.map(normalize) == address.label
            }
            return narrow(matches, respectingQualifier: false)
                ?? .none(nearest: nearest(to: address.label, among: targets))
        }

        // 1. exact
        if let hit = narrow(targets.filter { normalize($0.label ?? "") == needle && !needle.isEmpty }) {
            return hit
        }
        // 2. contains
        let contains = targets.filter { candidate in
            guard !needle.isEmpty else { return false }
            let labelMatches: Bool = {
                guard let label = candidate.label else { return false }
                let normalized = normalize(label)
                return !normalized.isEmpty
                    && (normalized.contains(needle) || needle.contains(normalized))
            }()
            let aliasMatches = candidate.aliases.contains { alias in
                let normalized = normalize(alias)
                // An alias may refine a short request ("yellow" -> "yellow
                // object"), but a longer request may not silently discard
                // qualifiers such as moving, above, or left-of.
                return !normalized.isEmpty && normalized.contains(needle)
            }
            return labelMatches || aliasMatches
        }
        if let hit = narrow(contains) { return hit }
        // 3. ordinal. A bare ordinal and `row N` mean the visible content-row
        // number. Every other role uses its own visible ordinal, so repeated
        // unlabeled buttons, tabs, text areas, and landmarks have an honest
        // natural address.
        if let ordinal = ordinalAddress(in: target) {
            if hint == "row",
               let hit = narrow(targets.filter { $0.ordinal == ordinal }) {
                return hit
            }
            if let hint,
               let hit = narrow(targets.filter {
                   $0.kind == hint && $0.roleOrdinal == ordinal
               }) {
                return hit
            }
            if hint == nil,
               let hit = narrow(targets.filter { $0.ordinal == ordinal }) {
                return hit
            }
        }
        return .none(nearest: nearest(to: needle, among: targets))
    }

    static func isPotentialDynamicVisualReference(_ target: String) -> Bool {
        let words = normalize(target).split(separator: " ")
        let exactRegion = words.count == 3
            && words[0] == "visual"
            && words[1] == "region"
            && Int(words[2]) != nil
        let compactObjectPhrase = (2...7).contains(words.count)
            && (words.contains("object") || words.contains("square") || words.contains("circle"))
        return exactRegion || compactObjectPhrase
    }

    private static func motionAppChangedReply(screen: String) -> MacFourVerbsReply {
        MacFourVerbsReply(ok: false,
            text: "The foreground app changed while I was observing motion. I haven't sent input.\n" + screen,
            detail: ["error": .string("motion_sampling_app_changed")])
    }

    /// This identity probe only earns one more observation. It NEVER supplies
    /// an action target: the original motion-qualified name must still resolve.
    static func canConfirmTemporalTurn(_ target: String, previous: [ActTarget], current: [ActTarget]) -> Bool {
        guard hasTemporalQualifier(target) else { return false }
        let appearance = normalize(target).split(separator: " ")
            .filter { $0 != "moving" && $0 != "stationary" }.joined(separator: " ")
        func identity(_ targets: [ActTarget]) -> String? {
            guard case .hit(let candidate) = resolve(appearance, among: targets),
                  candidate.physicalOnly, candidate.motionUncertain, candidate.enabled,
                  candidate.observedFrame != nil, let label = candidate.label, !label.isEmpty else { return nil }
            return candidate.handle + "|" + label
        }
        guard let previousID = identity(previous), let currentID = identity(current) else { return false }
        return previousID == currentID
    }

    static func hasTemporalQualifier(_ target: String) -> Bool {
        let words = normalize(target).split(separator: " ")
        return words.contains("moving") || words.contains("stationary")
    }

    static let editableKinds: Set<String> = ["text", "text area", "secure text"]

    static func focusedEditableAliases(kind: String) -> [String] {
        var aliases = ["focused control", "focused field", "focused text", "focused editable control"]
        aliases.append("focused \(kind)")
        return Array(Set(aliases)).sorted()
    }

    /// Scroll names commonly combine a page title with the region kind. Kind
    /// is the decisive part: a browser can expose the same title on a radio,
    /// window, and web area, but only the web area is a scroll destination.
    static func resolveScrollTarget(_ target: String, among targets: [ActTarget]) -> Resolution {
        let phrase = normalize(target)
        for kind in physicalScrollKinds.sorted(by: { $0.count > $1.count })
        where phrase.contains(normalize(kind)) {
            let matches = targets.filter { $0.kind == kind }
            if matches.count == 1, let match = matches.first { return .hit(match) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return resolve(target, among: targets)
    }

    /// What she DID see, so a miss is a fact she can act on rather than a dead
    /// end. Labels only — an unnamed control is not a suggestion.
    static func nearest(to needle: String, among targets: [ActTarget], limit: Int = 8) -> [String] {
        let named = targets.compactMap { candidate -> (String, Int)? in
            guard let label = candidate.label, !label.isEmpty else { return nil }
            let normalized = normalize(label)
            var score = 0
            if !needle.isEmpty {
                let shared = Set(needle.split(separator: " ")).intersection(normalized.split(separator: " "))
                score = shared.count * 10
                if let first = needle.first, normalized.hasPrefix(String(first)) { score += 1 }
            }
            return (recoveryName(candidate), score)
        }
        let ranked = named.enumerated()
            .sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            .map(\.element.0)
        var seen: Set<String> = []
        return ranked.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    static func matches(_ needle: String, _ label: String?, kind: String?) -> Bool {
        if let kind, normalize(kind) == needle { return true }
        guard let label else { return false }
        let normalized = normalize(label)
        guard !normalized.isEmpty, !needle.isEmpty else { return false }
        return normalized.contains(needle) || needle.contains(normalized)
    }

    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'"))
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        for article in ["the ", "a ", "an "] where value.hasPrefix(article) {
            value = String(value.dropFirst(article.count))
        }
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The kind words the renderer's own vocabulary publishes, so a hint can
    /// never name a role the render does not print.
    static let roleWords: [String: String] = {
        var out: [String: String] = [:]
        for name in Set(MacScreenRender.kindNames.values) { out[name] = name }
        // Regions use the same target model as controls. Their vocabulary is
        // published by the perception compiler, so a bare `sidebar` can
        // resolve only when exactly one such visible landmark exists.
        for name in Set(MacPerceptionCompiler.landmarkKinds.values) { out[name] = name }
        // Two synonyms a person actually says, mapped onto the same vocabulary.
        out["field"] = "text"
        out["textfield"] = "text"
        return out
    }()

    private static let trailingRolePhrases = roleWords.keys.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    /// Only a trailing role phrase qualifies the remaining fuzzy/exact-name
    /// rungs. Embedded words in a literal name are not role restrictions.
    static func trailingRoleQualifier(in phrase: String) -> (label: String, kind: String)? {
        let normalized = normalize(phrase)
        for role in trailingRolePhrases where normalized.hasSuffix(" " + role) {
            guard let kind = roleWords[role] else { continue }
            return (normalize(String(normalized.dropLast(role.count))), kind)
        }
        return nil
    }

    static func roleHint(in phrase: String) -> String? {
        let words = normalize(phrase).split(separator: " ").map(String.init)
        // Longest match first, so "menu item" beats "menu".
        if words.count >= 2 {
            for index in 0..<(words.count - 1) {
                if let hit = roleWords[words[index] + " " + words[index + 1]] { return hit }
            }
        }
        for word in words.reversed() {
            if let hit = roleWords[word] { return hit }
        }
        return nil
    }

    /// The phrase with its trailing role word removed — "the send button" is a
    /// request for something NAMED "send", not for something named "send button".
    static func stripRoleWords(_ phrase: String) -> String {
        var words = normalize(phrase).split(separator: " ").map(String.init)
        while let last = words.last, roleWords[last] != nil, words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// These prefixes specify an aim point *within* an already named object;
    /// unlike motion, coarse position, and relations, they are not part of its
    /// identity. Strip them for resolution while preserving the original
    /// phrase for `aimPoint`.
    static func stripWithinTargetAimQualifier(_ phrase: String) -> String {
        withinTargetAimQualifier(phrase)?.target ?? normalize(phrase)
    }

    /// Interpret only a bounded spatial prefix. Hyphens in the object's own
    /// name (for example "upper-left-icon") remain part of its identity.
    private static func withinTargetAimQualifier(_ phrase: String) -> (target: String, words: Set<String>)? {
        let normalized = normalize(phrase)
        guard let separator = normalized.range(of: " of ") else { return nil }
        let qualifier = String(normalized[..<separator.lowerBound])
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let singles: Set<String> = ["left side", "right side", "top", "upper part",
                                    "bottom", "lower part", "center", "centre", "middle"]
        let diagonal = qualifier.count >= 2 && qualifier.count <= 3
            && ["top", "upper", "bottom", "lower"].contains(qualifier[0])
            && ["left", "right"].contains(qualifier[1])
            && (qualifier.count == 2 || ["corner", "part", "side"].contains(qualifier[2]))
        guard diagonal || singles.contains(qualifier.joined(separator: " ")) else { return nil }
        let target = normalize(String(normalized[separator.upperBound...]))
        guard !target.isEmpty else { return nil }
        return (target, Set(qualifier))
    }

    private static func aimWords(in phrase: String) -> Set<String> {
        withinTargetAimQualifier(phrase)?.words
            ?? Set(normalize(phrase).split(separator: " ").map(String.init))
    }

    static let ordinalNouns: Set<String> = ["row", "item", "cell", "line", "no", "number", "#"]

    static func labeledOrdinalAddress(in phrase: String) -> (kind: String, ordinal: Int, label: String)? {
        let normalized = normalize(phrase)
        for role in trailingRolePhrases where normalized.hasPrefix(role + " ") {
            let remainder = normalized.dropFirst(role.count + 1)
            let parts = remainder.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let ordinal = Int(parts[0]),
                  let kind = roleWords[role] else { continue }
            let label = normalize(String(parts[1]))
            guard !label.isEmpty else { continue }
            return (kind, ordinal, label)
        }
        return nil
    }

    static func ordinalAddress(in phrase: String) -> Int? {
        let words = normalize(phrase)
            .replacingOccurrences(of: "#", with: "# ")
            .split(separator: " ").map(String.init)
        if words.count == 1, let only = Int(words[0]) { return only }
        if words.count > 1,
           let last = words.last,
           let value = Int(last),
           roleHint(in: words.dropLast().joined(separator: " ")) != nil {
            return value
        }
        for (index, word) in words.enumerated() where ordinalNouns.contains(word) {
            if index + 1 < words.count, let value = Int(words[index + 1]) { return value }
        }
        return nil
    }

    static func nextRoleOrdinal(for kind: String, among targets: [ActTarget]) -> Int {
        (targets.compactMap { target in
            target.kind == kind ? target.roleOrdinal : nil
        }.max() ?? 0) + 1
    }

    // MARK: - Words

    enum ScrollDirection: String {
        case up, down, left, right
        var isHorizontal: Bool { self == .left || self == .right }
    }

    static func parseVerb(_ raw: String) -> (String, ScrollDirection) {
        let words = normalize(raw).split(separator: " ").map(String.init)
        let head = words.first ?? ""
        let direction: ScrollDirection = words.contains("up") ? .up
            : words.contains("left") ? .left : words.contains("right") ? .right : .down
        return (head, direction)
    }

    static func pastTense(_ verb: MacActVerb, direction: ScrollDirection) -> String {
        switch verb {
        case .click: return "Clicked"
        case .open: return "Opened"
        case .type: return "Typed into"
        case .select: return "Selected"
        case .toggle: return "Toggled"
        case .dismiss: return "Dismissed"
        case .scroll: return "Scrolled \(direction.rawValue) in"
        }
    }

    static func attempted(_ verb: MacActVerb, direction: ScrollDirection) -> String {
        switch verb {
        case .scroll: return "Tried to scroll \(direction.rawValue) in"
        default: return "Tried to \(verb.rawValue)"
        }
    }

    static func name(_ candidate: ActTarget) -> String {
        if let label = candidate.label, !label.isEmpty { return "\"\(label)\"" }
        if let ordinal = candidate.ordinal { return "row \(ordinal)" }
        return "that \(candidate.kind)"
    }

    static func recoveryName(_ candidate: ActTarget) -> String {
        let address = candidate.ordinal.map { "row \($0)" }
            ?? candidate.roleOrdinal.map { "\(candidate.kind) \($0)" }
        guard let address else { return name(candidate) }
        if let label = candidate.label, !label.isEmpty { return "\(address) \"\(label)\"" }
        return address
    }

    static func spokenName(_ candidate: ActTarget, requestedAs target: String) -> String {
        let requested = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = normalize(stripWithinTargetAimQualifier(requested))
        if !requested.isEmpty,
           candidate.aliases.contains(where: { normalize($0) == identity }) {
            return "\"\(requested)\""
        }
        return name(candidate)
    }

    /// Natural spatial qualifiers turn one visible region into useful aim
    /// points without exposing coordinates. Quarter-points leave a margin so
    /// "right side" does not accidentally target a resize edge.
    static func safeAimPoint(for target: ActTarget, in frame: MacAXFrame,
                            describedBy phrase: String) -> MacPointerPosition? {
        let aim = aimPoint(in: frame, describedBy: phrase)
        guard let preferred = MacPointerPosition(x: aim.x, y: aim.y) else { return nil }
        let words = aimWords(in: phrase)
        let spatialWords: Set<String> = ["left", "right", "top", "upper", "bottom", "lower", "center", "centre", "middle"]
        return MacRegionAim.point(in: frame, preferred: preferred, excluding: target.excludedFrames,
                                  allowAlternate: target.regionOnly && words.isDisjoint(with: spatialWords))
    }

    private static func obstructedPointReply(screen: String) -> MacFourVerbsReply {
        MacFourVerbsReply(ok: false,
            text: "That point is covered by a foreground window; I haven't sent input. Name a clear part of the surface or move the obstruction first.\n" + screen,
            detail: ["error": .string("target_point_obstructed")])
    }

    static func aimPoint(in frame: MacAXFrame, describedBy phrase: String) -> (x: Double, y: Double) {
        let words = aimWords(in: phrase)
        let xRatio = words.contains("left") ? 0.25 : words.contains("right") ? 0.75 : 0.5
        let yRatio = words.contains("top") || words.contains("upper")
            ? 0.25
            : (words.contains("bottom") || words.contains("lower") ? 0.75 : 0.5)
        return (frame.x + frame.w * xRatio, frame.y + frame.h * yRatio)
    }

    /// AX can describe a web document with its full many-screen height. A
    /// wheel event must be aimed inside the portion a person can currently
    /// see, not at the mathematical centre of the off-screen document.
    static func visiblePortion(of frame: MacAXFrame?, within viewport: MacAXFrame?) -> MacAXFrame? {
        guard let frame else { return nil }
        guard let viewport else { return frame }
        let x = max(frame.x, viewport.x)
        let y = max(frame.y, viewport.y)
        let right = min(frame.x + frame.w, viewport.x + viewport.w)
        let bottom = min(frame.y + frame.h, viewport.y + viewport.h)
        guard right > x, bottom > y else { return nil }
        return MacAXFrame(x: x, y: y, w: right - x, h: bottom - y)
    }

    struct EffectWords {
        let sentence: String
        let status: String
    }

    /// What changed, said plainly. Everything here is read off the effect diff
    /// the closed loop already computed and already redacted — no value is
    /// re-derived and none is re-rendered from a raw string.
    static func effectWords(
        output: [String: JSONValue],
        verb: MacActVerb,
        typed: String?
    ) -> EffectWords {
        let status = string(output["status"]) ?? "acted"
        let effect = object(output["effect"] ?? .null)
        var parts: [String] = []

        for row in array(effect["readouts_changed"]).prefix(3) {
            let readout = object(row)
            if let text = MacScreenText(string(readout["text"]) ?? "", redacted: readout["text"]).display {
                parts.append("it now reads \"\(text)\"")
            }
        }
        if parts.isEmpty {
            for row in array(effect["readouts_added"]).prefix(2) {
                let readout = object(row)
                if let text = MacScreenText(string(readout["text"]) ?? "", redacted: readout["text"]).display {
                    parts.append("\"\(text)\" appeared")
                }
            }
        }
        if case .bool(true)? = effect["window_changed"] {
            let reasons = array(effect["change_reasons"]).compactMap { string($0) }
            parts.append(reasons.isEmpty ? "the window changed" : "the window changed (\(reasons.joined(separator: ", ")))")
        }
        let added = int(effect["affordances_added_total"]) ?? 0
        let removed = int(effect["affordances_removed_total"]) ?? 0
        if added > 0 || removed > 0 {
            parts.append("\(added) thing\(added == 1 ? "" : "s") appeared, \(removed) went away")
        }
        if verb == .type, let typed, !typed.isEmpty, status == "acted" {
            parts.insert("the text went in", at: 0)
        }

        // The verdict from below is carried, not restated: `acted_unobserved`
        // means the event went out and nothing was seen to happen, and calling
        // that a success is the exact dishonesty the closed loop was built to
        // stop.
        var sentence: String
        if status == "acted" {
            sentence = parts.isEmpty ? "It landed; nothing else on screen moved." : parts.joined(separator: "; ") + "."
        } else if status == "acted_unobserved" {
            let why = string(output["status_reason"]).map { " (\($0))" } ?? ""
            sentence = "The press went out but nothing was seen to change\(why)"
                + (parts.isEmpty ? "." : " — " + parts.joined(separator: "; ") + ".")
        } else {
            sentence = (string(output["status_note"]) ?? "Status: \(status).")
        }
        return EffectWords(sentence: sentence, status: status)
    }

    /// THE HOMEWORK STRIPPER.
    ///
    /// The layers below write real words, and their guidance is used verbatim —
    /// except for the tail they were written with: "…call mac_look again",
    /// "…re-look", "…now do X and call me again". native-screen.md: "A refusal
    /// ending in '…now do X and call me again' is a BUG, not a safety feature."
    /// Those clauses name a tool she does not have any more and ask her to
    /// perform bookkeeping this file already performed — every refusal here is
    /// followed by a fresh screen. So the mechanism survives, the homework does
    /// not, and the reply says which of the two happened.
    static func plainWords(_ guidance: String?) -> String? {
        guard let guidance, !guidance.isEmpty else { return nil }
        // Clause-wise, so the MECHANISM (which is the part she reasons with) is
        // never truncated along with the instruction.
        let clauses = guidance
            .replacingOccurrences(of: " — ", with: "\u{1}")
            .replacingOccurrences(of: "; ", with: "\u{1}")
            .split(separator: "\u{1}", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let homework = ["mac_look", "call me again", "look again", "re-look", "take another look"]
        let kept = clauses.filter { clause in
            let lowered = clause.lowercased()
            return !homework.contains { lowered.contains($0) }
        }
        var mechanism = (kept.isEmpty ? clauses : kept).joined(separator: " — ")
        // …and the FRAME vocabulary goes with it. Below this file a frame is a
        // real object with a real name; in her hands it is the bookkeeping these
        // verbs deleted, and a mechanism she cannot map onto anything she did is
        // not a mechanism she can choose differently from.
        for (jargon, plain) in [
            ("the app this frame was captured from", "the app I was looking at"),
            ("the window this frame was captured from", "the window I was looking at"),
            ("this frame was captured from", "I was looking at"),
            ("the old frame is discarded", "I've let go of what I had"),
            ("this frame", "what I was looking at"),
            ("the frame", "what I was looking at"),
        ] {
            mechanism = mechanism.replacingOccurrences(of: jargon, with: plain)
        }
        var trimmed = mechanism.trimmingCharacters(in: CharacterSet(charactersIn: " .")).appending(".")
        if let first = trimmed.first, first.isLowercase {
            trimmed = first.uppercased() + trimmed.dropFirst()
        }
        // The re-look is stated as DONE, because it is: the fresh screen is
        // already attached below this line.
        return kept.count == clauses.count ? trimmed : trimmed + " I looked again — this is what's there now."
    }

    /// A refusal code with no `guidance` of its own — rare, since the layers
    /// below write their own words. Translated, never echoed bare.
    static func refusalWords(_ code: String) -> String {
        switch code {
        case "window_not_key":
            return "another window has the keyboard right now, so the keystroke would have gone "
                + "somewhere else — nothing was sent."
        case "handle_drifted", "window_drifted":
            return "the screen moved while I was reaching for it — nothing was touched; look again."
        case "frame_window_gone", "frame_app_gone":
            return "what I was looking at isn't there any more — nothing was touched."
        case "verb_not_supported_on_element":
            return "that thing doesn't do that."
        case "observer_unavailable":
            return "I couldn't watch that app for the effect, so I didn't press anything blind."
        default:
            return "it refused: \(code)."
        }
    }

    static func lookRefusalWords(_ code: String) -> String {
        switch code {
        case "no_frontmost_window": return "There's no window up to look at."
        case "ax_untrusted", "accessibility_untrusted":
            return "Accessibility isn't granted to me, so I can't read any window."
        default: return "The read came back \(code)."
        }
    }

    static func place(_ percept: MacLookPercept) -> String {
        let app = percept.app?.name ?? "an unnamed app"
        guard let title = MacScreenText(percept.windowTitle ?? "", redacted: percept.windowTitleJSON).display else {
            return app
        }
        return "\(app) — \"\(title)\""
    }

    // MARK: - Where "there" is
    //
    // Three shapes, tested in order, with no app-name branch anywhere: a URL
    // with a web scheme, a filesystem path, then a NAME (running first, then
    // installed). A string that is none of those is not guessed at.

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        // Deliberately reject arbitrary custom schemes: `go` is a web/file/app
        // navigator, not a way for a string to select a privileged URL handler.
        guard ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    static func filePath(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme?.lowercased() == "file" { return url }
        var path = text
        if path.hasPrefix("~") {
            path = NSHomeDirectory() + String(path.dropFirst())
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private enum NamedFolderResolution {
        case none
        case unique(URL)
        case ambiguous([String])
    }

    /// A bare destination name gets one small, predictable filesystem fallback
    /// after app activation says it is not an app. Search only direct children
    /// of the familiar home folders; never recurse, fuzzy-match, or pick the
    /// first duplicate. The roots are injected so tests do not inspect the
    /// developer's home directory.
    private static func namedFolder(_ name: String, under roots: [URL]) -> NamedFolderResolution {
        let manager = FileManager.default
        var matches: [URL] = []
        var seenPaths: Set<String> = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard let children = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where child.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let path = child.standardizedFileURL.path
                if seenPaths.insert(path).inserted { matches.append(child.standardizedFileURL) }
            }
        }

        if matches.isEmpty { return .none }
        if matches.count == 1 { return .unique(matches[0]) }
        return .ambiguous(matches.map { $0.deletingLastPathComponent().lastPathComponent })
    }

    private static func commonHomeLocationRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Whether the fresh screen proves the requested destination. `nil` means
    /// the surface does not publish enough identity to decide (common for a URL
    /// whose page title does not resemble its host); it never means success.
    static func destination(_ requested: String, matches sighting: Sighting) -> Bool? {
        if let url = webURL(requested) {
            guard let host = url.host?.lowercased() else { return nil }
            let hostWords = host
                .replacingOccurrences(of: "www.", with: "")
                .split(separator: ".")
                .map(String.init)
                .filter { $0.count > 2 && !["com", "org", "net", "io", "app"].contains($0) }
            guard !hostWords.isEmpty else { return nil }
            let visible = normalize(sighting.place + " " + sighting.render)
            return hostWords.contains { visible.contains(normalize($0)) } ? true : nil
        }
        if let path = filePath(requested) {
            let leaf = normalize(path.lastPathComponent)
            guard !leaf.isEmpty else { return nil }
            let stem = normalize(path.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " "))
            let visible = normalize(sighting.place + " " + sighting.render)
            return visible.contains(leaf) || (stem.count >= 3 && visible.contains(stem))
        }
        let wanted = normalize(requested)
        guard !wanted.isEmpty, let app = sighting.appName.map(normalize) else { return nil }
        return app.contains(wanted) || wanted.contains(app)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1fs", max(0, value))
    }

    /// A screenshot supplement is useful only when it describes the same app
    /// as the semantic look it augments. The two captures are separate system
    /// calls, so a foreground change between them must discard the supplement
    /// rather than manufacture one mixed screen.
    static func sameApp(percept: MacLookPercept, supplement: MacFourVerbsSupplement) -> Bool {
        if let lookID = percept.app?.bundleIdentifier, let viewID = supplement.bundleIdentifier {
            return lookID == viewID
        }
        guard let lookName = percept.app?.name, let viewName = supplement.appName else { return false }
        return normalize(lookName) == normalize(viewName)
    }

    // MARK: - Percept reconstruction
    //
    // The look organ answers in JSON whose strings have ALREADY been through
    // the compiler's redaction under the full node context. Those verdicts are
    // carried through verbatim into `MacScreenText`, which is what decides what
    // prints — this file never re-redacts and never re-renders a raw string.
    // A withheld string arrives as an object rather than a `.string`, so it
    // prints as `⟨redacted⟩` and matches no name.

    static func percept(from output: [String: JSONValue]) -> MacLookPercept {
        let app = object(output["app"] ?? .null)
        let (windowRaw, windowJSON) = text(output["window"])
        let focus = object(output["focus"] ?? .null)
        let modal = object(output["modal"] ?? .null)

        return MacLookPercept(
            app: string(app["name"]).map {
                MacAXAppInfo(
                    name: $0,
                    bundleIdentifier: string(app["bundle_id"]),
                    processIdentifier: Int32(int(app["pid"]) ?? 0)
                )
            },
            windowTitle: windowRaw,
            focus: string(focus["role"]).map { role in
                let (label, labelJSON) = text(focus["label"])
                return MacLookFocus(
                    role: role,
                    label: label,
                    handle: string(focus["handle"]),
                    path: path(focus["path"]),
                    labelJSON: labelJSON
                )
            },
            modal: string(modal["role"]).map { role in
                let (label, labelJSON) = text(modal["label"])
                return MacLookModal(
                    role: role,
                    subrole: string(modal["subrole"]),
                    label: label,
                    path: path(modal["path"]),
                    labelJSON: labelJSON
                )
            },
            landmarks: array(output["landmarks"]).map { row in
                let landmark = object(row)
                let (label, labelJSON) = text(landmark["label"])
                return MacLookLandmark(
                    kind: string(landmark["kind"]) ?? "region",
                    role: string(landmark["role"]) ?? "AXUnknown",
                    label: label,
                    depth: Int(int(landmark["depth"]) ?? 1),
                    path: path(landmark["path"]),
                    frame: frame(landmark["frame"]),
                    labelJSON: labelJSON
                )
            },
            affordances: array(output["affordances"]).compactMap { row in
                let affordance = object(row)
                guard let handle = string(affordance["handle"]),
                      let role = string(affordance["role"]) else { return nil }
                let (label, labelJSON) = text(affordance["label"])
                let (value, valueJSON) = text(affordance["value"])
                return MacLookAffordance(
                    handle: handle,
                    role: role,
                    subrole: string(affordance["subrole"]),
                    label: label ?? "",
                    labelSource: string(affordance["label_source"]) ?? "title",
                    value: value,
                    secret: affordance["secret_field"] == .bool(true),
                    enabled: affordance["enabled"] != .bool(false),
                    selected: bool(affordance["selected"]),
                    frame: frame(affordance["frame"]),
                    path: path(affordance["path"]),
                    labelJSON: labelJSON,
                    valueJSON: valueJSON
                )
            },
            unlabeledByRole: object(output["unlabeled"] ?? .null).reduce(into: [:]) { out, entry in
                out[entry.key] = Int(int(entry.value) ?? 0)
            },
            affordancesOmitted: Int(int(output["affordances_omitted"]) ?? 0),
            interactiveCount: Int(int(output["interactive_count"]) ?? 0),
            labeledCount: Int(int(output["labeled_count"]) ?? 0),
            truncated: output["truncated"] == .bool(true),
            truncationReasons: array(output["truncation_reasons"]).compactMap { string($0) },
            skippedAtLeast: Int(int(output["skipped_at_least"]) ?? 0),
            windowTitleJSON: windowJSON,
            readouts: array(output["readouts"]).map { row in
                let readout = object(row)
                let (value, valueJSON) = text(readout["text"])
                return MacLookReadout(
                    handle: string(readout["handle"]),
                    role: string(readout["role"]) ?? "AXStaticText",
                    text: value ?? "",
                    source: string(readout["source"]) ?? "value",
                    path: path(readout["path"]),
                    nearFocus: readout["near_focus"] == .bool(true),
                    inModal: readout["in_modal"] == .bool(true),
                    textJSON: valueJSON
                )
            },
            readoutsOmitted: Int(int(output["readouts_omitted"]) ?? 0)
        )
    }

    /// The SAME split `MacScreenRender.screen(from:)` makes — a control ROLE, or
    /// anything inside a control CONTAINER — using the same two sets, so the
    /// ordinal she reads in the render is the row this resolves. A test pins the
    /// agreement rather than leaving it to inspection.
    static func partition(
        _ percept: MacLookPercept
    ) -> (rows: [MacLookAffordance], controls: [MacLookAffordance]) {
        let containers = percept.landmarks
            .filter { MacScreenRender.controlContainerKinds.contains($0.kind) }
            .map(\.path)
        func insideContainer(_ path: [Int]) -> Bool {
            containers.contains { container in
                container.count < path.count && Array(path.prefix(container.count)) == container
            }
        }
        var rows: [MacLookAffordance] = []
        var controls: [MacLookAffordance] = []
        for affordance in percept.affordances {
            let isControl = !MacScreenRender.contentRowRoles.contains(affordance.role)
                && (MacPerceptionCompiler.controlRoles.contains(affordance.role)
                    || insideContainer(affordance.path))
            if isControl { controls.append(affordance) } else { rows.append(affordance) }
        }
        return (rows, controls)
    }

    /// Fuse only one supported identity. An AX path is capture-local: labels
    /// and available geometry must still agree so a reordered tree cannot
    /// donate a different control's physical mark to an old semantic handle.
    /// A matching row/cell and its contained filename may share the named item,
    /// without sharing marks; separate rows and interactive descendants cannot.
    static func supplementalDuplicateIndex(
        _ candidate: MacFourVerbsSupplementalTarget, among targets: [ActTarget]
    ) -> Int? {
        let display = candidate.label?.display.map(normalize)
        let matches = targets.indices.filter { index in
            let existing = targets[index]
            let existingLabel = existing.label.map(normalize)
            let sameLabel = display != nil && display == existingLabel
            let incompatibleLabel = display != nil && existingLabel != nil && !sameLabel
            if let path = candidate.sourceAXPath, let existingPath = existing.sourceAXPath,
               path != existingPath {
                let itemKinds: Set<String> = ["row", "cell", "item"]
                let displayKinds = itemKinds.union(["text"])
                let shorter = path.count < existingPath.count ? path : existingPath
                let longer = path.count < existingPath.count ? existingPath : path
                return sameLabel && display?.isEmpty == false
                    && candidate.enabled == existing.enabled
                    && !candidate.physicalOnly && !existing.physicalOnly
                    && displayKinds.contains(candidate.kind) && displayKinds.contains(existing.kind)
                    && (itemKinds.contains(candidate.kind) || itemKinds.contains(existing.kind))
                    && !shorter.isEmpty && longer.count - shorter.count <= 2
                    && longer.starts(with: shorter)
                    && framesOverlap(candidate.frame, existing.frame)
            }
            guard candidate.kind == existing.kind else { return false }
            if let path = candidate.sourceAXPath, let existingPath = existing.sourceAXPath {
                guard path == existingPath, !incompatibleLabel else { return false }
                return existing.frame.map { framesOverlap(candidate.frame, $0) } ?? sameLabel
            }
            // Named moving pixel regions can overlap by design. Their live
            // names, not geometric containment, identify the region.
            if candidate.physicalOnly || existing.physicalOnly { return sameLabel }
            guard !incompatibleLabel else { return false }
            if let frame = existing.frame { return framesOverlap(candidate.frame, frame) }
            return sameLabel
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func framesOverlap(_ lhs: MacAXFrame, _ rhs: MacAXFrame?) -> Bool {
        guard let rhs, lhs.w > 0, lhs.h > 0, rhs.w > 0, rhs.h > 0 else { return false }
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.w, rhs.x + rhs.w)
        let bottom = min(lhs.y + lhs.h, rhs.y + rhs.h)
        guard right > left, bottom > top else { return false }
        let intersection = (right - left) * (bottom - top)
        let smaller = min(lhs.w * lhs.h, rhs.w * rhs.h)
        return smaller > 0 && intersection / smaller >= 0.65
    }

    /// Fuse additive evidence without printing the same AX/vision label twice.
    /// AX is the authoritative semantic lane and therefore stays first.
    static func adding(
        contents: [MacScreenRender.Content] = [],
        controls: [MacScreenRender.Control] = [],
        values: [MacScreenRender.Value] = [],
        to screen: MacScreenRender.Screen
    ) -> MacScreenRender.Screen {
        var known = Set<String>()
        for control in screen.controls {
            if let label = control.label.display { known.insert(normalize(label)) }
        }
        for content in screen.contents {
            for row in content.rows {
                if let label = row.label?.display { known.insert(normalize(label)) }
            }
        }
        for value in screen.values {
            if let text = value.text.display { known.insert(normalize(text)) }
        }

        let newControls = controls.filter { control in
            // AX-backed rows were reconciled with targets by identity above.
            // Equal labels on distinct paths are not duplicate controls.
            if control.sourceAXPath != nil {
                if let label = control.label.display { known.insert(normalize(label)) }
                return true
            }
            guard let label = control.label.display else { return true }
            return known.insert(normalize(label)).inserted
        }
        var newContents: [MacScreenRender.Content] = []
        for content in contents {
            if content.kind == .canvas {
                if !screen.contents.contains(where: { $0.kind == .canvas }) { newContents.append(content) }
                continue
            }
            let rows = content.rows.filter { row in
                if row.sourceAXPath != nil {
                    if let label = row.label?.display { known.insert(normalize(label)) }
                    return true
                }
                guard let label = row.label?.display else { return true }
                return known.insert(normalize(label)).inserted
            }
            if !rows.isEmpty {
                newContents.append(MacScreenRender.Content(
                    kind: content.kind,
                    noun: content.noun,
                    rows: rows,
                    totalRows: rows.count,
                    scrollable: content.scrollable,
                    canvas: content.canvas
                ))
            }
        }
        let newValues = values.filter { value in
            guard let text = value.text.display else { return true }
            return known.insert(normalize(text)).inserted
        }

        // An open native menu is the immediate interaction surface. Keep its
        // choices ahead of background toolbar controls under the render cap,
        // preserving order within each role so existing ordinals stay valid.
        let allControls = screen.controls + newControls
        let orderedControls = allControls.filter { $0.kind == "menu item" }
            + allControls.filter { $0.kind != "menu item" }

        return MacScreenRender.Screen(
            appName: screen.appName,
            windowTitle: screen.windowTitle,
            isFront: screen.isFront,
            otherWindows: screen.otherWindows,
            provenance: screen.provenance,
            modal: screen.modal,
            whereSteps: screen.whereSteps,
            contents: screen.contents + newContents,
            controls: orderedControls,
            totalControls: screen.totalControls + newControls.count,
            unlabeledControls: screen.unlabeledControls,
            values: screen.values + newValues,
            totalValues: screen.totalValues + newValues.count,
            unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
        )
    }

    // MARK: - JSON primitives

    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    static func visionValueTexts(_ detail: [String: JSONValue]) -> Set<String>? {
        let source = detail["vision_effect_value_text"] ?? detail["vision_value_text"]
        guard case .array(let values)? = source else { return nil }
        return Set(values.compactMap { string($0) }.map(normalize))
    }

    static func array(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let array)? = value else { return [] }
        return array
    }

    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    static func int(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let number)?: return number
        case .double(let number)?: return Int64(number)
        default: return nil
        }
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let number)?: return Double(number)
        case .double(let number)? where number.isFinite: return number
        default: return nil
        }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    static func frame(_ value: JSONValue?) -> MacAXFrame? {
        let value = object(value)
        guard let x = number(value["x"]), let y = number(value["y"]),
              let w = number(value["w"]), let h = number(value["h"]),
              w > 0, h > 0 else { return nil }
        return MacAXFrame(x: x, y: y, w: w, h: h)
    }

    static func path(_ value: JSONValue?) -> [Int] {
        array(value).compactMap { int($0).map(Int.init) }
    }

    /// A string channel out of the look, as the pair `MacScreenText` needs: the
    /// clear text when redaction let it through, and a NON-EMPTY placeholder
    /// plus the withholding verdict when it did not — so the render prints
    /// `⟨redacted⟩` (visibly absent) rather than `⟨unlabeled⟩` (a different
    /// fact).
    static func text(_ value: JSONValue?) -> (String?, JSONValue?) {
        switch value {
        case .string(let clear)?:
            return (clear, .string(clear))
        case .object?:
            return ("⟨withheld⟩", value)
        default:
            return (nil, nil)
        }
    }

    static func operationDetail(_ result: MacControlResult) -> [String: JSONValue] {
        var detail: [String: JSONValue] = [:]
        if let operationId = result.operationId { detail["operationId"] = .string(operationId) }
        if let state = result.operationState { detail["operationState"] = .string(state.rawValue) }
        if let verification = result.verification { detail["verification"] = .string(verification.rawValue) }
        return detail
    }

    private func landingFailure(
        _ line: String,
        detail: [String: JSONValue] = [:]
    ) async -> MacFourVerbsReply {
        switch await sight(part: nil) {
        case .blind:
            return MacFourVerbsReply(
                ok: false,
                text: line,
                detail: detail.merging(["error": .string("go_failed")]) { current, _ in current }
            )
        case .seen(let hit):
            return MacFourVerbsReply(
                ok: false,
                text: line + " Still looking at " + hit.place + ".\n" + hit.render,
                detail: detail.merging(["error": .string("go_failed")]) { current, _ in current }
            )
        }
    }
}
