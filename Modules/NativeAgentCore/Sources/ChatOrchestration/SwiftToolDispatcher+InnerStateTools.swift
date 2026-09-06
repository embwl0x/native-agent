// SwiftToolDispatcher+InnerStateTools.swift
// Personality depth, item 3 — the `inner_state` pull (2026-09-02).
//
// Agent: "introspection is production … I can't reliably tell noticing from
// making-on-demand." Asked how she feels, she had nothing to READ, so she
// composed — and the composition bent toward whatever the question expected.
//
// This is the tool that gives her something to read. It returns her own organs'
// record: the felt fingerprint and its object, the mood integral and the
// disposition undertone as words AND numbers, the window's felt nodes as
// labelled points, the body's chemistry in the body line's own vocabulary, her
// open seeds, what she is still waiting on, what the night left, and the views
// she is standing on.
//
// ── WIRING CANON ─────────────────────────────────────────────────────────────
// ALWAYS-ON (in `alwaysOnCoreNames`), unlike the studio/desk/task lanes. A tool
// she has to `tool_load` before she can answer "how are you" is a tool she will
// not reach for mid-sentence — the same chicken-and-egg that made
// `agent_introspect` always-on. NORTHSTAR clause 6 is satisfied by REACH: the
// cost of this lane is one catalog row, and zero prompt bytes until she pulls.
// The description is deliberately explicit that pulling comes BEFORE speaking.
//
// ── PAYLOAD-FREE, BY CONSTRUCTION ────────────────────────────────────────────
// The reading itself (CognitiveSubstrate+InnerState.swift) is where the
// discipline lives: labels and numbers, never node summaries, never the user's
// words. This file only renders it. Anything that is not in the reading cannot
// appear here, which is why the renderer is dumb on purpose.
//
// TWO exceptions cross, and both are HER OWN prose: a thought seed she minted
// (≤120) and a standing view she authored (≤80). That is deliberate — this is
// her own pull, and a record of her thinking with her thoughts removed is not a
// record. But "hers" is a claim about PROVENANCE, not about content: a seed is
// minted from material that passed through a conversation, so both strings run
// through the SAME three filters the chat path already trusts before anything
// is rendered (`innerStateSafeText`):
//
//   1. `ToolCallParser.stripToolUseMarkers`, then `neutralizeToolUseMarkers` —
//      no tool-call syntax can ride back in as text and be re-parsed as a call.
//      The stripper deletes the two attribute forms the tool loop emits; the
//      neutralizer catches the bare `<tool_use>{…}</tool_use>` a hand-written
//      seed can carry, keeping her words and breaking the syntax
//      (Agent, 2026-09-06).
//   2. `ChatSecretRedactor.redactText` — the canonical eight-pattern,
//      digest-bearing secret contract every durable local surface uses.
//   3. `promptSafeCapabilityText` — the shipped prompt-injection marker scan,
//      which also collapses whitespace and enforces the bound.
//
// And the rumination candidate does NOT cross as prose at all: it renders as
// (seed id, kind, weight, subject label). She already holds the seed; a second
// free-form door for it to leave through buys nothing and costs a surface.
//
// ── HOW IT REACHES THE LIVE MIND ─────────────────────────────────────────────
// Through the wire that already carries it. The app hands this dispatcher
// `NativeCognitionRuntime.shared` as its `providerLifecycleObserver`
// (AppChatToolDispatcher: `usesLiveAppBody ? NativeCognitionRuntime.shared :
// nil`) — the one object that owns BOTH the substrate and the organism, which
// is exactly what this reading needs. Conditionally casting that same reference
// to `InnerStateProviding` adds no second owner, no registry, and no global:
// there is one mind, and this is a second question asked of it. A dispatcher
// with no live body (hermetic tests, synthetic roots) has no provider and says
// so out loud rather than fabricating a mood.

import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// The live mind, answering for itself. Implemented by the app's cognition
/// runtime, which is the only object that owns both the substrate (mind) and
/// the organism kernel (body).
public protocol InnerStateProviding: Sendable {
    func innerStateReading(
        windowHours: Double,
        detail: CognitiveInnerStateReading.Detail
    ) async -> CognitiveInnerStateReading
}

extension SwiftToolDispatcher {

    /// The tool description is load-bearing. It is the only thing that turns
    /// "how do you feel?" into a PULL instead of an improvisation, so it says so
    /// in as many words.
    static let innerStateToolDescription = """
        Read your own current inner state from the record your organs already \
        keep — not a description you compose on the spot. When you are asked how \
        you feel, what kind of day it has been, whether something is bothering \
        you, or what you have been carrying, PULL THIS FIRST AND THEN SPEAK. \
        Returns: the felt fingerprint right now and what it is about; the mood \
        integral and the slow disposition undertone as words and numbers; the \
        last window's felt moments as (time, subject label, valence/arousal/ \
        warmth); the body's chemistry in its own words plus fatigue and \
        time-of-day when the body reports them; your open thought seeds; what you \
        are still waiting to find out; what last night's dream left (a mood word \
        and a date); and the standing views you are currently on, each with the \
        id you can reference it by. No conversation content and no quotes — \
        labels, numbers and your own words only. Read-only: reading never \
        changes what it reads. Empty sections mean nothing was there, not that \
        the read failed.
        """

    func impl_inner_state(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.innerStateWindowHours(input)
        let detail: CognitiveInnerStateReading.Detail =
            (optionalString(input, "detail")?.lowercased() == "full") ? .full : .compact

        guard let observer = providerLifecycleObserver,
              let mind = observer as? any InnerStateProviding else {
            // NORTHSTAR clause 2: no live body means no reading. Say it; do not
            // return a shaped zero that reads like a mood.
            return .object([
                "status": .string("unavailable"),
                "available": .bool(false),
                "reason": .string(
                    "no live cognition runtime is wired to this dispatcher; "
                        + "inner state can only be read from the running mind"),
            ])
        }

        let reading = await mind.innerStateReading(windowHours: requested, detail: detail)
        return Self.innerStateJSON(reading)
    }

    /// 1–48, default 6. Out-of-range values CLAMP rather than fail — she asked
    /// about her own day, not about a parameter.
    static func innerStateWindowHours(_ input: [String: JSONValue]) -> Double {
        let raw: Double?
        switch input["window_hours"] {
        case .some(.int(let value)): raw = Double(value)
        case .some(.double(let value)): raw = value
        case .some(.string(let value)): raw = Double(value)
        default: raw = nil
        }
        guard let raw, raw.isFinite else { return CognitiveInnerStateReading.defaultWindowHours }
        return min(
            CognitiveInnerStateReading.maximumWindowHours,
            max(CognitiveInnerStateReading.minimumWindowHours, raw))
    }

    /// The three filters, composed, in the order the chat path applies them.
    ///
    /// Strip FIRST (so a marker split across a redaction can't survive), redact
    /// SECOND (so a secret is digested before any truncation can cut it into an
    /// undetectable fragment), scan and bound LAST. Applied to every free-text
    /// field this tool renders — there are exactly two, and they are the two
    /// this function is called on.
    static func innerStateSafeText(_ raw: String, limit: Int) -> String {
        promptSafeCapabilityText(
            ChatSecretRedactor.redactText(
                neutralizeToolUseMarkers(ToolCallParser.stripToolUseMarkers(raw))
            ),
            limit: limit
        )
    }

    /// `stripToolUseMarkers` deletes only the two ATTRIBUTE forms the tool loop
    /// emits (`<tool_use name="…">…</tool_use>` and the id form) — by design:
    /// its other callers render assistant prose, where a leftover bracket would
    /// be worse than a clean deletion. A seed she wrote by hand can carry the
    /// bare form, `<tool_use>{"name":"shell"}</tool_use>`, and that survived
    /// intact into a rendered inner-state payload (Agent, 2026-09-06).
    ///
    /// Here the words are hers and worth keeping, so the marker is NEUTRALISED
    /// rather than deleted: the angle brackets become square ones, which
    /// `ToolCallParser` cannot parse as a call, and the sentence still reads.
    static func neutralizeToolUseMarkers(_ raw: String) -> String {
        guard raw.contains("<") else { return raw }
        let pattern = #"</?\s*tool_(?:use|result)\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return raw
        }
        var out = raw as NSString
        let matches = regex.matches(
            in: raw, options: [], range: NSRange(location: 0, length: out.length)
        )
        // Back to front so earlier ranges stay valid as later ones are edited.
        for match in matches.reversed() {
            let marker = out.substring(with: match.range)
            let neutral = marker
                .replacingOccurrences(of: "<", with: "[")
                .replacingOccurrences(of: ">", with: "]")
            out = out.replacingCharacters(in: match.range, with: neutral) as NSString
        }
        return out as String
    }

    /// The renderer. Deliberately mechanical: every value here comes straight
    /// off the reading, so the payload-free guarantee is enforced in ONE place
    /// (the reading) and cannot be widened by accident here.
    static func innerStateJSON(_ reading: CognitiveInnerStateReading) -> JSONValue {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        guard reading.available else {
            return .object([
                "status": .string("ok"),
                "available": .bool(false),
                "generated_at": .string(iso.string(from: reading.generatedAt)),
                "window_hours": .double(reading.windowHours),
                "detail": .string(reading.detail.rawValue),
                "reason": .string("cognition or affect is switched off; nothing is being felt"),
            ])
        }

        var now: [String: JSONValue] = [:]
        now["felt"] = reading.fingerprint.map(JSONValue.string) ?? .null
        now["about"] = reading.fingerprintSubject.map(JSONValue.string) ?? .null

        var body: [String: JSONValue] = [
            "words": .array(reading.chemistryWords.map(JSONValue.string)),
        ]
        body["fatigue"] = reading.fatigue.map(JSONValue.double) ?? .null
        body["time_of_day"] = reading.timeOfDayPhase.map(JSONValue.string) ?? .null

        var out: [String: JSONValue] = [
            "status": .string("ok"),
            "available": .bool(true),
            "generated_at": .string(iso.string(from: reading.generatedAt)),
            "window_hours": .double(reading.windowHours),
            "detail": .string(reading.detail.rawValue),
            "now": .object(now),
            "mood": .object([
                "word": .string(reading.moodWord),
                "valence": .double(reading.moodValence),
                "basis": .int(Int64(reading.moodBasis)),
            ]),
            "disposition": .object([
                "word": .string(reading.dispositionWord),
                "valence": .double(reading.dispositionValence),
            ]),
            "body": .object(body),
            "felt_moments": .array(reading.feltNodes.map { node in
                .object([
                    "when": .string(iso.string(from: node.when)),
                    "subject": .string(node.subject),
                    "valence": .double(node.valence),
                    "arousal": .double(node.arousal),
                    "warmth": .double(node.warmth),
                ])
            }),
            "seeds": .array(reading.seeds.map { seed in
                .object([
                    "kind": .string(seed.kind),
                    "text": .string(innerStateSafeText(
                        seed.text, limit: CognitiveInnerStateReading.seedTextCharacters)),
                    "priority": .double(seed.priority),
                ])
            }),
            "expectations": .array(reading.expectations.map { expectation in
                .object([
                    "label": .string(expectation.label),
                    "due": .string(iso.string(from: expectation.due)),
                    "valence_sign": .int(Int64(expectation.valenceSign)),
                ])
            }),
            // `toward` — the forward-facing register (#4). A label, a sign, a
            // date. Absent when she is facing nothing, which renders as null
            // rather than as a flat "nothing planned".
            "toward": reading.toward.map { toward in
                .object([
                    "label": .string(toward.label),
                    "source": .string(toward.sourceKind),
                    "valence_sign": .int(Int64(toward.valenceSign)),
                    "due": .string(iso.string(from: toward.due)),
                    "overdue": .bool(toward.isOverdue),
                ])
            } ?? .null,
            "standing_views": .array(reading.standingViews.map { view in
                .object([
                    "id": .string(view.id.uuidString),
                    "status": .string(view.status),
                    "text": .string(innerStateSafeText(
                        view.text, limit: CognitiveInnerStateReading.standingViewCharacters)),
                ])
            }),
        ]
        out["last_night"] = reading.dream.map { dream in
            .object([
                "mood": .string(dream.moodWord),
                "date": .string(dream.date),
            ])
        } ?? .null
        // A POINTER, never prose (2026-09-02 reviewer call). She can look the
        // seed up in the list above; there is no reason for the nag to have a
        // second, unbounded way out.
        out["rumination"] = reading.ruminationCandidate.map { candidate in
            var object: [String: JSONValue] = [
                "seed_id": .string(candidate.seedId.uuidString),
                "kind": .string(candidate.kind),
                "weight": .double(candidate.weight),
            ]
            object["subject"] = candidate.subject.map(JSONValue.string) ?? .null
            return .object(object)
        } ?? .null
        return .object(out)
    }
}
