import ChatToolParsing
// SwiftToolDispatcher+InnerStateTools.swift
// The `inner_state` pull: read the recorded state before speaking about it.
//
// This is the tool that gives her something to read. It returns her own organs'
// record: the felt fingerprint and its object, the mood integral and the
// disposition undertone as words AND numbers, the window's felt nodes as
// labelled points, the body's chemistry in the body line's own vocabulary,
// what she is still waiting on, what the night left, and her cares.
//
// ── PAYLOAD-FREE, BY CONSTRUCTION ────────────────────────────────────────────
// The reading itself (CognitiveSubstrate+InnerState.swift) is where the
// discipline lives: labels and numbers, never node summaries, never the user's
// words. This file only renders it. Anything that is not in the reading cannot
// appear here, which is why the renderer is dumb on purpose.
//
// Her own prose crosses through her cares. This is
// her own pull, and a record of her thinking with her thoughts removed is not a
// record. But "hers" is a claim about PROVENANCE, not about content: her cares
// may come from material that passed through a conversation, so their words run
// through the SAME three filters the chat path already trusts before anything
// is rendered (`innerStateSafeText`):
//
//   1. `ToolCallParser.stripToolUseMarkers`, then `neutralizeToolUseMarkers` —
//      no tool-call syntax can ride back in as text and be re-parsed as a call.
//      The stripper deletes the two attribute forms the tool loop emits; the
//      neutralizer catches the bare `<tool_use>{…}</tool_use>` a hand-written
//      care can carry, keeping her words and breaking the syntax.
//   2. `ChatSecretRedactor.redactText` — the shared credential patterns,
//      digest-bearing secret contract every durable local surface uses.
//   3. `promptSafeCapabilityText` — the shipped prompt-injection marker scan,
//      which also collapses whitespace and enforces the bound.
//
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |

/// The live mind, answering for itself. Implemented by the app's cognition
/// runtime, which is the only object that owns both the substrate (mind) and
/// the organism kernel (body).
public protocol InnerStateProviding: Sendable {
    func innerStateReading(
        windowHours: Double,
        detail: CognitiveInnerStateReading.Detail,
        surface: String
    ) async -> CognitiveInnerStateReading
}

extension SwiftToolDispatcher {

    func impl_inner_state(input: [String: JSONValue], surface: String) async -> JSONValue {
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

        let reading = await mind.innerStateReading(windowHours: requested, detail: detail, surface: surface)
        return Self.innerStateJSON(reading, requestedWindowHours: Self.innerStateRawWindowHours(input))
    }

    /// Return the finite requested window, or nil if absent or invalid, so results can disclose clamping.
    static func innerStateRawWindowHours(_ input: [String: JSONValue]) -> Double? {
        let raw: Double?
        switch input["window_hours"] {
        case .some(.int(let value)): raw = Double(value)
        case .some(.double(let value)): raw = value
        case .some(.string(let value)): raw = Double(value)
        default: raw = nil
        }
        guard let raw, raw.isFinite else { return nil }
        return raw
    }


    /// 1–168, default 6. Out-of-range values CLAMP rather than fail — she asked
    /// about her own week, not about a parameter.
    static func innerStateWindowHours(_ input: [String: JSONValue]) -> Double {
        guard let raw = Self.innerStateRawWindowHours(input) else {
            return CognitiveInnerStateReading.defaultWindowHours
        }
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

    /// Square brackets preserve care prose while making bare tool markers unparseable as calls.
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
    static func innerStateJSON(
        _ reading: CognitiveInnerStateReading,
        requestedWindowHours: Double? = nil
    ) -> JSONValue {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let window = innerStateWindowFields(
            requested: requestedWindowHours, applied: reading.windowHours)

        guard reading.available else {
            return .object([
                "status": .string("ok"),
                "available": .bool(false),
                "generated_at": .string(iso.string(from: reading.generatedAt)),
                "detail": .string(reading.detail.rawValue),
                "reason": .string("cognition or affect is switched off; nothing is being felt"),
            ].merging(window) { current, _ in current })
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
                    // Age beside the timestamp distinguishes past moments from the present.
                    "age_hours": .double(
                        (reading.generatedAt.timeIntervalSince(node.when) / 3600 * 10).rounded() / 10),
                    // Which list it came from: `felt` = among the window's
                    // strongest, `recent` = among the newest. Different claims.
                    "selection": .string(node.selection.rawValue),
                    "subject": .string(node.subject),
                    "valence": .double(node.valence),
                    "arousal": .double(node.arousal),
                    "warmth": .double(node.warmth),
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
        ]
        // What she cares about, most charged first: her words, its depth,
        // whom it is held with, the newest feeling and the gap still open.
        out["cares"] = .array(reading.cares.map { care in
            .object([
                "id": .string(care.id.uuidString),
                "about": .string(innerStateSafeText(care.about, limit: CognitiveCare.aboutCharacters)),
                "depth": .string(care.depth),
                "with": .array(care.with.map(JSONValue.string)),
                "felt": care.felt.map { .string(innerStateSafeText($0, limit: CognitiveCare.feltCharacters)) } ?? .null,
                "charge": .double((care.charge * 100).rounded() / 100),
                "open": care.open.map { .string(innerStateSafeText($0, limit: CognitiveCare.openCharacters)) } ?? .null,
                "stance": care.stance.map { .string(innerStateSafeText($0, limit: CognitiveCare.stanceCharacters)) } ?? .null,
                "because": care.because.map { .string(innerStateSafeText($0, limit: CognitiveCare.stanceCharacters)) } ?? .null,
                "would_change_mind": care.wouldChangeMind.map { .string(innerStateSafeText($0, limit: CognitiveCare.stanceCharacters)) } ?? .null,
            ])
        })
        if reading.detail == .full {
            let lines = reading.growthWeek.isEmpty
                ? ["No changes recorded in the last 7 days."]
                : reading.growthWeek
            out["growth_week"] = .array(lines.map(JSONValue.string))
            // Her story: how her cares changed depth and what her nights settled.
            out["story"] = .array(reading.story.map { .string(innerStateSafeText($0, limit: 400)) })
        }
        out["last_night"] = reading.dream.map { dream in
            .object([
                "mood": .string(dream.moodWord),
                "date": .string(dream.date),
            ])
        } ?? .null
        for (key, value) in window { out[key] = value }
        return .object(out)
    }

    /// The window, said out loud: what was asked for, what was used, and — only
    /// when they differ — one line naming the cap that made the difference.
    ///
    /// `window_hours` keeps its meaning (the window ACTUALLY used) so every
    /// existing reader is unchanged; the two new keys are what turn a silent
    /// clamp into a stated one.
    static func innerStateWindowFields(
        requested: Double?, applied: Double
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "window_hours": .double(applied),
            "window_hours_requested": .double(requested ?? applied),
            "window_hours_applied": .double(applied),
        ]
        guard let requested, requested != applied else { return fields }
        let maximum = CognitiveInnerStateReading.maximumWindowHours
        let minimum = CognitiveInnerStateReading.minimumWindowHours
        let bound = requested > maximum
            ? "the maximum window is \(Self.innerStateHours(maximum)) hours"
            : "the minimum window is \(Self.innerStateHours(minimum)) hour"
        fields["window_hours_note"] = .string(
            "you asked for \(Self.innerStateHours(requested)) hours; \(bound), "
                + "so this reading covers the last \(Self.innerStateHours(applied)) hours "
                + "and says nothing about anything older")
        return fields
    }

    /// Whole numbers read as whole numbers: "168", not "168.0".
    static func innerStateHours(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(value)
    }
}
