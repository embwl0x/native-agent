import Foundation
import NativeAgentCore
import Testing
@testable import Context

extension ContextFlowCoordinatorTests {
    @Test
    func generationDerivedSetsReuseOneComputationAndIsolatePrivacyKeys() async throws {
        let correction = compiledSource(
            id: "cached-correction",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/cached-correction",
            kind: .correction,
            body: "A cached eligibility walk must retain this explicit correction.",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [correction]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let correctionID = try #require(correction.atoms.first?.id)
        let privateRequest = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Retain the correction.",
            personaIDHint: "Agent",
            allowedPrivacy: [.localPrivate]
        )

        let first = try await fixture.coordinator.prepareFrozenTurn(privateRequest)
        #expect(first.need.mandatoryAtomIDs == [correctionID])
        let afterFirst = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(afterFirst.computationCount == 1)
        #expect(afterFirst.hitCount == 0)
        #expect(afterFirst.entryCount == 1)

        let second = try await fixture.coordinator.prepareFrozenTurn(privateRequest)
        #expect(second.packet.receipt.selectedAtomIDs == first.packet.receipt.selectedAtomIDs)
        let afterHit = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(afterHit.computationCount == 1)
        #expect(afterHit.hitCount == 1)
        #expect(afterHit.entryCount == 1)

        let publicRequest = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Retain only public context.",
            personaIDHint: "Agent",
            allowedPrivacy: [.publicSafe]
        )
        let publicOnly = try await fixture.coordinator.prepareFrozenTurn(publicRequest)
        #expect(!publicOnly.need.authorization.allowedSourceIDs.contains(correction.descriptor.id))
        #expect(!publicOnly.need.mandatoryAtomIDs.contains(correctionID))
        _ = try await fixture.coordinator.prepareFrozenTurn(publicRequest)
        let isolated = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(isolated.computationCount == 2)
        #expect(isolated.hitCount == 2)
        #expect(isolated.entryCount == 2)
        print(
            "[turn-speed-a4] four preparations performed "
                + "\(isolated.computationCount) generation-derived computations "
                + "and \(isolated.hitCount) cache hits"
        )

        await fixture.coordinator.stop()
        let stopped = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(stopped.entryCount == 0)
        #expect(stopped.invalidationCount == 1)
    }

    @Test
    func generationDerivedSetsIsolateSurfaceEligibilityAndPrecoverage() async throws {
        let chatSource = compiledSource(
            id: "surface-chat",
            owner: "nativeagent.persona",
            locator: "persona/Agent/surfaces/chat.md",
            kind: .identity,
            body: "Chat-only guidance must be precovered only on chat.",
            authority: .identity,
            policy: .always,
            permittedSurfaces: [.chat]
        )
        let bridgeSource = compiledSource(
            id: "surface-bridge",
            owner: "nativeagent.persona",
            locator: "persona/Agent/surfaces/bridge.md",
            kind: .identity,
            body: "Bridge-only guidance must be precovered only on bridge.",
            authority: .identity,
            policy: .always,
            permittedSurfaces: [.bridge]
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [chatSource, bridgeSource],
            mirrorSurfaceVariants: [
                ContextSurfaceVariant(rawValue: "chat"),
                ContextSurfaceVariant(rawValue: "bridge"),
            ]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func request(_ surface: ContextSurface) -> ContextTurnRequest {
            ContextTurnRequest(
                surface: surface,
                origin: .localAuthenticated,
                userMessage: "Select this surface's guidance.",
                personaIDHint: "Agent",
                allowedPrivacy: [.localPrivate]
            )
        }

        let chat = try await fixture.coordinator.prepareFrozenTurn(request(.chat))
        #expect(chat.need.authorization.allowedSourceIDs.contains(chatSource.descriptor.id))
        #expect(!chat.need.authorization.allowedSourceIDs.contains(bridgeSource.descriptor.id))
        #expect(chat.need.precoveredSourceIDs.contains(chatSource.descriptor.id))
        #expect(!chat.need.precoveredSourceIDs.contains(bridgeSource.descriptor.id))

        let bridge = try await fixture.coordinator.prepareFrozenTurn(request(.bridge))
        #expect(bridge.need.authorization.allowedSourceIDs.contains(bridgeSource.descriptor.id))
        #expect(!bridge.need.authorization.allowedSourceIDs.contains(chatSource.descriptor.id))
        #expect(bridge.need.precoveredSourceIDs.contains(bridgeSource.descriptor.id))
        #expect(!bridge.need.precoveredSourceIDs.contains(chatSource.descriptor.id))

        _ = try await fixture.coordinator.prepareFrozenTurn(request(.chat))
        _ = try await fixture.coordinator.prepareFrozenTurn(request(.bridge))
        let metrics = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(metrics.computationCount == 2)
        #expect(metrics.hitCount == 2)
        #expect(metrics.entryCount == 2)
    }

    @Test
    func generationDerivedSetsIsolatePersonaSourcesAndScopeDigests() async throws {
        let agentSource = compiledSource(
            id: "persona-agent",
            owner: "nativeagent.persona",
            locator: "persona/Agent/GROWTH.md",
            kind: .relationship,
            body: "Agent-specific growth context.",
            authority: .identity,
            policy: .adaptive
        )
        let secondarySource = compiledSource(
            id: "persona-secondary",
            owner: "nativeagent.persona",
            locator: "persona/Secondary/GROWTH.md",
            kind: .relationship,
            body: "Secondary-specific growth context.",
            authority: .identity,
            policy: .adaptive
        )
        let agentScopeDigest = ContextStableID.digest(parts: ["agent"])
        let agentScopedMemory = compiledSource(
            id: "memory-agent-scope",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScopeDigest)/record",
            kind: .memory,
            body: "A digest-scoped fixture that must trip only for Agent.",
            authority: .canonical,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentSource, secondarySource, agentScopedMemory],
            additionalMirrorPersonaIDs: [ContextPersonaID(rawValue: "Secondary")]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func request(_ persona: String) -> ContextTurnRequest {
            ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "Select this persona's source set.",
                personaIDHint: persona,
                allowedPrivacy: [.localPrivate]
            )
        }

        let secondary = try await fixture.coordinator.prepareTurn(request("Secondary"))
        #expect(secondary.need.authorization.allowedSourceIDs.contains(secondarySource.descriptor.id))
        #expect(!secondary.need.authorization.allowedSourceIDs.contains(agentSource.descriptor.id))
        #expect(fixture.diagnostics.memoryVocabularyDrift.isEmpty)

        let agent = try await fixture.coordinator.prepareTurn(request("Agent"))
        #expect(agent.need.authorization.allowedSourceIDs.contains(agentSource.descriptor.id))
        #expect(!agent.need.authorization.allowedSourceIDs.contains(secondarySource.descriptor.id))
        let drift = fixture.diagnostics.memoryVocabularyDrift
        #expect(drift.count == 1)
        let driftLine = try #require(drift.first)
        #expect(driftLine.contains(agentScopeDigest))

        _ = try await fixture.coordinator.prepareFrozenTurn(request("Secondary"))
        _ = try await fixture.coordinator.prepareFrozenTurn(request("Agent"))
        let metrics = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(metrics.computationCount == 2)
        #expect(metrics.hitCount == 2)
        #expect(metrics.entryCount == 2)
    }

    @Test
    func generationDerivedCacheKeySeparatesEveryBehaviorDimension() {
        typealias Key = ContextFlowCoordinator.GenerationDerivedCacheKey
        func key(
            generationID: Int64 = 7,
            generationFingerprint: String = "generation-a",
            surface: String = "chat",
            personaID: String = "Agent",
            mirrorFingerprint: String = "mirror-a",
            kernelPersonaID: String = "Agent",
            kernelSurface: String = "chat",
            kernelFingerprint: String = "kernel-a",
            includedDocuments: [String] = ["SOUL.md", "VOICE.md"],
            privacy: [String] = ["local_private"]
        ) -> Key {
            Key(
                generationID: generationID,
                generationSourceFingerprint: generationFingerprint,
                surface: surface,
                personaID: personaID,
                mirrorSourceFingerprint: mirrorFingerprint,
                kernelPersonaID: kernelPersonaID,
                kernelSurface: kernelSurface,
                kernelSourceFingerprint: kernelFingerprint,
                stableIncludedDocumentIDs: includedDocuments,
                allowedPrivacy: privacy
            )
        }
        let baseline = key()
        let variants = [
            key(generationID: 8),
            key(generationFingerprint: "generation-b"),
            key(surface: "bridge"),
            key(personaID: "Secondary"),
            key(mirrorFingerprint: "mirror-b"),
            key(kernelPersonaID: "Secondary"),
            key(kernelSurface: "bridge"),
            key(kernelFingerprint: "kernel-b"),
            key(includedDocuments: ["SOUL.md"]),
            key(privacy: ["public_safe"]),
        ]

        #expect(Set([baseline] + variants).count == variants.count + 1)
    }

    @Test
    func generationChangeClearsDerivedSetsBeforeTheNextTurn() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let request = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Read the current generation.",
            personaIDHint: "Agent",
            allowedPrivacy: [.localPrivate]
        )

        let first = try await fixture.coordinator.prepareFrozenTurn(request)
        #expect(first.generation.generation.id == 1)
        #expect(first.need.authorization.allowedSourceIDs.contains(fixture.sourceID))
        let primed = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(primed.computationCount == 1)
        #expect(primed.entryCount == 1)

        let bridgeOnlyDescriptor = ContextSourceDescriptor(
            id: fixture.sourceID,
            owner: "persona",
            kind: .persona,
            canonicalLocator: fixture.sourceFile.path,
            authority: .identity,
            privacy: .localPrivate,
            permittedSurfaces: [.bridge],
            injectionPolicy: .always
        )
        try await fixture.registry.replace(ContextSourceRegistration(
            descriptor: bridgeOnlyDescriptor,
            fileURL: fixture.sourceFile,
            allowedRoot: fixture.sourceFile.deletingLastPathComponent(),
            requiredPersonaDocument: .soul,
            personaID: ContextPersonaID(rawValue: "Agent")
        ))
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "cache invalidation negative control"
        ))

        let afterPublication = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(afterPublication.invalidationCount == 1)
        #expect(afterPublication.entryCount == 0)
        let second = try await fixture.coordinator.prepareFrozenTurn(request)
        #expect(second.generation.generation.id == 2)
        #expect(!second.need.authorization.allowedSourceIDs.contains(fixture.sourceID))
        let recomputed = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(recomputed.computationCount == 2)
        #expect(recomputed.hitCount == 0)
        #expect(recomputed.invalidationCount == 1)
        #expect(recomputed.entryCount == 1)
    }

    @Test
    func normalPressureRehydratesWarmEntriesFromSameDurableGeneration() async throws {
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nStable identity.",
            warmBody: "# Project\nKeep the recovery plan warm."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let initial = try await fixture.coordinator.acquireSnapshot()
        let generationID = initial.snapshot.generationID
        let warmEntryKeys = initial.snapshot.warmEntries.map(\.key)
        _ = try #require(warmEntryKeys.first)
        initial.release()

        let trim = try await fixture.coordinator.applyMemoryPressure(.critical)
        #expect(trim.evictedWarmEntryKeys == warmEntryKeys)
        #expect(fixture.arena.currentSnapshot()?.warmEntries.isEmpty == true)

        _ = try await fixture.coordinator.applyMemoryPressure(.normal)

        let recovered = try await fixture.coordinator.acquireSnapshot()
        defer { recovered.release() }
        #expect(recovered.snapshot.generationID == generationID)
        #expect(recovered.snapshot.warmEntries.map(\.key) == warmEntryKeys)
        #expect(fixture.arena.metrics().pressure == .normal)
        try await expectNoGenerationMinted(after: generationID, in: fixture.store)
    }

    @Test
    func wakeRehydratesWarmEntriesFromSameDurableGeneration() async throws {
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nStable identity.",
            warmBody: "# Project\nRestore this working set after wake."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let initial = try await fixture.coordinator.acquireSnapshot()
        let generationID = initial.snapshot.generationID
        let warmEntryKeys = initial.snapshot.warmEntries.map(\.key)
        _ = try #require(warmEntryKeys.first)
        initial.release()

        _ = try await fixture.coordinator.applyMemoryPressure(.critical)
        #expect(fixture.arena.currentSnapshot()?.warmEntries.isEmpty == true)

        await fixture.coordinator.reconcileAfterWake()

        let recovered = try await fixture.coordinator.acquireSnapshot()
        defer { recovered.release() }
        #expect(recovered.snapshot.generationID == generationID)
        #expect(recovered.snapshot.warmEntries.map(\.key) == warmEntryKeys)
        #expect(fixture.arena.metrics().pressure == .normal)
        try await expectNoGenerationMinted(after: generationID, in: fixture.store)
    }

    @Test
    func offModeDoesNotCompileOrStartWatchers() async throws {
        let fixture = try await makeFixture(mode: .off, body: "# Core\nIdentity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let health = await fixture.coordinator.health()
        #expect(health.mode == .off)
        #expect(health.started)
        #expect(health.activeStoreGenerationID == nil)
        #expect(health.activeArenaGenerationID == nil)
    }

}
