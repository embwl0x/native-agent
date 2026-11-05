// Studio stance scales measured work feeling; neutral entries move nothing. Stable journal ids publish pointers, never response prose or social affect.

import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
// Blueprint: | `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |

public extension CognitiveEvent {
    /// Owner-measured feeling uses this metadata contract.
    static let feltValenceMetadataKey = "feltValence"
    static let feltArousalMetadataKey = "feltArousal"
    /// Retain journal identity so dream summaries cite the source.
    static let studioEntryIDMetadataKey = "studioEntryId"
    static let studioStanceMetadataKey = "studioStance"

    /// Measured feeling replaces per-kind inference so one entry cannot count twice.
    var carriesMeasuredFeltValence: Bool {
        switch metadata[Self.feltValenceMetadataKey] {
        case .some(.double), .some(.int): true
        default: false
        }
    }
}

public struct StudioJournalFelt: Sendable, Equatable {
    /// Zero is a valid neutral entry, never a scoring failure.
    public var valence: Double
    /// Arousal follows measured magnitude so it cannot be invented independently.
    public var arousal: Double

    public static let still = StudioJournalFelt(valence: 0, arousal: 0)

}

public extension CognitiveSubstrate {

    /// Share the body's measured-resolution ceiling to keep work feeling composed.
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

    /// A filed event needs nonempty source title and id.
    func studioJournalEvent(
        for entry: StudioJournalEntry
    ) throws -> CognitiveEvent? {
        let title = entry.work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !entry.id.isEmpty else { return nil }
        let felt = studioJournalFelt(for: entry)
        guard let occurredAt = NativeTimestampFormat.parseISO8601FractionalFirst(entry.recordedAt) else {
            throw CognitiveArtifactCodec.FieldFailure(path: "studio_journal:\(entry.id).recordedAt")
        }
        // A continuity node names the act and points to the journal; copying the judgment would create competing records.
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
            // A neutral entry is not merely valence-zero, it is unimportant: nothing about it should draw attention it did not earn.
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

    /// Put one filed entry on the bus. Idempotent by the event's stable id: the field's seen-event check makes a replay inert.
    func ingestStudioJournalEntry(_ entry: StudioJournalEntry) async {
        do {
            guard let event = try studioJournalEvent(for: entry) else { return }
            await ingest(event)
        } catch {
            await recordReceipt(kind: "studio_journal.unavailable", payload: .object([
                "id": .string(entry.id), "error": .string(String(describing: error)),
            ]))
        }
    }
}

/// One sink receives durable entries; a missing sink is logged once.
public actor StudioJournalCognitiveBus {
    public typealias Sink = @Sendable (StudioJournalEntry) async -> Void

    private var sink: Sink?
    private var warnedAboutMissingSink = false

    public init() {}

    /// One resident mind installs its own sink.
    public func install(_ value: @escaping Sink) {
        sink = value
        warnedAboutMissingSink = false
    }

    /// Publish a filed entry after its durable write. Missing delivery is reported; it cannot undo that write.
    public func publish(_ entry: StudioJournalEntry) async {
        guard let sink else {
            if !warnedAboutMissingSink {
                warnedAboutMissingSink = true
                nativeLog(
                    "[studio] journal entry %@ filed with no cognitive sink installed — "
                        + "the entry is durable, but nothing put it on the bus. "
                        + "Install this runtime's studio journal sink at startup.",
                    entry.id
                )
            }
            return
        }
        await sink(entry)
    }
}
