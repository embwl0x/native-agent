import Context
import Foundation
import Testing

@Suite("Fluid Context FC7 feedback")
struct ContextFeedbackTests {
    @Test
    func retrievalUtilityIsCappedAndPreservesAuthorityAndPrivacyMetadata() throws {
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
        #expect(strongState.authority == .canonical)
        #expect(strongState.privacy == .publicSafe)
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

    private func atom(_ suffix: String) -> ContextAtomID {
        ContextAtomID(rawValue: "atom:\(suffix)")
    }
}
