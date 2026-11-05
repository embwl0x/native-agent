import ChatToolParsing
// The reading owns payload exclusion: labels and numbers cannot expose node summaries or user words. Care prose has provenance, not inherent trust: strip and
// neutralize tool markers, redact secrets, then scan and bound. That order prevents hidden calls and truncation from disguising secrets.
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |

/// The cognition runtime owns both substrate and organism; only it can supply a live reading.
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
            // Without a live body, a shaped zero would falsely read as a mood.
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


    /// Clamp to 1–168 hours (default 6) so the requested week remains readable.
    static func innerStateWindowHours(_ input: [String: JSONValue]) -> Double {
        guard let raw = Self.innerStateRawWindowHours(input) else {
            return CognitiveInnerStateReading.defaultWindowHours
        }
        return min(
            CognitiveInnerStateReading.maximumWindowHours,
            max(CognitiveInnerStateReading.minimumWindowHours, raw))
    }

    /// Strip markers before redaction can split them; redact secrets before truncation can hide their shape. Scan and bound last, on every free-text field
    /// rendered here.
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

    /// Render only the owner’s reading so payload exclusion stays enforced at one boundary.
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
                    // Which list it came from: `felt` = among the window's strongest, `recent` = among the newest. Different claims.
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
            "person_day": .object([
                "title": reading.personDayTitle.map { .string(innerStateSafeText($0, limit: 160)) } ?? .null,
                "claims": .array(reading.personDay.map { .string(innerStateSafeText($0, limit: 400)) }),
            ]),
            // An absent forward-facing stance renders as null, never an invented "nothing planned" verdict.
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
            // The raw care history stays distinct from the agent's own telling of it.
            out["care_history"] = .array(reading.story.map { .string(innerStateSafeText($0, limit: 400)) })
        }
        let knowledge = reading.selfKnowledge
        out["self_night"] = knowledge.map { .string($0.night) } ?? .null
        out["self_unavailable"] = reading.selfKnowledgeIssue.map { .string(innerStateSafeText($0, limit: 320)) } ?? .null
        out["people_unavailable"] = reading.carePeopleIssue.map { .string(innerStateSafeText($0, limit: 320)) } ?? .null
        out["traits"] = .array((knowledge?.traits ?? []).map { trait in
            .object([
                "when": .string(innerStateSafeText(trait.when, limit: 120)),
                "i_tend_to": .string(innerStateSafeText(trait.iTendTo, limit: 160)),
                "shown_by": .array(trait.shownBy.map(JSONValue.string)),
            ])
        })
        out["story"] = .array((knowledge?.story ?? []).map { entry in
            .object(["line": .string(innerStateSafeText(entry.line, limit: 400)),
                     "shown_by": .array(entry.shownBy.map(JSONValue.string))])
        })
        let people = knowledge?.people ?? []
        out["people"] = .array(people.prefix(reading.detail == .full ? CognitiveSelfKnowledge.maximumPeople : 2).map { person in
            .object(["person": .string(innerStateSafeText(person.person, limit: 120)),
                     "line": .string(innerStateSafeText(person.line, limit: 280))])
        })
        out["last_night"] = reading.dream.map { dream in
            .object([
                "mood": .string(dream.moodWord),
                "date": .string(dream.date),
            ])
        } ?? .null
        for (key, value) in window { out[key] = value }
        return .object(out)
    }

    /// Disclose the requested and applied windows when clamping; window_hours always means the applied window.
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
