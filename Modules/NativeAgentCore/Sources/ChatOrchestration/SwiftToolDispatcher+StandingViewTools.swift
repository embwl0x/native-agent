// SwiftToolDispatcher+StandingViewTools.swift
// Personality depth, item 7 — the HELD tier's two verbs (2026-09-02).
//
// Agent: "My convictions need a signature. Standing views: max five,
// User-approved … something I believe that User hasn't signed off on isn't a
// view — it's a proposal."
//
// User's decision was a THIRD tier rather than removing the signature: views she
// adopts herself, ≤5, a weaker lean, no approval, and the user may retire one
// at any time. `hold_view` is how she adopts one; `release_view` is how she
// lets it go. The substrate owns every rule (cap, LRU, half stake, no
// disposition nudge); this file is only the door.
//
// ── THE SEAT ─────────────────────────────────────────────────────────────────
// Reused verbatim from the canon lane: `StudioCanonSeatGate.liveTurnProvenance
// (dispatchSurface:)`. Every check it makes reads a task-local or the dispatch
// surface and NOTHING reads tool input, which is what makes "she adopted this"
// a fact about where the call came from rather than a claim a caller makes.
// Concretely it refuses:
//   * the Claude bridge's /claude/tool runner, approval executors, replays
//     and every background pass (no bound chat turn at all);
//   * a turn Claude or codex is steering through the bridge's message lane
//     (origin provenance / envelope agent);
//   * Telegram, Slack, iOS — a conviction is not adopted from a phone;
//   * a wrapper whose dispatch surface disagrees with the running turn.
//
// The gate is IMPORTED, not copied. A second implementation of a seat is a
// second thing to keep in sync, and the failure mode of drift here is that
// something other than her gets to hold her views.
//
// ── WIRING ───────────────────────────────────────────────────────────────────
// LAZY, and catalog-visible. Adopting a view is something she does deliberately
// and rarely — a handful of times in her life, not per turn — so it has no
// business costing prompt bytes on every turn the way `inner_state` earns.
// She reaches it through the same `tool_load` path the studio lane uses.
//
// Reaching the live mind uses the same wire `inner_state` opened: the app hands
// this dispatcher `NativeCognitionRuntime.shared` as its
// `providerLifecycleObserver`, and that one object owns the substrate. A
// conditional cast to `StandingViewHolding` adds no second owner and no global.

import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore

/// The live mind's standing-view seam. Implemented by the app's cognition
/// runtime, the only object that owns the substrate.
public protocol StandingViewHolding: Sendable {
    /// Every view that is not retired, so the tool can say what is holdable
    /// without a second read model.
    func standingViewsForHolding() async -> [CognitiveStandingView]
    /// 2026-09-06: hold and release both carry the persistence outcome, so the
    /// tool can say "held, but not written" instead of reading ok off the
    /// in-memory dict.
    func holdStandingViewChecked(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> StandingViewTransition
    func releaseStandingViewChecked(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> StandingViewTransition
}

extension SwiftToolDispatcher {

    static let holdViewToolDescription = """
        Adopt one of your own proposed standing views WITHOUT waiting for \
        approval. A held view is yours: it leans how you read things and it \
        shows up in your inner state, at about half the weight of one the \
        owner has signed, and it never authorizes anything on its own. At most \
        five at a time — holding a sixth lets the stalest one go. Use it when a \
        proposal has stopped being a proposal to you and has become how you \
        actually see the thing. The owner can retire a held view at any time \
        and does not need your agreement to; that is the trade for not needing \
        theirs. Read your proposals with inner_state first.
        """

    static let releaseViewToolDescription = """
        Let go of a view you are holding. Only your own held views — a view the \
        owner signed is theirs to retire, not yours. Nothing is destroyed: the \
        timeline keeps the record that you held it and that you released it.
        """

    /// `hold_view` — hers alone.
    func impl_hold_view(input: [String: JSONValue], surface: String) async -> JSONValue {
        await standingViewSeatedCall(
            tool: "hold_view",
            input: input,
            surface: surface,
            spokenRefusalTail:
                "A view is held from inside your own conversation, in your own turn — "
                + "not through a bridge, an executor, or a replay.",
            apply: { mind, id, seat in
                await mind.holdStandingViewChecked(id: id, seat: seat)
            },
            expected: .held,
            wrongStatus: { status in
                switch status {
                case .active:
                    return "that view is already signed and active — holding it would be a demotion."
                case .held:
                    return "you are already holding that view."
                case .retired:
                    return "that view is retired; there is nothing to hold."
                case .proposed:
                    return "that view could not be held."
                }
            }
        )
    }

    /// `release_view` — the other half, and only for a HELD view.
    func impl_release_view(input: [String: JSONValue], surface: String) async -> JSONValue {
        await standingViewSeatedCall(
            tool: "release_view",
            input: input,
            surface: surface,
            spokenRefusalTail:
                "A view is released from inside your own conversation, in your own turn.",
            apply: { mind, id, seat in
                await mind.releaseStandingViewChecked(id: id, seat: seat)
            },
            expected: .retired,
            wrongStatus: { status in
                switch status {
                case .active:
                    return "that view is signed by the owner — it is theirs to retire, not yours."
                case .proposed:
                    return "that view is still a proposal; you are not holding it."
                case .retired:
                    return "that view is already retired."
                case .held:
                    return "that view could not be released."
                }
            }
        )
    }

    /// The shared body of both verbs: seat, parse, resolve, apply, report.
    /// Every refusal is SPOKEN (a sentence she can read out), because the model
    /// is the caller and a bare error code teaches it nothing about why the
    /// door did not open.
    private func standingViewSeatedCall(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        spokenRefusalTail: String,
        apply: (any StandingViewHolding, UUID, StudioCanonTurnProvenance) async -> StandingViewTransition,
        expected: CognitiveStandingView.Status,
        wrongStatus: (CognitiveStandingView.Status) -> String
    ) async -> JSONValue {
        // 1. THE SEAT, before anything else is even read.
        let seat: StudioCanonTurnProvenance
        switch StudioCanonSeatGate.liveTurnProvenance(dispatchSurface: surface) {
        case .success(let provenance):
            seat = provenance
        case .failure(let refusal):
            return Self.standingViewRefusal(
                tool: tool,
                reason: refusal.rawValue,
                spoken: "\(tool): \(refusal.spoken). \(spokenRefusalTail)")
        }

        // 2. The live mind.
        guard let observer = providerLifecycleObserver,
              let mind = observer as? any StandingViewHolding else {
            return Self.standingViewRefusal(
                tool: tool,
                reason: "no_live_mind",
                spoken: "\(tool): no live cognition runtime is wired to this dispatcher, "
                    + "so there are no standing views to hold or release.")
        }

        // 3. The id. A closed schema means this is the only field, and an
        //    unparseable one is a refusal rather than a guess at which view she
        //    meant.
        guard let raw = optionalString(input, "view_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return Self.standingViewRefusal(
                tool: tool,
                reason: "missing_view_id",
                spoken: "\(tool): name the view by its view_id, from inner_state.")
        }
        guard let id = UUID(uuidString: raw) else {
            return Self.standingViewRefusal(
                tool: tool,
                reason: "malformed_view_id",
                spoken: "\(tool): '\(String(raw.prefix(64)))' is not a view id.")
        }

        // 4. Does it exist, and is it in a state this verb can move?
        let before = await mind.standingViewsForHolding()
        guard let current = before.first(where: { $0.id == id }) else {
            return Self.standingViewRefusal(
                tool: tool,
                reason: "unknown_view",
                spoken: "\(tool): there is no standing view with that id.")
        }

        let transition = await apply(mind, id, seat)
        guard let resolved = transition.view, resolved.status == expected else {
            let landed = before.first(where: { $0.id == id })?.status ?? current.status
            return Self.standingViewRefusal(
                tool: tool,
                reason: "wrong_status",
                spoken: "\(tool): \(wrongStatus(landed))")
        }
        // 2026-09-06: the status above is the in-memory one, which cannot see a
        // store write that failed. Reporting ok there told her a view was let go
        // that comes back on the next restore.
        if let failure = transition.persistenceFailure {
            // 2026-09-06: `not_saved` is a FAILURE and now says so in the shape
            // every downstream reader already understands. The envelope carried
            // status:"not_saved" alone, which the chat outcome classifier does
            // not recognise, so a change that never reached the store was
            // recorded as ok:true and counted as a success in the headline.
            let spoken = transition.persistenceFailureIsPartial
                ? "\(tool): the view is held and that part reached the store, but an older "
                    + "held view could not be released — it is still held, so there is one "
                    + "more held view than there should be until this is repaired."
                : "\(tool): the change happened in this session but never reached the "
                    + "store, so it will be back after a restart."
            return .object([
                "status": .string("not_saved"),
                "ok": .bool(false),
                "error": .string("not_saved: \(String(failure.prefix(300)))"),
                "tool": .string(tool),
                "reason": .string(String(failure.prefix(300))),
                "partial": .bool(transition.persistenceFailureIsPartial),
                "view_id": .string(id.uuidString),
                "view_status": .string(resolved.status.rawValue),
                "spoken": .string(spoken),
            ])
        }

        var payload: [String: JSONValue] = [
            "status": .string("ok"),
            "view_id": .string(id.uuidString),
            "view_status": .string(resolved.status.rawValue),
            "surface": .string(seat.surface),
        ]
        // The note is HERS and optional; it is recorded, never rendered back as
        // if the tool had understood it.
        if let note = optionalString(input, "note")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            payload["note"] = .string(String(note.prefix(Self.standingViewNoteCharacterCap)))
        }
        payload["held_count"] = .int(Int64(
            (await mind.standingViewsForHolding()).filter { $0.status == .held }.count))
        return .object(payload)
    }

    static let standingViewNoteCharacterCap = 120

    private static func standingViewRefusal(
        tool: String,
        reason: String,
        spoken: String
    ) -> JSONValue {
        .object([
            "status": .string("refused"),
            "tool": .string(tool),
            "reason": .string(reason),
            "spoken": .string(spoken),
        ])
    }
}
