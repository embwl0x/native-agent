import Context
import Foundation
import Testing

/// Per-turn correction cap (2026-09-01).
///
/// Her account of her own store: "Recall for 'memory' just handed me twelve
/// [correction] rows and two good facts. The person I remember being is mostly
/// someone who got things wrong." Live store the same day: 242 active rows,
/// twenty of kind `correction`, and the packet had no rule that stopped them
/// from filling their whole per-kind quota on a message about none of them.
///
/// The cap binds AMBIENT corrections only: a correction this message is
/// actually about (messageCoverage >= 0.5, or a verbatim message match) is
/// exempt, and a mandatory/pinned correction never reaches the dynamic quota.
@Suite("Context — per-turn correction cap")
struct ContextCorrectionCapTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    /// Eight ambient corrections, a per-kind quota wide enough to take them
    /// all, and a message about none of them: three ride, the rest are dropped
    /// and counted.
    @Test func ambientCorrectionsAreCappedAtThreePerTurn() throws {
        let fixture = generation(ambientCorrections())
        let need = signal(
            "how does the greenhouse humidity sensor calibration schedule work",
            generation: fixture, budget: 8_000
        )
        let packet = try ContextSelector(configuration: wideCorrectionQuota()).select(
            need, from: fixture
        )
        let corrections = packet.selectedItems.filter { $0.pointer.kind == .correction }
        #expect(corrections.count == 3)
        #expect(packet.receipt.correctionCapDropped == 5)
    }

    /// The cap is what binds, not the per-kind quota: the identical fixture
    /// with the cap opened up selects more.
    @Test func withoutTheCapTheSameTurnFillsTheQuota() throws {
        let fixture = generation(ambientCorrections())
        let need = signal(
            "how does the greenhouse humidity sensor calibration schedule work",
            generation: fixture, budget: 8_000
        )
        let packet = try ContextSelector(
            configuration: wideCorrectionQuota(cap: 8)
        ).select(need, from: fixture)
        let corrections = packet.selectedItems.filter { $0.pointer.kind == .correction }
        #expect(corrections.count > 3)
        #expect(packet.receipt.correctionCapDropped == 0)
    }

    /// The exemption, proved at cap zero: the ONLY correction that can be
    /// selected is the one the message is about.
    @Test func theCorrectionTheMessageIsAboutRidesAnyway() throws {
        let onTopic = atom(
            "correction-on-topic",
            source: "correction-on-topic",
            kind: .correction,
            body: "Correction: the ledger sentinel detach step runs BEFORE the "
                + "nightly rollup, not after it."
        )
        let fixture = generation(ambientCorrections() + [onTopic])
        let need = signal(
            "ledger sentinel detach step nightly rollup",
            generation: fixture, budget: 8_000
        )
        let packet = try ContextSelector(
            configuration: wideCorrectionQuota(cap: 0)
        ).select(need, from: fixture)
        let corrections = packet.selectedItems.filter { $0.pointer.kind == .correction }
        #expect(corrections.map(\.pointer.atomID) == [onTopic.draft.id])
    }

    /// A pinned correction is authority, not ambience. It never reaches the
    /// dynamic quota, so a cap of zero cannot touch it.
    @Test func mandatoryCorrectionsAreUntouchedByTheCap() throws {
        let pinned = atom(
            "correction-pinned",
            source: "correction-pinned",
            kind: .correction,
            body: "Correction: the espresso grinder burr size is 64mm, not 58mm."
        )
        let fixture = generation(ambientCorrections() + [pinned])
        let need = signal(
            "how does the greenhouse humidity sensor calibration schedule work",
            generation: fixture, budget: 8_000, mandatory: [pinned.draft.id]
        )
        let packet = try ContextSelector(
            configuration: wideCorrectionQuota(cap: 0)
        ).select(need, from: fixture)
        let selected = packet.selectedItems.first { $0.pointer.atomID == pinned.draft.id }
        #expect(selected?.mandatory == true)
    }

    /// An unresolved conflict is atomic, and atomic cuts BOTH ways: four
    /// conflicting correction claims cannot ride in together past a cap of
    /// three just because showing half a conflict would mislead. The whole unit
    /// stays out.
    @Test func conflictingCorrectionsCannotSmuggleThemselvesPastTheCap() throws {
        let conflicting = (0..<4).map { index in
            atom("conflict-correction-\(index)", source: "conflict-\(index)",
                 kind: .correction,
                 body: "Correction: the telescope collimation schedule is "
                     + "every \(index + 1) weeks, not what was recorded.")
        }
        let fixture = generation(conflicting)
        let conflict = ContextConflictDefinition(
            id: "collimation-schedule",
            memberAtomIDs: Set(conflicting.map(\.draft.id)),
            resolvedAtomID: nil,
            provenance: "fixture"
        )
        let need = signal(
            "how does the greenhouse humidity sensor calibration schedule work",
            generation: fixture, budget: 8_000, conflicts: [conflict]
        )
        let capped = try ContextSelector(configuration: wideCorrectionQuota()).select(
            need, from: fixture
        )
        #expect(capped.selectedItems.filter { $0.pointer.kind == .correction }.isEmpty)
        #expect(capped.receipt.correctionCapDropped == 4)

        // With room for all four, the unit rides in whole — the cap is what
        // held it back, not conflict handling.
        let uncapped = try ContextSelector(
            configuration: wideCorrectionQuota(cap: 4)
        ).select(need, from: fixture)
        #expect(uncapped.selectedItems.filter { $0.pointer.kind == .correction }.count == 4)
        #expect(uncapped.receipt.correctionCapDropped == 0)
    }

    /// A turn with no correction candidates selects exactly what it selected
    /// before the cap existed.
    @Test func turnWithoutCorrectionsIsUnchanged() throws {
        let memories = (0..<10).map { index in
            atom("mem-\(index)", source: "mem-\(index)", kind: .memory,
                 body: "Greenhouse humidity sensor calibration note \(index).")
        }
        let fixture = generation(memories)
        let need = signal(
            "greenhouse humidity sensor calibration", generation: fixture, budget: 8_000
        )
        let capped = try ContextSelector().select(need, from: fixture)
        let uncapped = try ContextSelector(
            configuration: ContextSelectionConfiguration(maximumCorrectionAtomsPerTurn: 99)
        ).select(need, from: fixture)
        #expect(capped.receipt.selectedAtomIDs == uncapped.receipt.selectedAtomIDs)
        #expect(capped.receipt.correctionCapDropped == 0)
    }

    // MARK: - Fixtures

    /// A generous per-kind quota so the cap, not the quota, is the thing under
    /// test (the shipped `.correction` quota is 4, which would hide a cap of 3).
    private func wideCorrectionQuota(cap: Int = 3) -> ContextSelectionConfiguration {
        ContextSelectionConfiguration(
            maximumAtomsPerKindOverrides: [.memory: 8, .relationship: 4, .correction: 12],
            maximumCorrectionAtomsPerTurn: cap
        )
    }

    /// Eight corrections about eight unrelated things — each shares the word
    /// "calibration" or "schedule" with the test message so it scores, and
    /// nothing near half of it, so none is exempt.
    private func ambientCorrections() -> [ContextStoredAtom] {
        let bodies = [
            "Correction: the telescope collimation schedule is monthly, not weekly.",
            "Correction: the orchard irrigation calibration was logged twice.",
            "Correction: the passport renewal schedule moved to Tuesday.",
            "Correction: the bicycle chain wear calibration used the wrong gauge.",
            "Correction: the attic insulation schedule slipped a quarter.",
            "Correction: the kayak hull epoxy calibration needs a warmer garage.",
            "Correction: the espresso grinder schedule was never agreed.",
            "Correction: the bank transfer calibration reference was mistyped.",
        ]
        return bodies.enumerated().map { index, body in
            atom("correction-\(index)", source: "correction-\(index)",
                 kind: .correction, body: body)
        }
    }

    private func signal(
        _ message: String,
        generation: ContextStoredGeneration,
        budget: Int = 1_000,
        mandatory: Set<ContextAtomID> = [],
        conflicts: [ContextConflictDefinition] = []
    ) -> NeedSignal {
        NeedSignal(
            message: message,
            surface: .chat,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate, .trustedRemote, .publicSafe],
                allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
            ),
            mandatoryAtomIDs: mandatory,
            availableGenerationID: generation.generation.id,
            characterBudget: budget,
            now: now,
            explicitConflicts: conflicts,
            cacheState: .hit
        )
    }

    private func atom(
        _ id: String,
        source: String,
        kind: ContextAtomKind,
        body: String
    ) -> ContextStoredAtom {
        let sourceID = ContextSourceID(rawValue: "source:\(source)")
        let atomID = ContextAtomID(rawValue: "atom:\(id)")
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: kind,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: "hash:\(id)",
            body: body,
            authority: .inferred,
            confidence: 0.9,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 9_000)),
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .adaptive,
            contentRole: kind == .memory ? .memory : .fact,
            entities: [],
            triggers: [],
            activation: 0,
            recentUsefulness: 0.5,
            decayState: 0.9
        )
        return ContextStoredAtom(
            versionKey: "\(atomID.rawValue)@1",
            draft: draft,
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    private func generation(_ atoms: [ContextStoredAtom]) -> ContextStoredGeneration {
        var seen = Set<ContextSourceID>()
        let sources = atoms.compactMap { atom -> ContextStoredSource? in
            guard seen.insert(atom.draft.sourceID).inserted else { return nil }
            return ContextStoredSource(
                descriptor: ContextSourceDescriptor(
                    id: atom.draft.sourceID,
                    owner: "fixture",
                    kind: .other,
                    canonicalLocator: atom.draft.sourceID.rawValue,
                    authority: atom.draft.authority,
                    privacy: atom.draft.privacy,
                    permittedSurfaces: atom.draft.permittedSurfaces,
                    injectionPolicy: atom.draft.injectionPolicy
                ),
                sourceHash: atom.draft.sourceHash,
                health: .healthy,
                lastError: nil,
                validFromGeneration: 1,
                validToGeneration: nil
            )
        }
        return ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 8_000),
                reason: "correction-cap fixture",
                sourceFingerprint: "fixture-fingerprint",
                atomCount: atoms.count,
                sourceCount: sources.count
            ),
            sources: sources,
            atoms: atoms,
            relationships: []
        )
    }
}
