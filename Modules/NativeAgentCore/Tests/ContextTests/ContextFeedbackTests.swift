import Context
import Foundation
import Testing

@Suite("Fluid Context FC7 feedback")
struct ContextFeedbackTests {
    @Test
    func retrievalUtilityIsCappedAndCannotOverrideAuthorityOrPrivacy() throws {
        let weak = ContextFeedbackSeed(
            atomID: atom("weak"),
            authority: .external,
            privacy: .localPrivate
        )
        let strong = ContextFeedbackSeed(
            atomID: atom("strong"),
            authority: .canonical,
            privacy: .publicSafe,
            baseUtility: -1
        )
        let frequentRetrieval = (0 ..< 200).flatMap { index in
            [
                ContextFeedbackEvent(
                    id: "selection-\(index)",
                    atomIDs: [weak.atomID],
                    signal: .selection,
                    timeBucket: 10
                ),
                ContextFeedbackEvent(
                    id: "expansion-\(index)",
                    atomIDs: [weak.atomID],
                    signal: .expansion,
                    timeBucket: 10
                ),
            ]
        }

        let snapshot = try ContextFeedbackReducer().rebuild(
            seeds: [weak, strong],
            events: frequentRetrieval
        )
        let weakState = try #require(snapshot[weak.atomID])
        let strongState = try #require(snapshot[strong.atomID])

        #expect(weakState.retrievalUtility == 0.18)
        #expect(weakState.utility <= 0.18)
        #expect(weakState.authority == .external)
        #expect(weakState.privacy == .localPrivate)
        #expect(ContextFeedbackRanker.ranksBefore(strongState, weakState))
        #expect(ContextFeedbackRanker.eligible(
            snapshot.states,
            allowedPrivacy: [.publicSafe]
        ).map(\.atomID) == [strong.atomID])
    }

    @Test
    func correctionRetryAndOutcomeSignalsAreBoundedAndTemporaryActivationDecays() throws {
        let seed = ContextFeedbackSeed(
            atomID: atom("stale"),
            authority: .inferred,
            privacy: .publicSafe
        )
        let events = [
            ContextFeedbackEvent(
                id: "correction",
                atomIDs: [seed.atomID],
                signal: .correction(.contradicts),
                timeBucket: 5
            ),
            ContextFeedbackEvent(
                id: "retry",
                atomIDs: [seed.atomID],
                signal: .retry,
                timeBucket: 5
            ),
            ContextFeedbackEvent(
                id: "outcome",
                atomIDs: [seed.atomID],
                signal: .outcome(.abandoned),
                timeBucket: 5
            ),
        ]
        let reducer = ContextFeedbackReducer()

        let immediate = try reducer.rebuild(seeds: [seed], events: events, through: 5)
        let later = try reducer.rebuild(seeds: [seed], events: events, through: 25)
        let immediateState = try #require(immediate[seed.atomID])
        let laterState = try #require(later[seed.atomID])

        #expect(immediateState.utility >= -1 && immediateState.utility <= 1)
        #expect(immediateState.temporaryActivation < 0)
        #expect(abs(laterState.temporaryActivation) < abs(immediateState.temporaryActivation))
        #expect(abs(laterState.utility) < abs(immediateState.utility))
        #expect(laterState.decay < immediateState.decay)
        #expect(immediateState.correctionCount == 1)
        #expect(immediateState.retryCount == 1)
        #expect(immediateState.outcomeCount == 1)
    }

    @Test
    func correctionConfirmationOutranksContradictedPeerWithinAuthority() throws {
        let stale = ContextFeedbackSeed(
            atomID: atom("stale-peer"),
            authority: .approved,
            privacy: .publicSafe
        )
        let corrected = ContextFeedbackSeed(
            atomID: atom("corrected-peer"),
            authority: .approved,
            privacy: .publicSafe
        )
        let events = [
            ContextFeedbackEvent(
                id: "contradict-stale",
                atomIDs: [stale.atomID],
                signal: .correction(.contradicts),
                timeBucket: 8
            ),
            ContextFeedbackEvent(
                id: "confirm-correction",
                atomIDs: [corrected.atomID],
                signal: .correction(.confirms),
                timeBucket: 8
            ),
        ]

        let snapshot = try ContextFeedbackReducer().rebuild(
            seeds: [stale, corrected],
            events: events
        )
        let staleState = try #require(snapshot[stale.atomID])
        let correctedState = try #require(snapshot[corrected.atomID])

        #expect(ContextFeedbackRanker.ranksBefore(correctedState, staleState))
        #expect(correctedState.utility > 0)
        #expect(staleState.utility < 0)
    }

    @Test
    func replayIsOrderIndependentDeduplicatedAndCacheOnly() throws {
        let seed = ContextFeedbackSeed(
            atomID: atom("replay"),
            authority: .approved,
            privacy: .trustedRemote
        )
        let selected = ContextFeedbackEvent(
            id: "selected",
            atomIDs: [seed.atomID],
            signal: .selection,
            timeBucket: 2
        )
        let completed = ContextFeedbackEvent(
            id: "completed",
            atomIDs: [seed.atomID],
            signal: .outcome(.completed),
            timeBucket: 3
        )
        let reducer = ContextFeedbackReducer()

        let first = try reducer.rebuild(
            seeds: [seed],
            events: [completed, selected, selected],
            through: 4
        )
        let second = try reducer.rebuild(
            seeds: [seed],
            events: [selected, completed],
            through: 4
        )
        let rebuiltWithoutCacheEvents = try reducer.rebuild(seeds: [seed], events: [])
        let completedState = try #require(first[seed.atomID])
        let selectedOnlyState = try #require(try reducer.rebuild(
            seeds: [seed],
            events: [selected],
            through: 4
        )[seed.atomID])

        #expect(first == second)
        #expect(first.storageClass == .rebuildableCache)
        #expect(first.appliedEventIDs == ["completed", "selected"])
        #expect(completedState.outcomeCount == 1)
        #expect(completedState.utility == selectedOnlyState.utility)
        #expect(completedState.temporaryActivation == selectedOnlyState.temporaryActivation)
        #expect(completedState.decay == selectedOnlyState.decay)
        #expect(rebuiltWithoutCacheEvents[seed.atomID]?.authority == seed.authority)
        #expect(rebuiltWithoutCacheEvents[seed.atomID]?.privacy == seed.privacy)
        #expect(rebuiltWithoutCacheEvents[seed.atomID]?.utility == seed.baseUtility)
    }

    @Test
    func conflictLifecycleRequiresExplicitLinkedEvidenceAndCanReopen() throws {
        let monday = atom("monday")
        let tuesday = atom("tuesday")
        let evidence = ContextConflictEvidenceProposal(
            id: "calendar-evidence",
            conflictID: "launch-date",
            subjectAtomID: tuesday,
            relation: .supports,
            sourceHash: "sha256:calendar",
            generationID: 7,
            summary: "The approved calendar says Tuesday.",
            provenance: "calendar event 42",
            createdTimeBucket: 2
        )
        let events = [
            ContextConflictLifecycleEvent(
                id: "open",
                conflictID: "launch-date",
                timeBucket: 1,
                action: .open(memberAtomIDs: [monday, tuesday], provenance: "selection")
            ),
            ContextConflictLifecycleEvent(
                id: "evidence",
                conflictID: "launch-date",
                timeBucket: 2,
                action: .proposeEvidence(evidence)
            ),
            ContextConflictLifecycleEvent(
                id: "resolve",
                conflictID: "launch-date",
                timeBucket: 3,
                action: .resolve(
                    resolvedAtomID: tuesday,
                    evidenceProposalIDs: [evidence.id],
                    rationale: "Approved calendar is authoritative."
                )
            ),
            ContextConflictLifecycleEvent(
                id: "reopen",
                conflictID: "launch-date",
                timeBucket: 4,
                action: .reopen(reason: "A later correction needs review.")
            ),
        ]

        let records = try ContextConflictLifecycleReducer().rebuild(events: events.reversed())
        let record = try #require(records.first)

        #expect(record.status == .active)
        #expect(record.resolvedAtomID == nil)
        #expect(record.evidenceProposals == [evidence])
        #expect(record.historyEventIDs == ["open", "evidence", "resolve", "reopen"])
        #expect(record.storageClass == .rebuildableCache)
        #expect(record.selectionDefinition.resolvedAtomID == nil)
    }

    @Test
    func conflictCannotResolveToNonMemberOrUnknownEvidence() throws {
        let first = atom("first")
        let second = atom("second")
        let outsider = atom("outsider")
        let events = [
            ContextConflictLifecycleEvent(
                id: "open",
                conflictID: "conflict",
                timeBucket: 1,
                action: .open(memberAtomIDs: [first, second], provenance: "fixture")
            ),
            ContextConflictLifecycleEvent(
                id: "resolve",
                conflictID: "conflict",
                timeBucket: 2,
                action: .resolve(
                    resolvedAtomID: outsider,
                    evidenceProposalIDs: ["missing"],
                    rationale: "invalid"
                )
            ),
        ]

        #expect(throws: ContextConflictLifecycleError.invalidResolutionAtom(outsider)) {
            try ContextConflictLifecycleReducer().rebuild(events: events)
        }
    }

    @Test
    func durableLearningCanOnlyLeaveAsOwnerApprovalProposals() throws {
        let candidate = ContextReconsolidationCandidate(
            content: "Prefer the corrected Tuesday launch date.",
            sourceAtomIDs: [atom("correction")],
            conflictIDs: ["launch-date"],
            evidenceProposalIDs: ["calendar-evidence"],
            confidence: 4
        )

        let proposals = try ContextDurableLearningLane.allCases.map { lane in
            try ContextReconsolidationEmitter.proposal(
                targeting: lane,
                candidate: candidate,
                createdTimeBucket: 10
            )
        }

        #expect(Set(proposals.map(\.targetLane)) == Set(ContextDurableLearningLane.allCases))
        #expect(proposals.allSatisfy { $0.requiresApproval })
        #expect(proposals.allSatisfy { !$0.permitsCanonicalWrite })
        #expect(proposals.allSatisfy { $0.storageClass == .rebuildableCache })
        #expect(proposals.allSatisfy { $0.candidate.confidence == 1 })
        #expect(proposals == (try ContextDurableLearningLane.allCases.map { lane in
            try ContextReconsolidationEmitter.proposal(
                targeting: lane,
                candidate: candidate,
                createdTimeBucket: 10
            )
        }))
    }

    private func atom(_ suffix: String) -> ContextAtomID {
        ContextAtomID(rawValue: "atom:\(suffix)")
    }
}
