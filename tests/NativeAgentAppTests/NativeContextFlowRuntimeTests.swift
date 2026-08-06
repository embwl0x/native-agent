import Context
import Foundation
import MemoryV2
import PersonaEngine
import PersistenceCore
import Testing
import WorkshopExecution
@testable import NativeAgentApp

private actor DelayedEmbeddingGate {
    private var delay: Duration = .zero
    private var calls = 0

    func setDelay(_ delay: Duration) {
        self.delay = delay
    }

    func embed(_ texts: [String], dimensions: Int) async -> [[Float]] {
        calls += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            let bucket = text.utf8.reduce(0) { ($0 + Int($1)) % dimensions }
            vector[bucket] = 1
            return vector
        }
    }

    func callCount() -> Int { calls }
}

private struct DelayedEmbeddingProvider: EmbeddingProvider {
    let dimensions = 8
    let modelId = "delayed-test-embedding"
    let gate: DelayedEmbeddingGate

    func embed(_ texts: [String]) async throws -> [[Float]] {
        await gate.embed(texts, dimensions: dimensions)
    }
}

private struct ContextFlowConfigurationFixture {
    let dataRoot: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        let identifier = UUID().uuidString
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeContextFlowRuntimeTests-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataRoot,
            withIntermediateDirectories: true
        )

        suiteName = "NativeContextFlowRuntimeTests.\(identifier)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dataRoot)
    }

    func completeOnboarding() throws {
        try "completed\n".write(
            to: dataRoot.appendingPathComponent(".onboarded"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@Suite("NativeContextFlow production configuration")
struct NativeContextFlowRuntimeTests {
    @Test("resident work re-enters relevant turns on evidence and restart without model settlement")
    func residentWorkReentryIsEventDrivenRelevantAndRestartSafe() async throws {
        let fixture = try ContextFlowConfigurationFixture()
        defer { fixture.cleanUp() }
        let personaRoot = fixture.dataRoot.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try Data("# SOUL\nAgent is one continuous mind.".utf8)
            .write(to: personaRoot.appendingPathComponent("SOUL.md"))
        try Data("# VOICE\nSpeak plainly and truthfully.".utf8)
            .write(to: personaRoot.appendingPathComponent("VOICE.md"))

        let desk = SwiftNativeDeskStore(dataRoot: fixture.dataRoot)
        let item = try await desk.createItem(
            kind: .project,
            project: "Orchid Lighthouse",
            title: "Calibrate the orchid lighthouse beacon",
            summary: "Prove the beacon calibration from exact local evidence"
        )
        _ = try await desk.setStatus(item.handle, status: .now)

        let executionID = "exec-resident-\(UUID().uuidString)"
        let createdAt = SwiftNativeWorkshopRunner.isoTimestamp(Date())
        let step = WorkshopExecutionStep(
                id: "verify-beacon",
                description: "verify the local beacon artifact",
                toolOrAction: "filesystem.read"
        )
        let queuedObject: [String: JSONValue] = [
            "id": .string(executionID),
            "desk_handle": .string(item.handle),
            "title": .string("Calibrate the orchid lighthouse beacon"),
            "objective": .string("Prove the beacon calibration from exact local evidence"),
            "created_at": .string(createdAt),
            "status": .string("queued"),
            "plan": .array([step.toJSON()]),
            "steps_completed": .array([]),
            "receipts_dir": .string(""),
            "trigger_source": .string("directed_task"),
            "trust_required": .string("none"),
            "expected_outputs": .array([]),
            "current_step_id": .string("verify-beacon"),
            "updated_at": .string(createdAt),
            "result": .null,
            "rerun_count": .int(0),
            "planning_provider_call_count": .int(0),
            "planning_removable_orchestration_provider_call_count": .int(0),
        ]
        let missionPath = fixture.dataRoot
            .appendingPathComponent("workshop/executions/\(executionID)", isDirectory: true)
            .appendingPathComponent("execution.json")
        try FileManager.default.createDirectory(
            at: missionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.writeJSON(.object(queuedObject), to: missionPath)
        let initialProjection = try await NativeResidentWorkContextProjection(
            dataRoot: fixture.dataRoot
        ).compiledProjection(previousSources: [:])
        #expect(initialProjection.changedSources.count == 1)

        func makeRuntime() -> NativeContextFlowRuntime {
            NativeContextFlowRuntime(
                dataRoot: fixture.dataRoot,
                configurationOverride: NativeContextFlowConfiguration(
                    mode: .active,
                    budget: .mib32
                ),
                memoryOverride: SwiftNativeMemoryV2(
                    embedder: DelayedEmbeddingProvider(gate: DelayedEmbeddingGate()),
                    storage: InMemoryMemoryStorage()
                )
            )
        }
        func residentText(_ runtime: NativeContextFlowRuntime, query: String) async throws -> String {
            let prepared = try await runtime.prepareContextTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: query,
                personaIDHint: "Agent"
            ))
            return prepared.packet.selectedItems
                .filter { $0.pointer.kind == .runtimeTruth }
                .map(\.text)
                .joined(separator: "\n")
        }

        let runtime = makeRuntime()
        await runtime.start()
        let initialHealth = try #require(await runtime.health())
        #expect(initialHealth.started == true)
        #expect(initialHealth.activeStoreGenerationID != nil, Comment(rawValue: initialHealth.lastError ?? "missing generation"))

        let unrelated = try await residentText(
            runtime,
            query: "Explain the phases of the moon."
        )
        #expect(unrelated.isEmpty)

        let queued = try await residentText(
            runtime,
            query: "What is happening with the orchid lighthouse beacon?"
        )
        #expect(queued.contains("Desk handle: \(item.handle)"))
        #expect(queued.contains("Workshop status: queued"))
        #expect(queued.contains("Decision need: quiet_wait"))

        let completedAt = SwiftNativeWorkshopRunner.isoTimestamp(Date().addingTimeInterval(1))
        var completedObject = queuedObject
        completedObject["status"] = .string("completed")
        completedObject["steps_completed"] = .array([.object([
            "step_id": .string("verify-beacon"),
            "status": .string("succeeded"),
        ])])
        completedObject["current_step_id"] = .string("")
        completedObject["updated_at"] = .string(completedAt)
        completedObject["result"] = .string("Beacon calibration matched the local artifact")
        completedObject["verification"] = WorkshopVerificationRecord(
            status: .satisfied,
            checkedAt: completedAt,
            methods: ["exact_local_evidence"],
            detail: "Calibration matched the canonical local artifact."
        ).toJSON()
        try await persistence.writeJSON(.object(completedObject), to: missionPath)
        let completedExecution = try #require(
            await SwiftNativeWorkshopRunner(root: fixture.dataRoot)
                .getWorkshopExecution(executionID)
        )
        await WorkshopDeskReceiptBridge.recordTerminal(
            completedExecution,
            reason: nil,
            dataRoot: fixture.dataRoot
        )

        var settled = ""
        for _ in 0..<100 {
            settled = try await residentText(
                runtime,
                query: "Did the orchid lighthouse beacon calibration finish?"
            )
            if settled.contains("Desk status: done")
                && settled.contains("Verification: satisfied") {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(settled.contains("Desk status: done"))
        #expect(settled.contains("Workshop status: completed"))
        #expect(settled.contains("Verification: satisfied"))
        #expect(settled.contains("Decision need: none"))
        #expect(completedExecution.planningProviderCallCount == 0)

        await runtime.stop()
        let restarted = makeRuntime()
        await restarted.start()
        let afterRestart = try await residentText(
            restarted,
            query: "Recall the orchid lighthouse beacon result."
        )
        #expect(afterRestart.contains("Desk status: done"))
        #expect(afterRestart.contains("Verification: satisfied"))
        #expect(afterRestart.contains("Beacon calibration matched the local artifact"))
        await restarted.stop()
    }

    @Test("semantic query embedding is opportunistic, bounded, and cached")
    func semanticQueryEmbeddingNeverAddsForegroundWait() async throws {
        let fixture = try ContextFlowConfigurationFixture()
        let gate = DelayedEmbeddingGate()
        let memory = SwiftNativeMemoryV2(
            embedder: DelayedEmbeddingProvider(gate: gate),
            storage: InMemoryMemoryStorage()
        )
        let runtime = NativeContextFlowRuntime(
            dataRoot: fixture.dataRoot,
            configurationOverride: NativeContextFlowConfiguration(
                mode: .active,
                budget: .mib32
            ),
            memoryOverride: memory
        )
        await runtime.start()
        guard await runtime.health()?.started == true else {
            await runtime.stop()
            fixture.cleanUp()
            Issue.record("ContextFlow fixture did not start")
            return
        }

        let callsBeforeQuery = await gate.callCount()
        // The gate delay is a deliberate wedge: long enough that the foreground
        // bound below proves beginQueryEmbedding never awaited the embedder,
        // even with multi-second scheduler noise under full-suite parallelism.
        // (The old 200ms delay + fixed 250ms wait made the ready-check a
        // roving flake: the background embed routinely missed the window.)
        await gate.setDelay(.seconds(5))
        let clock = ContinuousClock()
        let startedAt = clock.now
        let ticket = await runtime.beginQueryEmbedding("remember the jasmine drink")
        let foregroundElapsed = startedAt.duration(to: clock.now)

        #expect(ticket != nil)
        // 2s, not 100ms: the claim is "the foreground return did not await the
        // 5s embed" — well below the wedge still proves that, while a tight
        // bound loses to scheduler noise under full-suite parallelism.
        #expect(foregroundElapsed < .seconds(2))
        #expect(ticket?.embeddingIfReady == nil)
        // Positive step (the embedding SHOULD land) polls with a generous
        // deadline instead of a fixed sleep — the 5s gate plus task scheduling
        // has no fixed upper bound under load.
        let readyDeadline = clock.now.advanced(by: .seconds(20))
        while ticket?.embeddingIfReady == nil, clock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(ticket?.embeddingIfReady?.count == 8)
        #expect(await gate.callCount() == callsBeforeQuery + 1)
        print("[memory-quality-metric] semantic-foreground=\(foregroundElapsed)")

        let cached = await runtime.beginQueryEmbedding("remember   the JASMINE drink")
        #expect(cached?.embeddingIfReady == ticket?.embeddingIfReady)
        #expect(await gate.callCount() == callsBeforeQuery + 1)

        await runtime.stop()
        fixture.cleanUp()
    }

    @Test("bridge state exposes bounded ContextFlow health")
    func bridgeStateExposesContextFlowHealth() throws {
        let arena = try ContextArena(budget: .mib32)
        let health = ContextFlowCoordinatorHealth(
            mode: .active,
            started: true,
            activeStoreGenerationID: 8,
            activeArenaGenerationID: 8,
            registeredSourceCount: 14,
            degradedSourceCount: 0,
            arenaMetrics: arena.metrics(),
            pendingPrewarmHints: 2,
            prewarmUsefulnessReceipts: 3,
            lastReconciledAt: Date(timeIntervalSince1970: 1_000),
            lastError: nil
        )

        let json = ClaudeBridge.contextFlowHealthJSON(mode: .active, health: health)

        #expect(json["mode"] as? String == "active")
        #expect(json["started"] as? Bool == true)
        #expect(json["storeGeneration"] as? Int64 == 8)
        #expect(json["arenaGeneration"] as? Int64 == 8)
        #expect(json["registeredSources"] as? Int == 14)
        #expect(json["degradedSources"] as? Int == 0)
        #expect(json["residentBytes"] as? Int == 0)
        #expect(json["pendingPrewarmHints"] as? Int == 2)
        #expect(json["prewarmUsefulnessReceipts"] as? Int == 3)
        #expect(json["lastError"] is NSNull)
    }

    @Test("active kernels keep SOUL and VOICE while broad documents remain mirrored")
    func activeKernelIsNarrowAndMirrorIsComplete() throws {
        let root = URL(fileURLWithPath: "/tmp/persona")
        let documents = [
            personaDocument("SOUL", "identity", order: 0, root: root),
            personaDocument("VOICE", "voice", order: 1, root: root),
            personaDocument("USER", "relationship", order: 2, root: root),
            personaDocument("GROWTH", "growth", order: 3, root: root),
            personaDocument("AGENTS", "operations", order: 5, root: root),
            personaDocument(
                "surface:chat",
                "chat guidance",
                order: 6,
                root: root,
                surfaceOverride: true
            ),
        ]
        let packet = PersonalityPacket(
            surface: "chat",
            personaKind: "Default",
            personaId: "canonical",
            fingerprint: "packet",
            compiledSystemPrompt: documents.map { $0.content }.joined(separator: "\n"),
            activeDocs: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.content) }),
            traits: [:]
        )
        let snapshot = PersonaContextSourceSnapshot(
            packet: packet,
            personaRoot: root,
            activePersonaDirectory: nil,
            documents: documents,
            watchedDirectories: [root]
        )

        let mirror = try PersonaContextFlowProvider.makeMirror(
            personaID: "canonical",
            snapshots: [snapshot],
            mode: .active
        )
        let kernel = try #require(mirror.kernel(for: ContextSurfaceVariant(rawValue: "chat")))

        #expect(mirror.documents.map(\.id.rawValue) == [
            "SOUL.md", "VOICE.md", "USER.md", "GROWTH.md", "AGENTS.md",
        ])
        #expect(kernel.includedDocumentIDs.map(\.rawValue) == ["SOUL.md", "VOICE.md"])
        #expect(kernel.renderedPrompt.contains("# SOUL\nidentity"))
        #expect(kernel.renderedPrompt.contains("# VOICE\nvoice"))
        #expect(kernel.renderedPrompt.contains("chat guidance"))
        #expect(!kernel.renderedPrompt.contains("relationship"))
        #expect(!kernel.renderedPrompt.contains("growth"))
        #expect(!kernel.renderedPrompt.contains("operations"))
    }

    @Test("persona injection policy keeps identity stable and selects broad documents")
    func personaInjectionPolicySeparatesStableAndSelectedDocuments() {
        #expect(PersonaContextFlowProvider.injectionPolicy(for: "SOUL") == .always)
        #expect(PersonaContextFlowProvider.injectionPolicy(for: "VOICE") == .always)
        #expect(PersonaContextFlowProvider.injectionPolicy(for: "surface:telegram") == .always)
        #expect(PersonaContextFlowProvider.injectionPolicy(for: "USER") == .adaptive)
        #expect(PersonaContextFlowProvider.injectionPolicy(for: "GROWTH") == .adaptive)
        #expect(PersonaContextFlowProvider.injectionPolicy(for: "AGENTS") == .adaptive)
    }

    @Test("active stable kernel is at least 40 percent smaller than the canonical prompt")
    func activeKernelMeetsStableByteReductionGate() throws {
        let root = URL(fileURLWithPath: "/tmp/persona")
        let documents = [
            personaDocument("SOUL", String(repeating: "identity ", count: 45), order: 0, root: root),
            personaDocument("VOICE", String(repeating: "voice ", count: 45), order: 1, root: root),
            personaDocument("USER", String(repeating: "relationship ", count: 120), order: 2, root: root),
            personaDocument("GROWTH", String(repeating: "growth ", count: 160), order: 3, root: root),
            personaDocument("AGENTS", String(repeating: "procedure ", count: 140), order: 5, root: root),
            personaDocument(
                "surface:chat",
                String(repeating: "chat ", count: 20),
                order: 6,
                root: root,
                surfaceOverride: true
            ),
        ]
        let fullPrompt = documents.map(\.content).joined(separator: "\n\n")
        let snapshot = PersonaContextSourceSnapshot(
            packet: PersonalityPacket(
                surface: "chat",
                personaKind: "Default",
                personaId: "canonical",
                fingerprint: "packet",
                compiledSystemPrompt: fullPrompt,
                activeDocs: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.content) }),
                traits: [:]
            ),
            personaRoot: root,
            activePersonaDirectory: nil,
            documents: documents,
            watchedDirectories: [root]
        )

        let mirror = try PersonaContextFlowProvider.makeMirror(
            personaID: "canonical",
            snapshots: [snapshot],
            mode: .active
        )
        let kernel = try #require(mirror.kernel(for: ContextSurfaceVariant(rawValue: "chat")))
        let reduction = 1 - (Double(kernel.utf8ByteCount) / Double(fullPrompt.utf8.count))

        #expect(reduction >= 0.40)
        #expect(kernel.tokenCount == max(1, (kernel.utf8ByteCount + 3) / 4))
        print(
            "[fluid-context-metric] stable-kernel full=\(fullPrompt.utf8.count)B "
                + "active=\(kernel.utf8ByteCount)B reduction=\(reduction)"
        )
    }

    @Test("public pre-onboarding forces ContextFlow off despite explicit active")
    func publicPreOnboardingForcesOff() throws {
        let fixture = try ContextFlowConfigurationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(
            ContextFlowMode.active.rawValue,
            forKey: NativeContextFlowConfiguration.modeDefaultsKey
        )

        let configuration = NativeContextFlowConfiguration.resolve(
            dataRoot: fixture.dataRoot,
            environment: [
                NativeContextFlowConfiguration.modeEnvironmentKey:
                    ContextFlowMode.active.rawValue
            ],
            defaults: fixture.defaults,
            publicSafeMode: true
        )

        #expect(configuration.mode == .off)
    }

    @Test("onboarded public installs default ContextFlow to shadow")
    func onboardedPublicDefaultsToShadow() throws {
        let fixture = try ContextFlowConfigurationFixture()
        defer { fixture.cleanUp() }
        try fixture.completeOnboarding()

        let configuration = NativeContextFlowConfiguration.resolve(
            dataRoot: fixture.dataRoot,
            environment: [:],
            defaults: fixture.defaults,
            publicSafeMode: true
        )

        #expect(configuration.mode == .shadow)
    }

    @Test(
        "explicit off, shadow, and active modes are honored",
        arguments: ContextFlowMode.allCases
    )
    func explicitModesAreHonored(mode: ContextFlowMode) throws {
        let fixture = try ContextFlowConfigurationFixture()
        defer { fixture.cleanUp() }

        fixture.defaults.set(
            mode.rawValue,
            forKey: NativeContextFlowConfiguration.modeDefaultsKey
        )
        let storedConfiguration = NativeContextFlowConfiguration.resolve(
            dataRoot: fixture.dataRoot,
            environment: [:],
            defaults: fixture.defaults,
            publicSafeMode: false
        )
        #expect(storedConfiguration.mode == mode)

        let competingStoredMode: ContextFlowMode = mode == .active ? .off : .active
        fixture.defaults.set(
            competingStoredMode.rawValue,
            forKey: NativeContextFlowConfiguration.modeDefaultsKey
        )
        let environmentConfiguration = NativeContextFlowConfiguration.resolve(
            dataRoot: fixture.dataRoot,
            environment: [
                NativeContextFlowConfiguration.modeEnvironmentKey: mode.rawValue
            ],
            defaults: fixture.defaults,
            publicSafeMode: false
        )
        #expect(environmentConfiguration.mode == mode)
    }

    @Test("invalid ContextFlow RAM budget defaults to 96 MiB")
    func invalidBudgetDefaultsTo96MiB() throws {
        let fixture = try ContextFlowConfigurationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(95, forKey: NativeContextFlowConfiguration.budgetDefaultsKey)

        let configuration = NativeContextFlowConfiguration.resolve(
            dataRoot: fixture.dataRoot,
            environment: [:],
            defaults: fixture.defaults,
            publicSafeMode: false
        )

        #expect(configuration.budget == .mib96)
        #expect(configuration.budget.rawValue == 96)
    }

    @Test(
        "approved ContextFlow RAM budgets are honored",
        arguments: ContextArenaBudget.allCases
    )
    func approvedBudgetsAreHonored(budget: ContextArenaBudget) throws {
        let fixture = try ContextFlowConfigurationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(
            budget.rawValue,
            forKey: NativeContextFlowConfiguration.budgetDefaultsKey
        )

        let configuration = NativeContextFlowConfiguration.resolve(
            dataRoot: fixture.dataRoot,
            environment: [:],
            defaults: fixture.defaults,
            publicSafeMode: false
        )

        #expect(configuration.budget == budget)
    }
}

private func personaDocument(
    _ id: String,
    _ content: String,
    order: Int,
    root: URL,
    surfaceOverride: Bool = false
) -> PersonaContextDocumentSource {
    PersonaContextDocumentSource(
        id: id,
        fileURL: root.appendingPathComponent("\(id).md"),
        content: content,
        canonicalOrder: order,
        optional: false,
        surfaceOverride: surfaceOverride
    )
}
