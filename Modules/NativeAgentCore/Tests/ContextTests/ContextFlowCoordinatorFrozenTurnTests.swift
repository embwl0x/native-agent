import Foundation
import NativeAgentCore
import Testing
@testable import Context

extension ContextFlowCoordinatorTests {
    @Test
    func liveTurnSelectionAndOutcomeProduceBoundedFeedbackReceipts() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Who are you?",
            personaIDHint: "Agent"
        ))
        #expect(!prepared.packet.receipt.selectedAtomIDs.isEmpty)
        await prepared.recordOutcome(.completed)

        var feedback: [ContextStoreReceipt] = []
        for _ in 0..<100 {
            feedback = try await fixture.store.recentReceipts(limit: 20)
                .filter { $0.kind == .feedback }
            if feedback.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(feedback.contains { $0.details["signal"] == "selection" })
        #expect(feedback.contains { $0.details["signal"] == "outcome.completed" })
    }

    // EVAL FENCE: core.context / context.selection.liveLatency
    @Test
    func liveSelectionReceiptCarriesMonotonicLatencyProvenanceAndRejectsAdverseRows() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What should I remember about this session?",
            personaIDHint: "Agent"
        ))
        let packetReceipt = prepared.packet.receipt
        // This proves provenance, not machine speed: zero microseconds is a
        // valid clock resolution, and no wall-clock envelope is asserted here.
        #expect(packetReceipt.selectionLatencyProvenance == .monotonicClock)
        #expect(packetReceipt.measuredSelectionMicroseconds != nil)

        // The receipt crosses process/storage boundaries as Codable data. A
        // current producer must retain the measured provenance, while a
        // pre-provenance wire payload must still decode honestly as unknown.
        let encodedReceipt = try JSONEncoder().encode(packetReceipt)
        let receiptWire = try #require(
            try JSONSerialization.jsonObject(with: encodedReceipt) as? [String: Any]
        )
        #expect(
            receiptWire["selectionLatencyProvenance"] as? String
                == ContextSelectionLatencyProvenance.monotonicClock.rawValue
        )
        let roundTrippedReceipt = try JSONDecoder().decode(
            ContextSelectionReceipt.self,
            from: encodedReceipt
        )
        #expect(roundTrippedReceipt.selectionLatencyProvenance == .monotonicClock)
        #expect(roundTrippedReceipt.measuredSelectionMicroseconds == packetReceipt.measuredSelectionMicroseconds)

        var legacyReceiptWire = receiptWire
        legacyReceiptWire.removeValue(forKey: "selectionLatencyProvenance")
        let legacyReceiptData = try JSONSerialization.data(withJSONObject: legacyReceiptWire)
        let legacyReceipt = try JSONDecoder().decode(ContextSelectionReceipt.self, from: legacyReceiptData)
        #expect(legacyReceipt.selectionLatencyProvenance == nil)
        #expect(legacyReceipt.measuredSelectionMicroseconds == packetReceipt.measuredSelectionMicroseconds)

        var durableReceipt: ContextStoreReceipt?
        for _ in 0..<100 {
            durableReceipt = try await fixture.store.recentReceipts(limit: 50).first(where: {
                $0.kind == .selection && $0.details["receipt_id"] == packetReceipt.id
            })
            if durableReceipt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stored = try #require(durableReceipt)
        let observed = ContextSelectionLatencyObservation(receipt: stored)
        #expect(observed.status == .measured)
        #expect(observed.provenance == .monotonicClock)
        #expect(observed.surface == .chat)
        #expect(observed.microseconds == packetReceipt.measuredSelectionMicroseconds)
        #expect(stored.details["selection_microseconds"] == packetReceipt.measuredSelectionMicroseconds.map { String($0) })

        let missing = ContextSelectionLatencyObservation(receipt: ContextStoreReceipt(
            kind: .selection,
            summary: "fixture missing latency",
            details: [
                "surface": ContextSurface.chat.rawValue,
                "selection_microseconds": "absent",
                "selection_latency_provenance": ContextSelectionLatencyProvenance.unavailable.rawValue,
            ]
        ))
        #expect(missing.status == .missing)
        #expect(missing.microseconds == nil)

        let malformed = ContextSelectionLatencyObservation(receipt: ContextStoreReceipt(
            kind: .selection,
            summary: "fixture malformed latency",
            details: [
                "surface": ContextSurface.chat.rawValue,
                "selection_microseconds": "-9",
                "selection_latency_provenance": ContextSelectionLatencyProvenance.monotonicClock.rawValue,
            ]
        ))
        #expect(malformed.status == .invalid)
        #expect(malformed.microseconds == nil)

        let replaySupplied = ContextSelectionLatencyObservation(receipt: ContextStoreReceipt(
            kind: .selection,
            summary: "fixture replay latency",
            details: [
                "surface": ContextSurface.chat.rawValue,
                "selection_microseconds": "12",
                "selection_latency_provenance": ContextSelectionLatencyProvenance.callerSupplied.rawValue,
            ]
        ))
        #expect(replaySupplied.status == .invalid)
        #expect(replaySupplied.microseconds == nil)
    }

    @Test
    func frozenTurnPinsGenerationWithoutFeedbackPrewarmOrReceiptMutation() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let revisionBefore = try #require(await fixture.coordinator.frozenRevision())
        let receiptsBefore = try await fixture.store.recentReceipts(limit: 100)
        let prepared = try await fixture.coordinator.prepareFrozenTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Evaluate the frozen identity.",
            personaIDHint: "Agent",
            sessionID: "frozen-session"
        ))
        let selected = try #require(prepared.packet.receipt.selectedAtomIDs.first)
        await prepared.recordExpansion(atomID: selected, receiptID: "must-not-persist")
        await prepared.recordRetry()
        await prepared.recordOutcome(.completed)
        for _ in 0..<10 { await Task.yield() }

        let revisionAfter = try #require(await fixture.coordinator.frozenRevision())
        let receiptsAfter = try await fixture.store.recentReceipts(limit: 100)
        #expect(revisionAfter == revisionBefore)
        #expect(prepared.generation.generation.id == revisionBefore.generationID)
        #expect(prepared.lease.snapshot.generationID == revisionBefore.arenaGenerationID)
        #expect(receiptsAfter == receiptsBefore)
    }

    @Test
    func repeatedSessionTurnsValidatePrewarmUsefulnessWithoutChangingSelection() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let request = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Continue our identity discussion.",
            personaIDHint: "Agent",
            sessionID: "session-1"
        )

        let first = try await fixture.coordinator.prepareTurn(request)
        let firstSelection = first.packet.receipt.selectedAtomIDs
        for _ in 0..<100 {
            let receipts = try await fixture.store.recentReceipts(limit: 20)
            if receipts.contains(where: {
                $0.kind == .prewarm && $0.summary == "context prewarm planning"
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let second = try await fixture.coordinator.prepareTurn(request)
        #expect(second.packet.receipt.selectedAtomIDs == firstSelection)
        var health = await fixture.coordinator.health()
        for _ in 0..<100 {
            if health.prewarmUsefulnessReceipts > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
            health = await fixture.coordinator.health()
        }
        #expect(health.prewarmUsefulnessReceipts == 1)
        var receipts: [ContextStoreReceipt] = []
        for _ in 0..<100 {
            receipts = try await fixture.store.recentReceipts(limit: 50)
            if receipts.contains(where: {
                $0.kind == .prewarm && $0.summary == "context prewarm usefulness"
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let usefulness = try #require(receipts.first {
            $0.kind == .prewarm && $0.summary == "context prewarm usefulness"
        })
        #expect(usefulness.details["authority_granted"] == "false")
    }

    /// NORTHSTAR clause 6. Measured 2026-09-01: `persona.docChars` = 22,278
    /// while `system.stableChars` = 4,601 — in `.active` mode the kernel is
    /// SOUL/VOICE only, so every other required persona document was precovered
    /// by NOTHING and rode the per-turn packet, uncached, on every single turn.
    ///
    /// `stableSegmentCarriesRequiredDocuments` is the caller's promise that its
    /// STABLE segment now carries those bytes verbatim. On that promise the
    /// coordinator precovers EVERY persona-owned source, and the packet stops
    /// mirroring identity into the volatile block. Default `false` reproduces
    /// today's kernel-only precoverage exactly — the assertion pair below is
    /// what proves the flag, and only the flag, moved the document.
    @Test
    func stableSegmentFlagKeepsRequiredPersonaDocumentsOutOfThePacket() async throws {
        let growth = compiledSource(
            id: "growth",
            owner: "nativeagent.persona",
            locator: "persona/Agent/GROWTH.md",
            kind: .identity,
            body: "Approved drift is curated, never inferred; growth is User-gated.",
            authority: .identity,
            policy: .always
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [growth]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func request(stableCarriesDocuments: Bool) -> ContextTurnRequest {
            ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "How does approved drift work?",
                personaIDHint: "Agent",
                allowedPrivacy: [.localPrivate],
                stableSegmentCarriesRequiredDocuments: stableCarriesDocuments
            )
        }

        let growthSourceID = growth.descriptor.id

        // Today's behavior, untouched: the kernel carries SOUL only, so GROWTH
        // is not precovered and the packet is its carrier.
        let unflagged = try await fixture.coordinator
            .prepareFrozenTurn(request(stableCarriesDocuments: false))
        #expect(!unflagged.need.precoveredSourceIDs.contains(growthSourceID))
        #expect(unflagged.packet.selectedItems.contains {
            $0.pointer.sourceID == growthSourceID
        })

        // With the promise: precovered, and absent from the packet entirely —
        // not in the selected items, and not smuggled back as a pointer.
        let flagged = try await fixture.coordinator
            .prepareFrozenTurn(request(stableCarriesDocuments: true))
        #expect(flagged.need.precoveredSourceIDs.contains(growthSourceID))
        #expect(!flagged.packet.selectedItems.contains {
            $0.pointer.sourceID == growthSourceID
        })
        #expect(!flagged.packet.expandablePointers.contains {
            $0.sourceID == growthSourceID
        })
    }

}
