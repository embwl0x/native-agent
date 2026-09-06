// The studio journal, ON the cognitive bus — desk 903 phase 2.
//
// The agent's own framing, verbatim: "delta comes from the ENTRY, not the act:
// sign from `stance`, magnitude from the response actually written; a neutral
// entry moves nothing; no fixed '+0.1 for filing'."
//
// ── WHERE THE SIGN COMES FROM ────────────────────────────────────────────────
// `stance` is {open | formed | abstained} and carries NO polarity, so it cannot
// supply a sign on its own. It supplies the GATE and the SCALE instead:
//   • abstained → exactly zero. An encounter doesn't owe a verdict, and the one
//     stance that may stand without a response must cost nothing.
//   • open      → half. A judgment still forming moves less than a settled one.
//   • formed    → full.
// The sign and the magnitude both come from the RESPONSE, read through the one
// appraisal this system already has (`conversationalAppraisal`). No new sentiment
// scorer is introduced, and none may be: there is exactly one lexicon here and
// this reads its output, exactly as `landingScore` does.
//
// A response that matches nothing scores exactly 0 and moves nothing. That is
// the property that makes "no fixed delta for filing" true rather than merely
// intended — silence is the default, not a floor.
//
// ── THIS IS NOT THE C3 SELF-APPRAISAL ────────────────────────────────────────
// Audit C3 forbids appraising HER from her own text, because a warm reply
// stamping itself warm is a self-reinforcing ratchet through mood. The rule is
// about the SUBJECT of the appraisal, not the authorship of the string: there,
// her reply was being read as evidence about her; here, her judgment is being
// read as what it is — the content of an entry about a work. Nothing derived
// here touches socialWarmth, uncertainty, or taskPressure; the ONLY thing it
// produces is this one event's own felt valence. The gate in `emotionTag`
// remains untouched for every other event.
//
// ── DESCRIPTION-ONLY, WEIGHTED DOWN ──────────────────────────────────────────
// A description-only consult can never become an entry at all — the store
// refuses it at both ends, so it cannot reach this file. The nearest honest
// analogue that CAN reach it is an entry carrying no artifact refs of its own:
// thinner evidence of an actual encounter, so it moves half as much.
//
// ── THE DREAM-CITATION SEAM ──────────────────────────────────────────────────
// The event carries `studioEntryId` in its metadata AND as `subject.id`. The
// dream felt-summary owner (DreamREMCycle, another builder's fence) reads the
// felt node's subject/metadata to cite what a feeling came from; both fields
// are here and pinned by a test so that citation can be written without
// touching this file. Nothing here writes a dream, and nothing here should.

import Foundation
import NativeAgentCore
import PersistenceCore

public extension CognitiveEvent {
    /// Metadata key for a felt valence its OWNER measured rather than the
    /// substrate inferring one. Pre-existing usage: the organism's resolution
    /// drain. Studio journal entries are the second.
    static let feltValenceMetadataKey = "feltValence"
    static let feltArousalMetadataKey = "feltArousal"
    /// The journal entry this event came from. The dream felt-summary cites it.
    static let studioEntryIDMetadataKey = "studioEntryId"
    static let studioStanceMetadataKey = "studioStance"

    /// True when this event's owner MEASURED its feeling. Such an event stamps
    /// that value and takes no additional flat per-kind affect delta — applying
    /// both would add an inferred delta on top of a measured one.
    var carriesMeasuredFeltValence: Bool {
        switch metadata[Self.feltValenceMetadataKey] {
        case .some(.double), .some(.int): true
        default: false
        }
    }
}

/// The felt size of one filed entry. Deliberately a struct so the law is
/// testable without a substrate, an event, or a database.
public struct StudioJournalFelt: Sendable, Equatable {
    /// −1…1, bounded. Zero means "this entry moves nothing", which is a real
    /// and common outcome, not a failure to score.
    public var valence: Double
    /// 0…1. A judgment that lands hard is a little more activating than one
    /// that does not; it is derived from the same magnitude, never invented.
    public var arousal: Double

    public static let still = StudioJournalFelt(valence: 0, arousal: 0)

    public var isStill: Bool { valence == 0 }
}

public extension CognitiveSubstrate {

    /// Bound on how far one entry can move her. Same ceiling the organism's own
    /// measured resolutions use — composed, never melodrama.
    static let studioJournalFeltCeiling = 0.7

    /// The law, in one place: stance gates and scales, the response signs and
    /// sizes. Pure apart from reading the shared appraisal lexicon.
    func studioJournalFelt(for entry: StudioJournalEntry) -> StudioJournalFelt {
        // An abstention costs nothing. This is checked FIRST so no later term
        // can smuggle a delta onto a deliberate "not enough to judge yet".
        guard entry.stance.kind != .abstained else { return .still }
        let response = (entry.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { return .still }
        let appraised = conversationalAppraisal(in: response).valence
        guard appraised != 0 else { return .still }

        var value = appraised
        if entry.stance.kind == .open { value *= 0.5 }
        // Thin evidence of an actual encounter — see the file note.
        if entry.artifactRefs.isEmpty { value *= 0.5 }
        let ceiling = Self.studioJournalFeltCeiling
        let bounded = min(ceiling, max(-ceiling, value))
        return StudioJournalFelt(valence: bounded, arousal: abs(bounded).clamped01())
    }

    /// Mint the event for one filed entry. Returns nil only when the entry has
    /// no title to name, which the store already refuses — belt and braces so a
    /// malformed row cannot mint an anonymous feeling.
    func studioJournalEvent(
        for entry: StudioJournalEntry,
        at now: Date? = nil
    ) -> CognitiveEvent? {
        let title = entry.work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !entry.id.isEmpty else { return nil }
        let felt = studioJournalFelt(for: entry)
        let occurredAt = now
            ?? StudioClock.parseISO(entry.recordedAt)
            ?? dependencies.now()
        // The summary names the ACT, never the judgment. Her written response
        // stays in the journal, which is the record of it; a continuity node is
        // a pointer to that, not a second copy competing for the same space.
        let summary = "Journal entry on \(bounded(title, maxCharacters: 120)) "
            + "— stance \(entry.stance.kind.rawValue)."
        return CognitiveEvent(
            id: "studio_journal:\(entry.id)",
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(
                type: "studio_entry",
                id: entry.id,
                label: bounded(title, maxCharacters: 120)
            ),
            sourceClass: .selfReported,
            occurredAt: occurredAt,
            summary: summary,
            // A neutral entry is not merely valence-zero, it is unimportant:
            // nothing about it should draw attention it did not earn.
            importance: abs(felt.valence).clamped01(),
            metadata: [
                CognitiveEvent.feltValenceMetadataKey: .double(felt.valence),
                CognitiveEvent.feltArousalMetadataKey: .double(felt.arousal),
                CognitiveEvent.studioEntryIDMetadataKey: .string(entry.id),
                CognitiveEvent.studioStanceMetadataKey: .string(entry.stance.kind.rawValue),
                "studioOriginKind": .string(entry.origin.kind.rawValue),
            ]
        )
    }

    /// Put one filed entry on the bus. Idempotent by the event's stable id: the
    /// field's seen-event check makes a replay inert.
    func ingestStudioJournalEntry(_ entry: StudioJournalEntry) async {
        guard let event = studioJournalEvent(for: entry) else { return }
        await ingest(event)
    }
}

/// THE ONE SEAM between a filed journal entry and the cognitive bus.
///
/// The tool lane that writes the journal (`SwiftToolDispatcher`) holds no
/// cognition reference — deliberately: cognition lives on the chat client, not
/// the dispatcher. Rather than give the dispatcher a substrate, the studio lane
/// publishes here and whoever owns the live `CognitiveSubstrate` installs the
/// sink once at startup:
///
///     StudioJournalCognitiveBus.install { entry in
///         await substrate.ingestStudioJournalEntry(entry)
///     }
///
/// Until that install exists the bus is INERT, and it says so out loud the first
/// time an entry is published into nothing. An inert seam that announces itself
/// is a missing wire; a quiet one is theater.
public actor StudioJournalCognitiveBus {
    public typealias Sink = @Sendable (StudioJournalEntry) async -> Void

    private static let shared = StudioJournalCognitiveBus()
    private var sink: Sink?
    private var warnedAboutMissingSink = false

    /// Install the process's one sink. A second install REPLACES the first —
    /// there is one resident mind, so there is one sink.
    public static func install(_ sink: @escaping Sink) async {
        await shared.setSink(sink)
    }

    public static var isInstalled: Bool {
        get async { await shared.hasSink }
    }

    /// Publish a filed entry. Never throws and never blocks the journal write's
    /// success: the entry is already durable when this runs.
    public static func publish(_ entry: StudioJournalEntry) async {
        await shared.deliver(entry)
    }

    private var hasSink: Bool { sink != nil }

    private func setSink(_ value: @escaping Sink) {
        sink = value
        warnedAboutMissingSink = false
    }

    private func deliver(_ entry: StudioJournalEntry) async {
        guard let sink else {
            if !warnedAboutMissingSink {
                warnedAboutMissingSink = true
                NSLog(
                    "[studio] journal entry %@ filed with no cognitive sink installed — "
                        + "the entry is durable, but nothing put it on the bus. "
                        + "Install StudioJournalCognitiveBus at startup.",
                    entry.id
                )
            }
            return
        }
        await sink(entry)
    }
}
