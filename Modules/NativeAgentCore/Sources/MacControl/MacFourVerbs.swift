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
    public let label: MacScreenText?
    public let kind: String
    public let frame: MacAXFrame
    public let provenance: MacScreenRender.Provenance
    public let viewId: String?
    public let mark: Int?
    public let ordinal: Int?
    public let regionOnly: Bool
    /// Pixel evidence can pin a useful place without knowing what kind of UI
    /// object occupies it. Such a target may receive literal hand gestures,
    /// but must never be promoted into type/select/toggle/dismiss semantics.
    public let physicalOnly: Bool

    public init(
        label: MacScreenText?,
        kind: String,
        frame: MacAXFrame,
        provenance: MacScreenRender.Provenance,
        viewId: String? = nil,
        mark: Int? = nil,
        ordinal: Int? = nil,
        regionOnly: Bool = false,
        physicalOnly: Bool = false
    ) {
        self.label = label
        self.kind = kind
        self.frame = frame
        self.provenance = provenance
        self.viewId = viewId
        self.mark = mark
        self.ordinal = ordinal
        self.regionOnly = regionOnly
        self.physicalOnly = physicalOnly
    }
}

/// Additive evidence from the fused screenshot lane. It never replaces AX:
/// semantic targets win when both organs describe the same region, and this
/// fills only the things AX could not name plus genuinely pixel-only regions.
public struct MacFourVerbsSupplement: Sendable, Equatable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let visibleFrame: MacAXFrame?
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
        contents: [MacScreenRender.Content] = [],
        controls: [MacScreenRender.Control] = [],
        values: [MacScreenRender.Value] = [],
        targets: [MacFourVerbsSupplementalTarget] = [],
        diagnostics: [String: JSONValue] = [:]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.visibleFrame = visibleFrame
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
    func sleep(seconds: Double) async
}

public struct SystemMacFourVerbsClock: MacFourVerbsClock {
    public init() {}
    public func now() -> Date { Date() }
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

    public init(
        host: any MacFourVerbsHost,
        clock: any MacFourVerbsClock = SystemMacFourVerbsClock(),
        supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)? = nil,
        options: MacScreenRender.Options = .default,
        namedLocationRoots: [URL]? = nil
    ) {
        self.host = host
        self.clock = clock
        self.supplementalSource = supplementalSource
        self.options = options
        self.namedLocationRoots = namedLocationRoots ?? Self.commonHomeLocationRoots()
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
    public func screen(part: String? = nil) async -> MacFourVerbsReply {
        switch await sight(part: part) {
        case .blind(let reply):
            return reply
        case .seen(let sighting):
            var lead = "Looking at " + sighting.place + "."
            if let part, let note = sighting.zoomNote {
                lead = "Zoomed on \"\(part)\" in " + sighting.place + ". " + note
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
        seconds: Double? = nil,
        repeat requestedRepeat: Int? = nil,
        interval: Double? = nil,
        holding: String? = nil
    ) async -> MacFourVerbsReply {
        let requested = max(1, min(requestedRepeat ?? 1, Self.maximumActRepeats))
        let pause = max(0, min(interval ?? 0, Self.maximumActIntervalSeconds))
        let perAttemptBudget = max(0, min(seconds ?? 0, 10)) + pause
        let durationBound = perAttemptBudget > 0
            ? max(1, Int(Self.maximumActBurstSeconds / perAttemptBudget))
            : Self.maximumActRepeats
        let attempts = min(requested, durationBound)
        if attempts == 1 {
            return await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                to: destination,
                seconds: seconds,
                holding: holding,
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
        var completed = 0
        var visiblyVerified = 0
        var finalReply: MacFourVerbsReply?
        for attempt in 1...attempts {
            guard !Task.isCancelled else { break }
            let reply = await actOnce(
                verb: rawVerb,
                target: target,
                text: text,
                to: destination,
                seconds: seconds,
                holding: holding,
                attention: attention
            )
            finalReply = reply
            guard reply.ok else { break }
            completed += 1
            if Self.string(reply.detail["verification"]) == MotorVerificationState.satisfied.rawValue {
                visiblyVerified += 1
            }
            if attempt < attempts, pause > 0 { await clock.sleep(seconds: pause) }
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
        detail["repeat_planned"] = .int(Int64(attempts))
        detail["repeat_completed"] = .int(Int64(completed))
        detail["repeat_visibly_verified"] = .int(Int64(visiblyVerified))
        detail["repeat_stopped_early"] = .bool(completed < requested)
        if let holding { detail["holding"] = .string(holding) }
        if completed == attempts, visiblyVerified == completed {
            detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
            detail["verification_evidence"] = .string("fresh_visible_evidence_for_every_burst_attempt")
        } else if finalReply.ok {
            detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
            detail.removeValue(forKey: "verification_evidence")
        }

        let boundNote = attempts < requested
            ? " The 30-second safety bound limited this burst to \(attempts)."
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
            lead = "Completed \(completed)/\(requested) requested attempts. \(proof)\(boundNote)"
        } else {
            lead = "Stopped after \(completed)/\(requested) requested attempts. \(proof)\(boundNote)"
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
        seconds: Double?,
        holding: String?,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        let (verbName, parsedDirection) = Self.parseVerb(rawVerb)
        let direction: MacActScrollDirection = {
            guard verbName == MacActVerb.scroll.rawValue else { return parsedDirection }
            let hint = Self.normalize(text ?? "")
            if hint == "up" || hint.contains("scroll up") { return .up }
            if hint == "down" || hint.contains("scroll down") { return .down }
            return parsedDirection
        }()
        if let physical = PhysicalVerb(rawValue: verbName) {
            return await performPhysical(
                physical,
                target: target,
                destination: destination,
                seconds: seconds,
                holding: holding,
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
        let sighting: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let hit): sighting = hit
        }

        // b. RESOLVE BY NAME.
        let resolution = verb == .scroll
            ? Self.resolveScrollTarget(target, among: sighting.targets)
            : Self.resolve(target, among: sighting.targets)
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
                detail: ["error": .string("no_match"), "target": .string(target)]
            )

        case .ambiguous(let candidates):
            // The reply IS the question. Nothing is acted on.
            let listed = candidates.map { candidate -> String in
                let name = candidate.label ?? MacScreenRender.unlabeledMarker
                if let ordinal = candidate.ordinal { return "row \(ordinal) \"\(name)\" (\(candidate.kind))" }
                return "\"\(name)\" (\(candidate.kind))"
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
               Self.physicalScrollKinds.contains(candidate.kind),
               candidate.kind == "web area" || candidate.frame != nil {
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
            }
            if holding != nil {
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
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
            }
            if candidate.isSupplemental {
                return await performSupplementalSemantic(
                    verb,
                    direction: direction,
                    candidate: candidate,
                    target: target,
                    text: text,
                    holding: holding,
                    attention: attention,
                    before: sighting
                )
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
        seconds: Double?,
        holding: String?,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        if verb == .hold, holding != nil {
            return MacFourVerbsReply(
                ok: false,
                text: "A hold already keeps its target down; don't give it a second held-key set.",
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

        let before: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let seen): before = seen
        }
        let source: ActTarget
        switch Self.resolve(target, among: before.targets) {
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
        let start = Self.aimPoint(in: sourceFrame, describedBy: target)

        var body: [String: JSONValue] = [
            "gesture": .string(verb.rawValue),
            "x": .double(start.x),
            "y": .double(start.y),
        ]
        if let seconds { body["seconds"] = .double(seconds) }
        if let holding { body["holding"] = .string(holding) }
        var description: String
        if verb == .drag {
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Where should I drag \(Self.name(source)) to?")
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
            let end = Self.aimPoint(in: endFrame, describedBy: destination)
            body["to_x"] = .double(end.x)
            body["to_y"] = .double(end.y)
            description = "Dragged \(Self.name(source)) to \(Self.name(endTarget))."
        } else {
            switch verb {
            case .hover: description = "Hovered over \(Self.name(source))."
            case .hold: description = "Held \(Self.name(source))."
            case .move: description = "Moved to \(Self.name(source))."
            case .drag, .key: description = "Used \(Self.name(source))."
            }
        }
        return await performHand(
            body: body,
            description: description,
            attention: attention,
            before: before
        )
    }

    private func performSupplementalSemantic(
        _ verb: MacActVerb,
        direction: MacActScrollDirection,
        candidate: ActTarget,
        target: String,
        text: String?,
        holding: String?,
        attention: BurstAttention?,
        before: Sighting
    ) async -> MacFourVerbsReply {
        if let viewId = candidate.viewId, let mark = candidate.mark,
           verb != .open, verb != .scroll, holding == nil {
            var body: [String: JSONValue] = [
                "view": .string(viewId),
                "mark": .int(Int64(mark)),
            ]
            if verb == .type {
                guard let text, !text.isEmpty else {
                    return MacFourVerbsReply(ok: false, text: "Nothing to type into \(Self.name(candidate)).")
                }
                body["value"] = .string(text)
            } else {
                body["action"] = .string("AXPress")
            }
            return await performObservedDispatch(
                action: "ax_act",
                body: body,
                description: Self.pastTense(verb, direction: direction) + " " + Self.name(candidate) + ".",
                before: before,
                target: target,
                verb: verb.rawValue,
                attention: attention
            )
        }

        var body: [String: JSONValue] = [:]
        if !(verb == .scroll && candidate.kind == "web area") {
            guard let candidateFrame = Self.visiblePortion(of: candidate.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can see \(Self.name(candidate)), but I do not have a safe point for it.",
                    detail: ["error": .string("target_has_no_physical_point")]
                )
            }
            let point = Self.aimPoint(in: candidateFrame, describedBy: target)
            body["x"] = .double(point.x)
            body["y"] = .double(point.y)
        }
        if let holding { body["holding"] = .string(holding) }
        switch verb {
        case .click, .select, .toggle, .dismiss:
            body["gesture"] = .string("click")
        case .open:
            body["gesture"] = .string("double_click")
        case .type:
            guard let text, !text.isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Nothing to type into \(Self.name(candidate)).")
            }
            body["gesture"] = .string("click_type")
            body["text"] = .string(text)
        case .scroll:
            if candidate.kind == "web area" {
                // Live Chrome proof: synthesized wheel events were accepted
                // but inert on the AX web area, while the ordinary Page key
                // moved the same visible document and produced fresh proof.
                // Keep that physical distinction below the natural scroll
                // verb; the caller still names the region and direction.
                body["gesture"] = .string("key")
                body["keys"] = .string(direction == .up ? "pageup" : "pagedown")
            } else {
                body["gesture"] = .string("scroll")
                body["dy"] = .int(direction == .up ? 6 : -6)
            }
        }
        let reply = await performHand(
            body: body,
            description: Self.pastTense(verb, direction: direction) + " " + Self.name(candidate) + ".",
            unverifiedDescription: verb == .scroll
                ? "Tried to scroll \(direction.rawValue) in \(Self.name(candidate))."
                : nil,
            attention: attention,
            before: before,
            allowGenericScreenChangeVerification: !candidate.physicalOnly
        )
        var detail = reply.detail
        detail["verb"] = .string(verb.rawValue)
        detail["target"] = .string(target)
        detail["matched"] = .string(Self.name(candidate))
        let physicalRoute: String
        switch verb {
        case .click, .select, .toggle, .dismiss: physicalRoute = "click"
        case .open: physicalRoute = "double_click"
        case .type: physicalRoute = "click_type"
        case .scroll: physicalRoute = candidate.kind == "web area" ? "page_key" : "wheel"
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
        allowGenericScreenChangeVerification: Bool = true
    ) async -> MacFourVerbsReply {
        let result: MacControlResult
        var request = body
        Self.addAttention(attention, to: &request)
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
            allowGenericScreenChangeVerification: allowGenericScreenChangeVerification
        )
    }

    private func observedReply(
        result: MacControlResult,
        description: String,
        unverifiedDescription: String? = nil,
        before: Sighting?,
        allowGenericScreenChangeVerification: Bool = true
    ) async -> MacFourVerbsReply {
        switch await sight(part: nil) {
        case .blind(let reply):
            return MacFourVerbsReply(
                ok: true,
                text: (unverifiedDescription ?? description)
                    + " The input went out, but I couldn't take the confirming look. " + reply.text,
                detail: Self.operationDetail(result).merging(["observed_after": .bool(false)]) { current, _ in current }
            )
        case .seen(let after):
            let structuralChanged = before.map { $0.render != after.render }
            let handlerEvidence = Self.bool(Self.object(result.output)["verified"]) == true
            let changed = structuralChanged.map { $0 || handlerEvidence }
            let visibleValueChanged: Bool = {
                guard let before,
                      let beforeValues = Self.visionValueTexts(before.detail),
                      let afterValues = Self.visionValueTexts(after.detail) else { return false }
                return beforeValues != afterValues
            }()
            let observation: String
            if visibleValueChanged { observation = " A value the fresh screen says changed after it." }
            else if structuralChanged == true { observation = " The fresh screen changed after it." }
            else if handlerEvidence {
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
            if visibleValueChanged {
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
        let names = candidates.map(Self.name).joined(separator: ", ")
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

    /// Bounded waiting. Polls `screen()`; returns early when the render CONTAINS
    /// `until`, or when the screen stops changing (two identical renders in a
    /// row), or when the budget runs out — and says WHICH of the three it was.
    /// A timeout is never dressed up as a settle.
    public func wait(until: String? = nil, seconds: Double? = nil) async -> MacFourVerbsReply {
        let budget = min(max(seconds ?? Self.defaultWaitSeconds, 0), Self.maxWaitSeconds)
        let needle = until?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let startedAt = clock.now()
        var previous: String?
        var last: Sighting?
        var budgetLeft = true

        while budgetLeft {
            let hit: Sighting
            switch await sight(part: nil) {
            case .blind(let reply): return reply
            case .seen(let seen): hit = seen
            }
            last = hit
            let elapsed = clock.now().timeIntervalSince(startedAt)
            if let needle, !needle.isEmpty, hit.render.lowercased().contains(needle) {
                return MacFourVerbsReply(
                    ok: true,
                    text: "\"\(until ?? "")\" appeared after \(Self.seconds(elapsed)).\n" + hit.render,
                    detail: ["outcome": .string("matched"), "seconds": .double(elapsed)]
                )
            }
            if previous == hit.render {
                return MacFourVerbsReply(
                    ok: true,
                    text: (needle?.isEmpty == false
                           ? "Settled after \(Self.seconds(elapsed)) and \"\(until ?? "")\" never appeared."
                           : "Settled after \(Self.seconds(elapsed)).") + "\n" + hit.render,
                    detail: ["outcome": .string("settled"), "seconds": .double(elapsed)]
                )
            }
            previous = hit.render
            budgetLeft = elapsed + Self.pollSeconds <= budget
            if budgetLeft { await clock.sleep(seconds: Self.pollSeconds) }
        }

        let elapsed = clock.now().timeIntervalSince(startedAt)
        let ending = needle?.isEmpty == false
            ? "Timed out after \(Self.seconds(elapsed)) — \"\(until ?? "")\" never appeared and the screen is still changing."
            : "Timed out after \(Self.seconds(elapsed)) — the screen is still changing."
        return MacFourVerbsReply(
            ok: false,
            text: ending + (last.map { "\n" + $0.render } ?? ""),
            detail: ["outcome": .string("timeout"), "seconds": .double(elapsed)]
        )
    }

    static let defaultWaitSeconds: Double = 10
    static let maxWaitSeconds: Double = 60
    static let pollSeconds: Double = 0.5

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
        let place: String
        let appName: String?
        let bundleIdentifier: String?
        let visibleFrame: MacAXFrame?
        let targets: [ActTarget]
        let frameId: String
        let zoomNote: String?
        let detail: [String: JSONValue]
    }

    /// A resolvable thing on the screen. `label` is the DISPLAY text — what the
    /// renderer printed — so anything redaction withheld cannot be named.
    struct ActTarget: Equatable {
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
        let viewId: String?
        let mark: Int?
        let regionOnly: Bool
        let physicalOnly: Bool

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
            viewId: String? = nil,
            mark: Int? = nil,
            regionOnly: Bool = false,
            physicalOnly: Bool = false
        ) {
            self.handle = handle
            self.label = label
            self.aliases = aliases
            self.kind = kind
            self.ordinal = ordinal
            self.roleOrdinal = roleOrdinal
            self.enabled = enabled
            self.frame = frame
            self.viewId = viewId
            self.mark = mark
            self.regionOnly = regionOnly
            self.physicalOnly = physicalOnly
        }
    }

    private func sight(part: String?) async -> Sighted {
        await sight(part: part, wakeAttemptsRemaining: 2)
    }

    /// A screen saver is an obstruction to perception, not a destination Agent
    /// should reason about. Clear it with the already-gated wake organ and then
    /// start the read again. Two attempts cover the observed macOS teardown
    /// delay without creating an unbounded input loop.
    private func sight(part: String?, wakeAttemptsRemaining: Int) async -> Sighted {
        let result: MacControlResult
        do {
            result = try await host.dispatch(action: "look", body: ["grade": .string("look")])
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
                detail: ["error": .string(result.error ?? "look_failed")]
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
                return await sight(part: part, wakeAttemptsRemaining: wakeAttemptsRemaining - 1)
            }
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "The screensaver is covering the desktop, and the safe wake nudge was refused before anything moved.",
                detail: Self.operationDetail(wake).merging([
                    "error": .string("display_obstructed")
                ]) { current, _ in current }
            ))
        }

        // The look is frontmost-anchored by construction, so FRONT is a fact
        // here rather than a guess; how many OTHER windows exist is not
        // something this read can tell, and an unknown is omitted, never zeroed
        // into a claim.
        var full = MacScreenRender.screen(from: percept, isFront: true)
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
                mark: nil
            ))
        }
        var unnamedControlRoleOrdinals: [String: Int] = [:]
        for control in controls {
            let kind = MacScreenRender.kindName(role: control.role)
            let display = MacScreenText(control.label, redacted: control.labelJSON).display
            let roleOrdinal: Int?
            if display == nil {
                let next = (unnamedControlRoleOrdinals[kind] ?? 0) + 1
                unnamedControlRoleOrdinals[kind] = next
                roleOrdinal = next
            } else {
                roleOrdinal = nil
            }
            targets.append(ActTarget(
                handle: control.handle,
                label: display,
                kind: kind,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: control.enabled,
                frame: control.frame,
                viewId: nil,
                mark: nil
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
                regionOnly: true
            ))
        }

        var visibleFrame: MacAXFrame?
        var supplementalDiagnostics: [String: JSONValue] = [:]
        if let supplement = await supplementalSource?.observe(),
           Self.sameApp(percept: percept, supplement: supplement) {
            visibleFrame = supplement.visibleFrame
            supplementalDiagnostics = supplement.diagnostics
            var addedTargets: [ActTarget] = []
            for candidate in supplement.targets {
                let display = candidate.label?.display
                let combined = targets + addedTargets
                let duplicateIndex = combined.firstIndex { existing in
                    if let display, let existingLabel = existing.label,
                       Self.normalize(display) == Self.normalize(existingLabel),
                       candidate.kind == existing.kind { return true }
                    // Nested saliency regions commonly overlap (for example a
                    // bright core and its moving glow). Their live-scene names
                    // are the identity. Geometric dedup may keep region 2,
                    // discard region 1's resolver target, and still render
                    // both rows—making ACT deny the exact name SCREEN printed.
                    // Only an exact label may fuse physical-only regions.
                    if candidate.physicalOnly || existing.physicalOnly { return false }
                    // A toolbar/sidebar/list contains its controls, so pure
                    // geometric containment is not identity. Cross-kind frame
                    // dedup swallowed every nested button into its landmark
                    // while the renderer still truthfully printed the button.
                    return candidate.kind == existing.kind
                        && Self.framesOverlap(candidate.frame, existing.frame)
                }
                if let duplicateIndex {
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
                    let mergedViewId = existing.viewId ?? candidate.viewId
                    let mergedMark = existing.mark ?? candidate.mark
                    guard mergedLabel != existing.label
                            || mergedFrame != existing.frame
                            || mergedViewId != existing.viewId
                            || mergedMark != existing.mark else { continue }
                    let enriched = ActTarget(
                        handle: existing.handle,
                        label: mergedLabel,
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: mergedFrame,
                        viewId: mergedViewId,
                        mark: mergedMark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly || candidate.physicalOnly
                    )
                    if duplicateIndex < targets.count {
                        targets[duplicateIndex] = enriched
                    } else {
                        addedTargets[duplicateIndex - targets.count] = enriched
                    }
                    continue
                }
                addedTargets.append(ActTarget(
                    handle: "",
                    label: display,
                    kind: candidate.kind,
                    ordinal: rows.isEmpty ? candidate.ordinal : nil,
                    roleOrdinal: candidate.ordinal ?? Self.nextRoleOrdinal(
                        for: candidate.kind,
                        among: targets + addedTargets
                    ),
                    enabled: true,
                    frame: candidate.frame,
                    viewId: candidate.viewId,
                    mark: candidate.mark,
                    regionOnly: candidate.regionOnly,
                    physicalOnly: candidate.physicalOnly
                ))
            }
            targets.append(contentsOf: addedTargets)
            full = Self.adding(
                contents: supplement.contents,
                controls: supplement.controls,
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
                        viewId: existing.viewId,
                        mark: existing.mark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly
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
                        viewId: existing.viewId,
                        mark: existing.mark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly
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
                    mark: nil
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
        return .seen(Sighting(
            render: rendering.text,
            place: Self.place(percept),
            appName: percept.app?.name,
            bundleIdentifier: percept.app?.bundleIdentifier,
            visibleFrame: visibleFrame,
            targets: targets,
            frameId: frameId,
            zoomNote: zoom?.note,
            detail: [
                "bytes": .int(Int64(rendering.bytes)),
                "rows_dropped": .int(Int64(rendering.rowsDropped)),
                "controls_dropped": .int(Int64(rendering.controlsDropped)),
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

        let matchingControls = screen.controls.filter { matches(needle, $0.label.display, kind: $0.kind) }
        let matchingRows = screen.contents.flatMap { content in
            content.rows.enumerated().filter { matches(needle, $0.element.label?.display, kind: nil) }
                .map { $0.offset + 1 }
        }

        if !matchingControls.isEmpty, matchingRows.isEmpty {
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
                totalControls: matchingControls.count,
                unlabeledControls: [:],
                values: screen.values,
                totalValues: screen.totalValues
            )
            return Zoom(
                screen: scoped,
                options: options,
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
        let needle = normalize(stripRoleWords(target))
        guard !needle.isEmpty || hint != nil else { return .none(nearest: nearest(to: "", among: targets)) }

        func narrow(_ candidates: [ActTarget]) -> Resolution? {
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
        let normalizedTarget = normalize(target)
        if let hit = narrow(targets.filter { candidate in
            candidate.aliases.contains { normalize($0) == normalizedTarget }
        }) {
            return hit
        }

        // 1. exact
        if let hit = narrow(targets.filter { normalize($0.label ?? "") == needle && !needle.isEmpty }) {
            return hit
        }
        // 2. contains
        let contains = targets.filter { candidate in
            guard !needle.isEmpty, let label = candidate.label else { return false }
            let normalized = normalize(label)
            return !normalized.isEmpty && (normalized.contains(needle) || needle.contains(normalized))
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
            return (candidate.ordinal.map { "row \($0) \"\(label)\"" } ?? "\"\(label)\"", score)
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

    static let ordinalNouns: Set<String> = ["row", "item", "cell", "line", "no", "number", "#"]

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

    static func parseVerb(_ raw: String) -> (String, MacActScrollDirection) {
        let words = normalize(raw).split(separator: " ").map(String.init)
        let head = words.first ?? ""
        let direction: MacActScrollDirection = words.contains("up") ? .up : .down
        return (head, direction)
    }

    static func pastTense(_ verb: MacActVerb, direction: MacActScrollDirection) -> String {
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

    static func attempted(_ verb: MacActVerb, direction: MacActScrollDirection) -> String {
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

    /// Natural spatial qualifiers turn one visible region into useful aim
    /// points without exposing coordinates. Quarter-points leave a margin so
    /// "right side" does not accidentally target a resize edge.
    static func aimPoint(in frame: MacAXFrame, describedBy phrase: String) -> (x: Double, y: Double) {
        let words = Set(normalize(phrase).split(separator: " ").map(String.init))
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

        return MacScreenRender.Screen(
            appName: screen.appName,
            windowTitle: screen.windowTitle,
            isFront: screen.isFront,
            otherWindows: screen.otherWindows,
            provenance: screen.provenance,
            modal: screen.modal,
            whereSteps: screen.whereSteps,
            contents: screen.contents + newContents,
            controls: screen.controls + newControls,
            totalControls: screen.totalControls + newControls.count,
            unlabeledControls: screen.unlabeledControls,
            values: screen.values + newValues,
            totalValues: screen.totalValues + newValues.count
        )
    }

    // MARK: - JSON primitives

    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    static func visionValueTexts(_ detail: [String: JSONValue]) -> Set<String>? {
        guard case .array(let values)? = detail["vision_value_text"] else { return nil }
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
