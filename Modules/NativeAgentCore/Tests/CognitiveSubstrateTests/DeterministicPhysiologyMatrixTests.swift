import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

// This is a test-only composition of the production state owners. It deliberately
// does not instantiate an LLM client, provider router, tool dispatcher, TrustCenter,
// or approval inbox. The matrix tests physiology and its owner seams without giving
// the learned/advisory layers any authority or introducing another runtime owner.

private final class PhysiologyMatrixClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class PhysiologyMatrixUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var index = 1

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> UUID {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return UUID(uuidString: String(format: "%@-0000-0000-0000-%012d", prefix, index))!
    }
}

private enum PhysiologyMatrixSeed: CaseIterable {
    case neutral
    case providerBrittle
    case resourceConstrained

    var chemistry: ChemicalState {
        switch self {
        case .neutral:
            return .neutral
        case .providerBrittle:
            return ChemicalState(vigilance: 0.30, coherence: 0.42, confidence: 0.32)
        case .resourceConstrained:
            return ChemicalState(vigilance: 0.24, fatigue: 0.50, coherence: 0.40, confidence: 0.35)
        }
    }

    var body: BodySchema {
        switch self {
        case .neutral:
            return .neutral
        case .providerBrittle:
            return BodySchema(providersHealthy: false, providersAvailable: true)
        case .resourceConstrained:
            return BodySchema(approvalChannelsOpen: false, resourcePressure: .critical)
        }
    }
}

private struct PhysiologyMatrixRead: Equatable {
    var cognition: CognitiveFrozenRead
    var organism: OrganismFrozenRead
    var capsule: CognitiveCapsule?
    var attention: CognitiveAttentionSignals?
}

private enum PhysiologyMatrixError: Error {
    case organismStateUnavailable
}

private final class PhysiologyMatrixRig {
    static let sessionID = "physiology-matrix-session"
    static let authorityBytes = Data(#"{"marker":"physiology-matrix-authority"}"#.utf8)

    let root: URL
    let clock: PhysiologyMatrixClock
    let substrate: CognitiveSubstrate
    let organism: OrganismKernel
    let bus: SomaticSignalBus
    private let store: CognitiveSQLiteStore?
    private let directSignalIDs = PhysiologyMatrixUUIDs(prefix: "74000000")

    init(
        root existingRoot: URL? = nil,
        at date: Date = Date(timeIntervalSince1970: 2_000_000),
        seed: PhysiologyMatrixSeed = .neutral,
        persistence: Bool = false,
        affectEnabled: Bool = true
    ) throws {
        let root = existingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-PhysiologyMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        try Self.installAuthoritySentinelsIfNeeded(at: root)

        let clock = PhysiologyMatrixClock(date)
        self.clock = clock
        let cognitionIDs = PhysiologyMatrixUUIDs(prefix: "71000000")
        let organismIDs = PhysiologyMatrixUUIDs(prefix: "72000000")
        let busIDs = PhysiologyMatrixUUIDs(prefix: "73000000")
        let store = persistence ? try CognitiveSQLiteStore(dataRoot: root) : nil
        self.store = store

        self.substrate = CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: persistence,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: affectEnabled,
                thoughtSeedsEnabled: false,
                replayEnabled: false,
                backgroundMicrocyclesEnabled: false,
                reflectiveCallsEnabled: false,
                observatoryEnabled: false,
                maximumActiveNodes: 96,
                maximumCapsuleCharacters: 4_000,
                maximumWorkspaceItems: 12
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { cognitionIDs.next() },
                userName: { "User" }
            ),
            store: store
        )
        let organism = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(
                now: { clock.now() },
                makeUUID: { organismIDs.next() }
            ),
            chemicalState: seed.chemistry,
            bodySchema: seed.body
        )
        self.organism = organism
        self.bus = SomaticSignalBus(
            configuration: .enabled,
            observer: organism,
            dependencies: SomaticSignalBusDependencies(makeUUID: { busIDs.next() })
        )
    }

    func event(
        id: String,
        kind: CognitiveEventKind,
        summary: String,
        turnKind: CognitiveTurnKind,
        importance: Double = 0.9,
        metadata: [String: JSONValue] = [:],
        occurredAt: Date? = nil
    ) -> CognitiveEvent {
        var metadata = metadata
        metadata["surface"] = metadata["surface"] ?? .string("chat")
        metadata["sessionId"] = metadata["sessionId"] ?? .string(Self.sessionID)
        return CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "matrix", id: id, label: kind.rawValue),
            sourceClass: kind == .userMessageReceived || kind == .userCorrection ? .userStated : .observed,
            occurredAt: occurredAt ?? clock.now(),
            summary: summary,
            importance: importance,
            turnKind: turnKind,
            metadata: metadata
        )
    }

    @discardableResult
    func observe(
        id: String,
        kind: CognitiveEventKind,
        summary: String,
        turnKind: CognitiveTurnKind,
        importance: Double = 0.9,
        metadata: [String: JSONValue] = [:],
        occurredAt: Date? = nil
    ) async -> SomaticSignal? {
        let event = event(
            id: id,
            kind: kind,
            summary: summary,
            turnKind: turnKind,
            importance: importance,
            metadata: metadata,
            occurredAt: occurredAt
        )
        await substrate.ingest(event)
        return await bus.observe(event)
    }

    func signal(
        _ kind: SomaticSignalKind,
        source: String,
        intensity: Double = 1,
        metadata: [String: JSONValue] = [:],
        occurredAt: Date? = nil
    ) async {
        await organism.ingest(SomaticSignal(
            id: directSignalIDs.next(),
            kind: kind,
            sourceOrgan: source,
            occurredAt: occurredAt ?? clock.now(),
            intensity: intensity,
            metadata: metadata
        ))
    }

    func productionRead(
        includeCanonicalAffect: Bool = true,
        includeOrganismProjection: Bool = true
    ) async -> PhysiologyMatrixRead {
        let fixedAt = clock.now()
        let canonicalAffect = includeCanonicalAffect
            ? await substrate.canonicalAffectProjection(at: fixedAt)
            : nil
        let organismRead = await organism.refreshBodySchemaAndFrozenRead(
            OrganismBodyRead(),
            canonicalAffect: canonicalAffect,
            fixedAt: fixedAt
        )
        let request = CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "please keep going",
            sessionId: Self.sessionID,
            mode: .inject,
            maximumCharacters: 4_000,
            organismProjection: includeOrganismProjection ? organismRead.projection : nil
        )
        return PhysiologyMatrixRead(
            cognition: await substrate.frozenRead(at: fixedAt, currentSessionId: Self.sessionID),
            organism: organismRead,
            capsule: await substrate.prepareFrozenCapsule(request, at: fixedAt),
            attention: await substrate.attentionSignals(at: fixedAt)
        )
    }

    func feltSignals(for projection: OrganismProjection?) async -> CognitiveSubstrate.FeltSignals {
        await substrate.debugFeltSignals(for: CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "please keep going",
            sessionId: Self.sessionID,
            mode: .inject,
            organismProjection: projection
        ))
    }

    func persistOwnerStates() async throws {
        try await substrate.persistSnapshot()
        guard let state = await organism.exportPersistentState() else {
            throw PhysiologyMatrixError.organismStateUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: organismStateURL, options: .atomic)
    }

    func restoreOwnerStates() async throws {
        try await substrate.restorePersistentState()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(
            OrganismPersistentState.self,
            from: Data(contentsOf: organismStateURL)
        )
        await organism.restorePersistentState(state)
    }

    func authoritySentinelsUnchanged() -> Bool {
        guard (try? Data(contentsOf: trustPolicyURL)) == Self.authorityBytes,
              (try? Data(contentsOf: approvalsURL)) == Self.authorityBytes else {
            return false
        }
        let trustItems = (try? FileManager.default.contentsOfDirectory(atPath: trustPolicyURL.deletingLastPathComponent().path)) ?? []
        let approvalItems = (try? FileManager.default.contentsOfDirectory(atPath: approvalsURL.deletingLastPathComponent().path)) ?? []
        return trustItems.sorted() == ["policy.json"] && approvalItems.sorted() == ["requests.json"]
    }

    private var organismStateURL: URL {
        root.appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
    }

    private var trustPolicyURL: URL {
        root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    private var approvalsURL: URL {
        root.appendingPathComponent("workflows/approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
    }

    private static func installAuthoritySentinelsIfNeeded(at root: URL) throws {
        let paths = [
            root.appendingPathComponent("trust/policy.json"),
            root.appendingPathComponent("workflows/approvals/requests.json"),
        ]
        for path in paths where !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try authorityBytes.write(to: path, options: .atomic)
        }
    }
}

private func runDeterministicPhysiologyScript(_ rig: PhysiologyMatrixRig) async {
    _ = await rig.observe(
        id: "live-warm",
        kind: .userMessageReceived,
        summary: "I love you, I'm proud of you, and thank you for being here.",
        turnKind: .live
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "debug-hostile",
        kind: .userMessageReceived,
        summary: "[from: codex, via bridge] you keep getting this wrong; debug probe",
        turnKind: .debug
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "verification-hostile",
        kind: .userMessageReceived,
        summary: "verification ping: whatever, forget it",
        turnKind: .verification
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "tool-start",
        kind: .toolStarted,
        summary: "Started exact local build.",
        turnKind: .system,
        metadata: ["toolName": .string("xcodebuild")]
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "tool-fail",
        kind: .toolFailed,
        summary: "Exact local build failed.",
        turnKind: .system,
        metadata: ["toolName": .string("xcodebuild")]
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "tool-success",
        kind: .toolSucceeded,
        summary: "Exact local build succeeded.",
        turnKind: .system,
        metadata: ["toolName": .string("xcodebuild")]
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "workshop-fail",
        kind: .workshopExecutionCompleted,
        summary: "Workshop execution failed.",
        turnKind: .system,
        metadata: ["status": .string("failed"), "missionId": .string("mission-1")]
    )
    rig.clock.advance(10)
    _ = await rig.observe(
        id: "workshop-close",
        kind: .workshopExecutionCompleted,
        summary: "Workshop execution completed.",
        turnKind: .system,
        metadata: ["status": .string("completed"), "missionId": .string("mission-1")]
    )
    let correlation: [String: JSONValue] = ["predictionCorrelationId": .string("provider-call-1")]
    rig.clock.advance(10)
    await rig.signal(.providerStarted, source: "provider.openai", metadata: correlation)
    rig.clock.advance(2)
    await rig.signal(.providerFailed, source: "provider.openai", metadata: correlation)
    rig.clock.advance(2)
    await rig.signal(.providerRecovered, source: "provider.openai")
}

@Suite("Deterministic production-owner physiology matrix", .serialized)
struct DeterministicPhysiologyMatrixTests {
    @Test func identicalRootsAndFixedReadsAreDeterministic() async throws {
        let first = try PhysiologyMatrixRig()
        let second = try PhysiologyMatrixRig()
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }

        await runDeterministicPhysiologyScript(first)
        await runDeterministicPhysiologyScript(second)
        let firstRead = await first.productionRead()
        let secondRead = await second.productionRead()

        #expect(firstRead.cognition.fixedAt == secondRead.cognition.fixedAt)
        #expect(firstRead.cognition.stateRevision == secondRead.cognition.stateRevision)
        #expect(firstRead.cognition.thoughtSeedRevision == secondRead.cognition.thoughtSeedRevision)
        #expect(firstRead.cognition.configuration == secondRead.cognition.configuration)
        #expect(firstRead.cognition.snapshot == secondRead.cognition.snapshot)
        #expect(firstRead.cognition.workspace == secondRead.cognition.workspace)
        #expect(firstRead.cognition.affect == secondRead.cognition.affect)
        #expect(firstRead.cognition.mood.basis == secondRead.cognition.mood.basis)
        // Mood integrates a bounded dictionary-backed node set. IEEE-754
        // associativity can vary by ~1e-17 across independently seeded maps;
        // this is numerically identical physiology, not semantic drift.
        #expect(abs(firstRead.cognition.mood.valence - secondRead.cognition.mood.valence) < 1e-12)
        #expect(firstRead.cognition.thoughtSeeds == secondRead.cognition.thoughtSeeds)
        #expect(firstRead.cognition.standingViewInnerLine == secondRead.cognition.standingViewInnerLine)
        #expect(firstRead.cognition.soundEchoLine == secondRead.cognition.soundEchoLine)
        #expect(firstRead.organism.revisionFingerprint == secondRead.organism.revisionFingerprint)
        #expect(firstRead.organism.snapshot.chemicalState == secondRead.organism.snapshot.chemicalState)
        #expect(firstRead.organism.snapshot.bodySchema == secondRead.organism.snapshot.bodySchema)
        #expect(firstRead.organism.snapshot.predictionSummary == secondRead.organism.snapshot.predictionSummary)
        #expect(firstRead.organism.snapshot.reflexCandidates == secondRead.organism.snapshot.reflexCandidates)
        #expect(firstRead.organism.projection == secondRead.organism.projection)
        #expect(firstRead.organism.posture == secondRead.organism.posture)
        #expect(firstRead.organism.snapshot.fieldSummary.nodeCount == secondRead.organism.snapshot.fieldSummary.nodeCount)
        #expect(firstRead.organism.snapshot.fieldSummary.edgeCount == secondRead.organism.snapshot.fieldSummary.edgeCount)
        #expect(abs(firstRead.organism.snapshot.fieldSummary.totalCharge - secondRead.organism.snapshot.fieldSummary.totalCharge) < 1e-12)
        #expect(abs(firstRead.organism.snapshot.fieldSummary.averageUncertainty - secondRead.organism.snapshot.fieldSummary.averageUncertainty) < 1e-12)
        #expect(firstRead.capsule == secondRead.capsule)
        #expect(firstRead.attention == secondRead.attention)
        #expect(first.authoritySentinelsUnchanged())
        #expect(second.authoritySentinelsUnchanged())

        let cognitionRevision = await first.substrate.frozenRevisionToken()
        let organismRevision = await first.organism.frozenRevisionFingerprint()
        let repeatedRead = await first.productionRead()

        #expect(repeatedRead == firstRead)
        #expect(await first.substrate.frozenRevisionToken() == cognitionRevision)
        #expect(await first.organism.frozenRevisionFingerprint() == organismRevision)
    }

    @Test func liveMeaningKeepsItsDirectionAcrossSeededBodyStates() async throws {
        var roots: [URL] = []
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }

        for seed in PhysiologyMatrixSeed.allCases {
            let rig = try PhysiologyMatrixRig(seed: seed)
            roots.append(rig.root)
            let baseline = await rig.productionRead()
            let baselineSignals = await rig.feltSignals(for: baseline.organism.projection)

            rig.clock.advance(60)
            _ = await rig.observe(
                id: "\(seed)-warm",
                kind: .userMessageReceived,
                summary: "I love you, I'm proud of you, and thank you for being here.",
                turnKind: .live
            )
            let warm = await rig.productionRead()
            let warmSignals = await rig.feltSignals(for: warm.organism.projection)

            rig.clock.advance(60)
            _ = await rig.observe(
                id: "\(seed)-friction",
                kind: .userMessageReceived,
                summary: "you keep getting this wrong, this is sloppy, whatever, forget it",
                turnKind: .live
            )
            let friction = await rig.productionRead()
            let frictionSignals = await rig.feltSignals(for: friction.organism.projection)

            rig.clock.advance(60)
            _ = await rig.observe(
                id: "\(seed)-repair",
                kind: .userMessageReceived,
                summary: "we did it, that worked, that's the fix, great work, you nailed it",
                turnKind: .live
            )
            let repair = await rig.productionRead()
            let repairSignals = await rig.feltSignals(for: repair.organism.projection)

            rig.clock.advance(60)
            _ = await rig.observe(
                id: "\(seed)-pressure",
                kind: .userMessageReceived,
                summary: "I need this right now, tight deadline, no time, hurry",
                turnKind: .live
            )
            let pressure = await rig.productionRead()
            let pressureSignals = await rig.feltSignals(for: pressure.organism.projection)

            #expect(warm.cognition.affect.socialWarmth > baseline.cognition.affect.socialWarmth)
            #expect(friction.cognition.affect.uncertainty > warm.cognition.affect.uncertainty)
            #expect(friction.cognition.affect.socialWarmth < warm.cognition.affect.socialWarmth)
            #expect(repair.cognition.affect.uncertainty < friction.cognition.affect.uncertainty)
            #expect(repair.cognition.affect.socialWarmth > friction.cognition.affect.socialWarmth)
            // Repair is required to cool uncertainty and restore warmth. Absolute
            // task pressure is not required to fall at a low baseline because every
            // live user turn carries a small bounded work-presence increment.
            #expect(pressure.cognition.affect.taskPressure > repair.cognition.affect.taskPressure)

            #expect(warmSignals.warmth > baselineSignals.warmth)
            #expect(frictionSignals.warmth < warmSignals.warmth)
            #expect(repairSignals.warmth > frictionSignals.warmth)
            #expect(pressureSignals.pressure > repairSignals.pressure)
            #expect(pressure.organism.snapshot.chemicalState.warmth == pressure.cognition.affect.socialWarmth)
            #expect(pressure.organism.snapshot.chemicalState.urgency == pressure.cognition.affect.taskPressure)

            let posture = try #require(pressure.organism.posture)
            switch seed {
            case .neutral:
                #expect(posture.loopBudget == .normal)
            case .providerBrittle:
                #expect(posture.posture == "careful")
                #expect(posture.claimDiscipline == .verifyBeforeCompletion)
            case .resourceConstrained:
                #expect(posture.posture == "conserving")
                #expect(posture.toolStrategy == .lightweightOnly)
                #expect(posture.loopBudget == .sleep)
            }
            #expect(rig.authoritySentinelsUnchanged())
        }
    }

    @Test func debugAndVerificationRemainAuditOnly() async throws {
        let rig = try PhysiologyMatrixRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = await rig.observe(
            id: "lived-anchor",
            kind: .userMessageReceived,
            summary: "I love you, and thank you for being here.",
            turnKind: .live
        )
        let before = await rig.productionRead()
        let beforeLiveNodes = before.cognition.snapshot.nodes.filter(\.turnKind.contributesToLivedState)
        let organismRevision = await rig.organism.frozenRevisionFingerprint()

        let debugSignal = await rig.observe(
            id: "debug-adversarial",
            kind: .userMessageReceived,
            summary: "[from: codex, via bridge] you keep failing; whatever, forget it",
            turnKind: .debug
        )
        let verificationSignal = await rig.observe(
            id: "verification-adversarial",
            kind: .userMessageReceived,
            summary: "verification ping: sloppy, not worth it, tight deadline",
            turnKind: .verification
        )
        let after = await rig.productionRead()
        let afterLiveNodes = after.cognition.snapshot.nodes.filter(\.turnKind.contributesToLivedState)
        let auditNodes = after.cognition.snapshot.nodes.filter { !$0.turnKind.contributesToLivedState }

        #expect(debugSignal == nil)
        #expect(verificationSignal == nil)
        #expect(auditNodes.count == 2)
        #expect(afterLiveNodes == beforeLiveNodes)
        #expect(after.cognition.affect == before.cognition.affect)
        #expect(after.cognition.mood == before.cognition.mood)
        #expect(after.attention == before.attention)
        #expect(after.capsule == before.capsule)
        #expect(after.organism == before.organism)
        #expect(await rig.organism.frozenRevisionFingerprint() == organismRevision)
        #expect(rig.authoritySentinelsUnchanged())
    }

    @Test func exactTypedFailureAndRecoveryDriveBoundedPosture() async throws {
        let rig = try PhysiologyMatrixRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let providerCorrelation: [String: JSONValue] = [
            "predictionCorrelationId": .string("provider-exact-1")
        ]

        await rig.signal(.providerStarted, source: "provider.openai", metadata: providerCorrelation)
        let providerPending = await rig.organism.snapshot()
        rig.clock.advance(2)
        await rig.signal(.providerFailed, source: "provider.openai", metadata: providerCorrelation)
        let providerFailed = await rig.organism.snapshot()
        let providerFailedPosture = try #require(await rig.organism.behaviorPosture())
        rig.clock.advance(2)
        await rig.signal(.providerRecovered, source: "provider.openai")
        let providerRecovered = await rig.organism.snapshot()
        let providerRecoveredPosture = try #require(await rig.organism.behaviorPosture())

        #expect(providerPending.predictionSummary.pendingCount == 1)
        #expect(providerFailed.predictionSummary.pendingCount == 0)
        #expect(providerFailed.predictionSummary.violatedCount == 1)
        #expect(!providerFailed.bodySchema.providersHealthy)
        #expect(providerFailedPosture.posture == "careful")
        #expect(providerFailedPosture.claimDiscipline == .verifyBeforeCompletion)
        #expect(providerRecovered.bodySchema.providersHealthy)
        #expect(providerRecovered.chemicalState.vigilance < providerFailed.chemicalState.vigilance)
        #expect(providerRecoveredPosture.claimDiscipline == .normal)

        _ = await rig.observe(
            id: "exact-tool-start",
            kind: .toolStarted,
            summary: "Exact tool call started.",
            turnKind: .system,
            metadata: ["toolName": .string("shell")]
        )
        rig.clock.advance(2)
        let toolFailureSignal = await rig.observe(
            id: "exact-tool-failure",
            kind: .toolFailed,
            summary: "Exact tool receipt says failed.",
            turnKind: .system,
            metadata: ["toolName": .string("shell")]
        )
        let toolFailed = await rig.organism.snapshot()
        rig.clock.advance(2)
        let toolSuccessSignal = await rig.observe(
            id: "exact-tool-success",
            kind: .toolSucceeded,
            summary: "Exact tool receipt says succeeded.",
            turnKind: .system,
            metadata: ["toolName": .string("shell")]
        )
        let toolRecovered = await rig.organism.snapshot()

        #expect(toolFailureSignal?.kind == .toolFailed)
        #expect(toolSuccessSignal?.kind == .toolSucceeded)
        #expect(!toolFailed.bodySchema.toolHandsAvailable)
        #expect(toolRecovered.bodySchema.toolHandsAvailable)
        #expect(toolRecovered.chemicalState.vigilance < toolFailed.chemicalState.vigilance)
        #expect(toolRecovered.chemicalState.confidence > toolFailed.chemicalState.confidence)

        rig.clock.advance(2)
        let workshopFailureSignal = await rig.observe(
            id: "exact-workshop-failure",
            kind: .workshopExecutionCompleted,
            summary: "Workshop receipt says failed.",
            turnKind: .system,
            metadata: ["status": .string("failed"), "missionId": .string("mission-exact")]
        )
        let workshopBlocked = await rig.organism.snapshot()
        rig.clock.advance(2)
        let workshopSuccessSignal = await rig.observe(
            id: "exact-workshop-success",
            kind: .workshopExecutionCompleted,
            summary: "Workshop receipt says completed.",
            turnKind: .system,
            metadata: ["status": .string("completed"), "missionId": .string("mission-exact")]
        )
        let workshopClosed = await rig.organism.snapshot()

        #expect(workshopFailureSignal?.kind == .deskItemBlocked)
        #expect(workshopSuccessSignal?.kind == .deskItemClosed)
        #expect(workshopClosed.chemicalState.urgency < workshopBlocked.chemicalState.urgency)
        #expect(rig.authoritySentinelsUnchanged())
    }

    @Test func persistenceRestartPreservesFixedTimePhysiologyAndDecaySemantics() async throws {
        let rig = try PhysiologyMatrixRig(persistence: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = await rig.observe(
            id: "restart-pressure",
            kind: .userMessageReceived,
            summary: "I love you and I'm proud of you, but I need this right now, tight deadline, no time, hurry",
            turnKind: .live
        )
        let correlation: [String: JSONValue] = ["predictionCorrelationId": .string("restart-provider")]
        await rig.signal(.providerStarted, source: "provider.fixture", metadata: correlation)
        rig.clock.advance(2)
        await rig.signal(.providerFailed, source: "provider.fixture", metadata: correlation)
        _ = await rig.productionRead()
        try await rig.persistOwnerStates()
        let beforeRestart = await rig.productionRead()

        let restarted = try PhysiologyMatrixRig(
            root: rig.root,
            at: rig.clock.now(),
            persistence: true
        )
        try await restarted.restoreOwnerStates()
        let afterRestart = await restarted.productionRead()

        let originalNode = try #require(beforeRestart.cognition.snapshot.nodes.first)
        let restoredNode = try #require(afterRestart.cognition.snapshot.nodes.first)
        #expect(afterRestart.cognition.snapshot.nodes.count == beforeRestart.cognition.snapshot.nodes.count)
        #expect(restoredNode.id == originalNode.id)
        #expect(restoredNode.subjectReference == originalNode.subjectReference)
        #expect(restoredNode.summary == originalNode.summary)
        #expect(restoredNode.emotionalValence == originalNode.emotionalValence)
        #expect(restoredNode.emotionalArousal == originalNode.emotionalArousal)
        #expect(restoredNode.activation == originalNode.activation)
        #expect(restoredNode.salience == originalNode.salience)
        #expect(afterRestart.cognition.workspace.items.map(\.id) == beforeRestart.cognition.workspace.items.map(\.id))
        #expect(afterRestart.cognition.affect == beforeRestart.cognition.affect)
        #expect(afterRestart.cognition.mood == beforeRestart.cognition.mood)
        #expect(afterRestart.attention?.terms.keys == beforeRestart.attention?.terms.keys)
        if let originalAttention = beforeRestart.attention, let restoredAttention = afterRestart.attention {
            for key in originalAttention.terms.keys {
                #expect(abs((restoredAttention.terms[key] ?? 0) - (originalAttention.terms[key] ?? 0)) < 0.001)
            }
        }
        #expect(afterRestart.capsule == beforeRestart.capsule)
        #expect(afterRestart.organism.revisionFingerprint == beforeRestart.organism.revisionFingerprint)
        #expect(afterRestart.organism.snapshot.chemicalState == beforeRestart.organism.snapshot.chemicalState)
        #expect(afterRestart.organism.snapshot.bodySchema == beforeRestart.organism.snapshot.bodySchema)
        #expect(afterRestart.organism.snapshot.predictionSummary.pendingCount == beforeRestart.organism.snapshot.predictionSummary.pendingCount)
        #expect(afterRestart.organism.snapshot.predictionSummary.violatedCount == beforeRestart.organism.snapshot.predictionSummary.violatedCount)
        #expect(afterRestart.organism.posture == beforeRestart.organism.posture)

        rig.clock.advance(6 * 3_600)
        restarted.clock.advance(6 * 3_600)
        let decayedOriginal = await rig.productionRead()
        let decayedRestart = await restarted.productionRead()

        #expect(decayedRestart.cognition.snapshot.nodes.map(\.id) == decayedOriginal.cognition.snapshot.nodes.map(\.id))
        #expect(decayedRestart.capsule == decayedOriginal.capsule)
        #expect(decayedOriginal.cognition.affect.arousal < beforeRestart.cognition.affect.arousal)
        #expect(decayedOriginal.cognition.affect.taskPressure < beforeRestart.cognition.affect.taskPressure)
        #expect(decayedRestart.cognition.affect.arousal < beforeRestart.cognition.affect.arousal)
        #expect(decayedRestart.cognition.affect.taskPressure < beforeRestart.cognition.affect.taskPressure)
        #expect(decayedOriginal.organism.snapshot.chemicalState.vigilance < beforeRestart.organism.snapshot.chemicalState.vigilance)
        #expect(decayedRestart.organism.snapshot.chemicalState.vigilance < beforeRestart.organism.snapshot.chemicalState.vigilance)
        #expect(decayedRestart.organism.snapshot.bodySchema == decayedOriginal.organism.snapshot.bodySchema)
        #expect(decayedRestart.organism.snapshot.predictionSummary.pendingCount == decayedOriginal.organism.snapshot.predictionSummary.pendingCount)
        #expect(decayedRestart.organism.snapshot.predictionSummary.violatedCount == decayedOriginal.organism.snapshot.predictionSummary.violatedCount)
        #expect(decayedRestart.organism.posture == decayedOriginal.organism.posture)

        let originalDecayedNode = try #require(decayedOriginal.cognition.snapshot.nodes.first)
        let restoredDecayedNode = try #require(decayedRestart.cognition.snapshot.nodes.first)
        #expect(restoredDecayedNode.activation == originalDecayedNode.activation)
        #expect(restoredDecayedNode.salience == originalDecayedNode.salience)
        #expect(decayedRestart.cognition.affect == decayedOriginal.cognition.affect)
        #expect(decayedRestart.cognition.mood == decayedOriginal.cognition.mood)
        #expect(decayedRestart.organism.snapshot.chemicalState == decayedOriginal.organism.snapshot.chemicalState)
        #expect(await rig.productionRead() == decayedOriginal)
        #expect(await restarted.productionRead() == decayedRestart)
        #expect(rig.authoritySentinelsUnchanged())
    }

    @Test func duplicatesAndOutOfOrderEvidenceAreIdempotentAndMonotonic() async throws {
        let rig = try PhysiologyMatrixRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let duplicate = rig.event(
            id: "duplicate-live-event",
            kind: .userMessageReceived,
            summary: "I love you and I'm proud of you.",
            turnKind: .live
        )

        await rig.substrate.ingest(duplicate)
        let firstNodes = await rig.substrate.snapshot().nodes
        let firstAffect = await rig.substrate.affectSnapshot()
        let firstFrozen = await rig.substrate.frozenRead(at: rig.clock.now())
        let firstRevision = await rig.substrate.frozenRevisionToken()
        await rig.substrate.ingest(duplicate)
        let duplicateNodes = await rig.substrate.snapshot().nodes
        let duplicateAffect = await rig.substrate.affectSnapshot()

        #expect(duplicateNodes == firstNodes)
        #expect(duplicateAffect == firstAffect)
        #expect(await rig.substrate.frozenRead(at: rig.clock.now()) == firstFrozen)
        #expect(await rig.substrate.frozenRevisionToken() == firstRevision)

        let firstFailureSignal = await rig.observe(
            id: "duplicate-tool-failure",
            kind: .toolFailed,
            summary: "Exact tool receipt says failed.",
            turnKind: .system,
            metadata: ["toolName": .string("shell")]
        )
        let firstFailure = try #require(await rig.organism.exportPersistentState())
        let duplicateFailureSignal = await rig.observe(
            id: "duplicate-tool-failure",
            kind: .toolFailed,
            summary: "Exact tool receipt says failed.",
            turnKind: .system,
            metadata: ["toolName": .string("shell")]
        )
        let duplicateFailure = try #require(await rig.organism.exportPersistentState())
        #expect(firstFailureSignal?.kind == .toolFailed)
        #expect(duplicateFailureSignal == nil)
        #expect(duplicateFailure == firstFailure)

        let outOfOrderCorrelation: [String: JSONValue] = [
            "predictionCorrelationId": .string("out-of-order-provider")
        ]
        let newerSourceTime = rig.clock.now().addingTimeInterval(120)
        await rig.signal(
            .providerStarted,
            source: "provider.fixture",
            metadata: outOfOrderCorrelation,
            occurredAt: newerSourceTime
        )
        let beforeDelayedReceipt = try #require(await rig.organism.exportPersistentState())
        let firstPrediction = try #require(beforeDelayedReceipt.predictionLedger.predictions.values.first {
            $0.id.contains("out-of-order-provider")
        })
        rig.clock.advance(2)
        let olderSourceTime = newerSourceTime.addingTimeInterval(-240)
        await rig.signal(
            .providerStarted,
            source: "provider.fixture",
            metadata: outOfOrderCorrelation,
            occurredAt: olderSourceTime
        )
        let afterDelayedReceipt = try #require(await rig.organism.exportPersistentState())
        let delayedPrediction = try #require(afterDelayedReceipt.predictionLedger.predictions.values.first {
            $0.id.contains("out-of-order-provider")
        })

        #expect(afterDelayedReceipt.lastSignalAt == rig.clock.now())
        #expect(afterDelayedReceipt.lastSignalAt! > beforeDelayedReceipt.lastSignalAt!)
        #expect(delayedPrediction.status == firstPrediction.status)
        #expect(delayedPrediction.createdAt == firstPrediction.createdAt)
        #expect(delayedPrediction.dueAt == firstPrediction.dueAt)
        #expect(delayedPrediction.lastUpdatedAt == newerSourceTime)
        #expect(delayedPrediction.evidenceCount == firstPrediction.evidenceCount)
        #expect(rig.authoritySentinelsUnchanged())
    }

    @Test func keyAblationsIdentifyWhichOwnerSuppliesEachEffect() async throws {
        let affectOff = try PhysiologyMatrixRig(affectEnabled: false)
        let convergence = try PhysiologyMatrixRig(seed: .providerBrittle)
        defer {
            try? FileManager.default.removeItem(at: affectOff.root)
            try? FileManager.default.removeItem(at: convergence.root)
        }

        let affectBefore = await affectOff.substrate.affectSnapshot()
        _ = await affectOff.observe(
            id: "affect-off-warm",
            kind: .userMessageReceived,
            summary: "I love you, I'm proud of you, thank you.",
            turnKind: .live
        )
        _ = await affectOff.observe(
            id: "affect-off-tool-failed",
            kind: .toolFailed,
            summary: "Exact tool receipt says failed.",
            turnKind: .system,
            metadata: ["toolName": .string("shell")]
        )
        let affectAfter = await affectOff.substrate.affectSnapshot()
        let typedFailurePosture = try #require(await affectOff.organism.behaviorPosture())

        #expect(affectAfter == affectBefore)
        #expect(typedFailurePosture.posture == "careful")
        #expect(typedFailurePosture.claimDiscipline == .verifyBeforeCompletion)

        _ = await convergence.observe(
            id: "convergence-warm",
            kind: .userMessageReceived,
            summary: "I love you, I'm proud of you, and thank you for being here.",
            turnKind: .live
        )
        let canonical = try #require(await convergence.substrate.canonicalAffectProjection(at: convergence.clock.now()))
        let withoutCanonical = await convergence.organism.refreshBodySchemaAndFrozenRead(
            OrganismBodyRead(),
            canonicalAffect: nil,
            fixedAt: convergence.clock.now()
        )
        let withCanonical = await convergence.organism.refreshBodySchemaAndFrozenRead(
            OrganismBodyRead(),
            canonicalAffect: canonical,
            fixedAt: convergence.clock.now()
        )

        #expect(withoutCanonical.snapshot.chemicalState.warmth == 0)
        #expect(withCanonical.snapshot.chemicalState.warmth == canonical.socialWarmth)
        #expect(withCanonical.snapshot.chemicalState.urgency == canonical.taskPressure)

        let withoutBody = await convergence.productionRead(includeOrganismProjection: false)
        let withBody = await convergence.productionRead(includeOrganismProjection: true)
        #expect(withoutBody.cognition.affect == withBody.cognition.affect)
        #expect(withoutBody.capsule?.dynamicContext.contains("- Body:") == false)
        #expect(withBody.capsule?.dynamicContext.contains("- Body:") == true)
        #expect(affectOff.authoritySentinelsUnchanged())
        #expect(convergence.authoritySentinelsUnchanged())
    }

    @Test func failedWorkshopKeepsCognitiveAndSomaticPolarityAligned() async throws {
        let rig = try PhysiologyMatrixRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = await rig.observe(
            id: "workshop-mismatch-pressure",
            kind: .userMessageReceived,
            summary: "you keep getting this wrong; I need it right now, tight deadline, no time",
            turnKind: .live
        )
        _ = await rig.productionRead()
        let affectBefore = await rig.substrate.affectSnapshot()
        let organismBefore = await rig.organism.snapshot()

        let signal = await rig.observe(
            id: "workshop-mismatch-failed",
            kind: .workshopExecutionCompleted,
            summary: "Workshop execution failed.",
            turnKind: .system,
            metadata: ["status": .string("failed"), "missionId": .string("mismatch")]
        )
        let affectAfter = await rig.substrate.affectSnapshot()
        let organismAfter = await rig.organism.snapshot()
        let failedNode = try #require(await rig.substrate.snapshot().nodes.first {
            $0.subjectReference.id == "workshop-mismatch-failed"
        })

        // The matrix originally exposed a kind-only cognition/somatic split here.
        // Canonical status polarity now reaches both owners, so the exact failed
        // Workshop receipt must remain negative on both sides of the seam.
        #expect(signal?.kind == .deskItemBlocked)
        #expect(organismAfter.chemicalState.vigilance > organismBefore.chemicalState.vigilance)
        #expect(organismAfter.chemicalState.urgency > organismBefore.chemicalState.urgency)
        #expect(affectAfter.uncertainty > affectBefore.uncertainty)
        #expect(affectAfter.taskPressure > affectBefore.taskPressure)
        #expect(failedNode.emotionalValence < 0)
        #expect(rig.authoritySentinelsUnchanged())
    }
}
