// Studio feeling reads lexical valence from the written judgment through studioValence.
// Stance gates and scales: abstained is silent, open weighs half, formed weighs full;
// empty or neutral responses move nothing, and entries without artifact refs weigh half again.
// Description-only consults cannot enter the journal. Valence concerns the work,
// never her socialWarmth, uncertainty or taskPressure; this file writes no dreams.
// Dream-citation seam: stable `studio_journal:<entry.id>` events carry the entry id
// in `subject.id` (type `studio_entry`) and metadata `studioEntryId`.

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
// Blueprint: | `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |

public extension CognitiveEvent {
    /// Metadata key for valence measured by the event's owner.
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

/// The measured feeling of one filed entry.
public struct StudioJournalFelt: Sendable, Equatable {
    /// −1…1, bounded. Zero means "this entry moves nothing", which is a real
    /// and common outcome, not a failure to score.
    public var valence: Double
    /// 0…1. A judgment that lands hard is a little more activating than one
    /// that does not; it is derived from the same magnitude, never invented.
    public var arousal: Double

    public static let still = StudioJournalFelt(valence: 0, arousal: 0)

}

public extension CognitiveSubstrate {

    /// Bound on how far one entry can move her. Same ceiling the organism's own
    /// measured resolutions use — composed, never melodrama.
    static let studioJournalFeltCeiling = 0.7

    func studioJournalFelt(for entry: StudioJournalEntry) -> StudioJournalFelt {
        guard entry.stance.kind != .abstained else { return .still }
        let response = (entry.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { return .still }
        let appraised = studioValence(in: response)
        guard appraised != 0 else { return .still }

        var value = appraised
        if entry.stance.kind == .open { value *= 0.5 }
        if entry.artifactRefs.isEmpty { value *= 0.5 }
        let ceiling = Self.studioJournalFeltCeiling
        let bounded = min(ceiling, max(-ceiling, value))
        return StudioJournalFelt(valence: bounded, arousal: abs(bounded).clamped01())
    }

    /// Mint a filed entry's event only when its title and id are nonempty.
    func studioJournalEvent(
        for entry: StudioJournalEntry,
        at now: Date? = nil
    ) -> CognitiveEvent? {
        let title = entry.work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !entry.id.isEmpty else { return nil }
        let felt = studioJournalFelt(for: entry)
        let occurredAt = now
            ?? NativeTimestampFormat.parseISO8601FractionalFirst(entry.recordedAt)
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

/// Delivers durable journal entries to one sink; logs once while no sink is installed.
public actor StudioJournalCognitiveBus {
    public typealias Sink = @Sendable (StudioJournalEntry) async -> Void

    @TaskLocal static var shared = StudioJournalCognitiveBus()
    private var sink: Sink?
    private var warnedAboutMissingSink = false

    /// Install the process's one sink. A second install REPLACES the first —
    /// there is one resident mind, so there is one sink.
    public static func install(_ sink: @escaping Sink) async {
        await shared.setSink(sink)
    }

    /// Publish a filed entry. Never throws and never blocks the journal write's
    /// success: the entry is already durable when this runs.
    public static func publish(_ entry: StudioJournalEntry) async {
        await shared.deliver(entry)
    }

    private func setSink(_ value: @escaping Sink) {
        sink = value
        warnedAboutMissingSink = false
    }

    private func deliver(_ entry: StudioJournalEntry) async {
        guard let sink else {
            if !warnedAboutMissingSink {
                warnedAboutMissingSink = true
                nativeLog(
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
