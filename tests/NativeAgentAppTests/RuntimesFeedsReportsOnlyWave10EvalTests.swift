import BackgroundLoops
import ApprovalInbox
import Context
import Foundation
import GitHubConnector
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import SelfImprovement
import Skills
import Testing
import TriggerScheduler
import ChatOrchestration
@testable import NativeAgentApp

// Wave 10 closes runtime/feed observations through their live Swift owners.
// The fixtures are hermetic: they do not inspect source text or manufacture a
// response envelope.  Each assertion observes a durable owner after its real
// action, including restart or damaged-state semantics where the owner has one.

private func wave10Root(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentWave10-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private actor Wave10CallCounter {
    private var value = 0

    func increment() { value += 1 }
    func read() -> Int { value }
}

private final class Wave10LLM: LLMClient, @unchecked Sendable {
    let result: String
    private let callCounter = Wave10CallCounter()

    init(result: String) { self.result = result }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        await callCounter.increment()
        return result
    }

    var calls: Int { get async { await callCounter.read() } }
}

private final class Wave10PersonaSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The Desk route is a lazy-tool caller. Carry the same persisted session and
/// loaded-tool state that a real Desk click receives before it reaches the
/// dispatch membrane.
private struct Wave10AuthorizedDeskRouter: DeskToolInvoking {
    let router: DeskToolDispatchRouter
    let sessionID: String

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        var authorizedInput = input
        authorizedInput["session_id"] = .string(sessionID)
        return try await router.run(tool: tool, input: authorizedInput)
    }
}

private func wave10AuthorizedDeskRouter(dataRoot: URL) async throws -> Wave10AuthorizedDeskRouter {
    let sessionID = "wave10-desk-session"
    try await ActiveToolsStore(dataRoot: dataRoot).addLoaded(
        sessionId: sessionID,
        names: ["desk_nag_control"]
    )
    return Wave10AuthorizedDeskRouter(
        router: DeskToolDispatchRouter(dataRoot: dataRoot),
        sessionID: sessionID
    )
}

@Suite("app runtimes and feeds reports-only wave 10", .serialized)
struct RuntimesFeedsReportsOnlyWave10EvalTests {
    // app.personaContextFlowProvider
    @Test("persona source mirrors replace the picker-selected persona after cache invalidation")
    func personaPickerRefreshesRequiredDocumentMirrors() async throws {
        let root = try wave10Root("persona")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, marker) in [("Alpha", "wave10-alpha-source"), ("Beta", "wave10-beta-source")] {
            let directory = root.appendingPathComponent("persona/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: directory.appendingPathComponent("SOUL.md"))
        }
        let selection = Wave10PersonaSelection("Alpha")
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let activePersona = personaRoot.appendingPathComponent("active.json")
        // The picker applies to Chat only. Every other source surface resolves
        // the canonical active identity, so keep that generation in lockstep
        // with the selected identity before reading the combined mirrors.
        try Data(#"{"persona":"Alpha"}"#.utf8).write(to: activePersona)
        let provider = PersonaContextFlowProvider(
            compiler: PersonaCompiler(engine: SwiftNativePersonaEngine(root: personaRoot, dataRoot: root)),
            dataRoot: root,
            mode: .shadow,
            personaOverride: { selection.read() }
        )

        let before = try await provider.requiredDocumentMirrors()
            .flatMap(\.documents).map(\.text).joined(separator: "\n")
        #expect(before.contains("wave10-alpha-source"))
        #expect(!before.contains("wave10-beta-source"))

        selection.set("Beta")
        try Data(#"{"persona":"Beta"}"#.utf8).write(to: activePersona)
        await provider.invalidateCachedBuild()
        let after = try await provider.requiredDocumentMirrors()
            .flatMap(\.documents).map(\.text).joined(separator: "\n")
        #expect(after.contains("wave10-beta-source"))
        #expect(!after.contains("wave10-alpha-source"))
    }

    // feeds.desk.cadence_stats
    @Test("cadence observations survive a reopened store while corrupt bytes become conservative unknown")
    func deskCadenceStoreReopensAndDoesNotInventLearnedCadence() async throws {
        let root = try wave10Root("cadence")
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DeskCadenceStore(dataRoot: root)
        _ = try await store.recordObservation(refKey: "github:wave10", fingerprint: "first", at: stamp)
        _ = try await store.recordObservation(refKey: "github:wave10", fingerprint: "changed", at: stamp.addingTimeInterval(3600))

        let reopened = DeskCadenceStore(dataRoot: root)
        let persisted = await reopened.load()
        #expect(persisted.refs["github:wave10"]?.observations == 2)

        // The real GitHub tracker is the cadence reader: a complete learned
        // batch stretches its exact next refresh, while a missing member must
        // fall back to the configured rate.
        let refreshed = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshedISO = ISO8601DateFormatter().string(from: refreshed)
        let refKey = "owner/repo#pr#7"
        let persistence = SwiftNativePersistenceCore()
        try await persistence.writeJSON(.object([
            "version": .int(2),
            "refreshIntervalMinutes": .int(15),
            "project": .string("Wave 10"),
            "mode": .string("repository"),
            "repositories": .array([.object([
                "fullName": .string("owner/repo"), "name": .string("repo"),
                "htmlURL": .string("https://github.com/owner/repo"),
            ])]),
            "staleAfterHours": .int(72),
            "updatedAt": .string(refreshedISO),
        ]), to: root.appendingPathComponent("connectors/github/tracking.json"))
        try await persistence.writeJSON(.object([
            "project": .string("Wave 10"),
            "refreshedAt": .string(refreshedISO),
            "entities": .array([.object([
                "key": .string(refKey), "repository": .string("owner/repo"),
                "number": .int(7), "kind": .string("pull_request"),
                "title": .string("Wave 10"), "state": .string("open"),
                "updatedAt": .string(refreshedISO), "url": .string("https://github.com/owner/repo/pull/7"),
            ])]),
        ]), to: root.appendingPathComponent("connectors/github/tracking_snapshot.json"))
        let learned = DeskRefObservationStat(
            refKey: refKey, firstObservedAt: refreshedISO, lastObservedAt: refreshedISO,
            lastChangeAt: refreshedISO, observations: 4, changes: 3,
            ewmaChangeIntervalSec: 4 * 60 * 60, lastFingerprint: "wave10"
        )
        _ = try await reopened.updating { _ in (DeskCadenceStats(refs: [refKey: learned]), ()) }
        #expect(await GitHubConnectorActions.nextTrackingRefreshDeadline(
            after: refreshed.addingTimeInterval(60), dataRoot: root
        ) == refreshed.addingTimeInterval(2 * 60 * 60))

        let path = reopened.statsPath
        try Data("not-json".utf8).write(to: path)
        let damaged = await DeskCadenceStore(dataRoot: root).load()
        #expect(damaged.refs.isEmpty)
        let interval = await DeskCadenceStore(dataRoot: root).resolvedInterval(
            refKey: "github:wave10", explicit: nil, now: stamp, fallbackSeconds: 900
        )
        #expect(interval.seconds == 900)
        #expect(interval.source == .fallback)
    }

    // feeds.desk.nag_config
    @Test("Desk nag actions commit through the canonical config and a reopened reader preserves the mute window")
    func deskNagConfigActionSurvivesRestart() async throws {
        let root = try wave10Root("nag")
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try await wave10AuthorizedDeskRouter(dataRoot: root)
        #expect((await DeskActionRunner.perform(.nagGlobal(on: true), via: router)).ok)
        #expect((await DeskActionRunner.perform(.nagMute(until: nil), via: router)).ok)

        let config = await DeskNagConfigStore(dataRoot: root).load()
        #expect(config.enabled)
        #expect(config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel)
        #expect(config.isMuted(now: Date(timeIntervalSince1970: 1_800_000_000)))

        let path = DeskNagConfigStore(dataRoot: root).configPath
        try Data("[]".utf8).write(to: path)
        let damaged = await DeskNagConfigStore(dataRoot: root).load()
        #expect(!damaged.enabled, "a malformed preference file must not leave the nag lane silently armed")
    }

    // feeds.triggers.state
    @Test("a due default trigger stamps its canonical state once and a relaunched scheduler does not refire")
    func triggerStateClaimSurvivesSchedulerRelaunch() async throws {
        let root = try wave10Root("trigger-state")
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let due = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 12, day: 12, hour: 9, minute: 0
        )))
        let first = SwiftNativeTriggerScheduler(root: root, now: { due })
        let fired = await first.evaluateAndFire()
        #expect(fired.contains("morning_brief"))
        #expect(FileManager.default.fileExists(atPath: first.inboxStatePath.path))

        let second = SwiftNativeTriggerScheduler(root: root, now: { due })
        #expect(!(await second.evaluateAndFire()).contains("morning_brief"))

        try Data("[\"wrong-shape\"]".utf8).write(to: first.inboxStatePath)
        let corruptBytes = try Data(contentsOf: first.inboxStatePath)
        let damaged = SwiftNativeTriggerScheduler(root: root, now: { due.addingTimeInterval(86_400) })
        #expect(!(await damaged.evaluateAndFire()).contains("morning_brief"),
                "existing corrupt state must make periodic delivery dormant, never look like a fresh install")
        #expect(try Data(contentsOf: first.inboxStatePath) == corruptBytes,
                "a dormant corrupt state is byte-preserved; it is not reset as a fresh state")
    }

    // feeds.skills.registry
    @Test("canonical skill mutation writes registry, body, and history before a restarted reader observes it")
    func skillsRegistryMutationOwnsItsWholeArtifactFamily() async throws {
        let root = try wave10Root("skills")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SwiftNativeSkillsClient(root: root)
        let created = try await first.createSkill(body: .object([
            "name": .string("Wave 10 Skill"),
            "description": .string("A canonical skills mutation fixture."),
            "triggers": .array([.string("wave ten")]),
            "content": .string("# Wave 10 Skill\n\nUse the canonical mutation path."),
        ]))
        guard case .object(let row) = created,
              case .string(let id)? = row["id"],
              case .string(let bodyPath)? = row["bodyPath"] else {
            Issue.record("canonical create did not return its durable identifiers")
            return
        }
        #expect(FileManager.default.fileExists(atPath: bodyPath))
        #expect((try await first.listSkillVersions(id: id)).count == 1)
        let restarted = SwiftNativeSkillsClient(root: root)
        let restartedRows = try await restarted.listSkills()
        #expect(restartedRows.contains { candidate in
            guard case .object(let row) = candidate else { return false }
            return row["name"] == .string("Wave 10 Skill")
                && row["bodyPath"] == .string(bodyPath)
        })
        _ = try await restarted.archiveSkill(id: id)
        #expect((try await restarted.listSkillVersions(id: id)).count >= 2)
    }

    // feeds.self_improvement
    @Test("weekly self-improvement stages a runtime finding, writes its digest, and a relaunch honors the durable weekly marker")
    func weeklySelfImprovementDigestAndMarkerAreRealOutputs() async throws {
        let root = try wave10Root("self-improvement")
        defer { try? FileManager.default.removeItem(at: root) }
        let llm = Wave10LLM(result: """
        {"summary":"wave10 summary","findings":[{"kind":"runtime","title":"Wave 10 runtime finding","evidence":"receipt","proposedChange":"disable a dormant capability","apply":{"op":"disable_skill","target":"wave10"}}]}
        """)
        let key = "selfImprovementEnabled"
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: key)
        defer { if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(true, forKey: key)
        let first = BackgroundLoopsAssembly.makeWeeklySelfImprovementLoop(dataRoot: root, llm: llm)
        #expect(await first.tickOutcome() == .completed(result: "weekly proposals staged"))
        let approvals = try await SwiftNativeApprovalInbox(root: root).list(filter: .pending)
        #expect(approvals.count == 1)
        #expect(approvals.first?.title == "Wave 10 runtime finding")
        let digestRoot = root.appendingPathComponent("self_improvement/digests", isDirectory: true)
        let digests = try FileManager.default.contentsOfDirectory(
            at: digestRoot,
            includingPropertiesForKeys: nil
        )
        #expect(digests.count == 1)
        guard let digest = digests.first else {
            Issue.record("weekly self-improvement did not write a digest")
            return
        }
        #expect(try String(contentsOf: digest, encoding: .utf8).contains("Wave 10 runtime finding"))

        let relaunched = BackgroundLoopsAssembly.makeWeeklySelfImprovementLoop(dataRoot: root, llm: llm)
        #expect(await relaunched.tickOutcome() == .skipped(reason: "weekly pass already committed"))
        #expect(await llm.calls == 1)
    }

    // feeds.evolution
    @Test("evolution retention drives the canonical proposal store and refuses to erase a corrupt store")
    func evolutionRetentionUsesStoreAndFailsClosedOnDamage() async throws {
        let root = try wave10Root("evolution")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let store = EvolutionProposalStore(dataRoot: root, now: { old })
        let proposal = try await store.propose(source: .weekly, title: "Wave 10", evidence: "old terminal")
        #expect((try await store.transition(id: proposal.id, to: .denied, denyReason: "fixture")).applied)
        let loop = BackgroundLoopsAssembly.makeEvolutionProposalRetentionLoop(dataRoot: root)
        #expect(await loop.tickOutcome() == .completed(result: "evolution proposal sweep removed 1"))
        #expect((try await EvolutionProposalStore(dataRoot: root, now: { old }).list()).isEmpty)

        let path = root.appendingPathComponent("evolution/proposals.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: path)
        let failed = await loop.tickOutcome()
        guard case .failed = failed else { Issue.record("corrupt proposal store was treated as healthy"); return }
        #expect(try Data(contentsOf: path) == corrupt)
    }

    // feeds.context.legacy_generation_json
    @Test("latest context receipt follows a live message runId and does not substitute an unrelated legacy generation")
    func legacyContextFilesAreNotAFallbackReader() async throws {
        let root = try wave10Root("legacy-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("context/old-generation.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"generation":"old","content":"must not become live"}"#.utf8).write(to: legacy)
        let sessionID = "wave10-session"
        let sessions = root.appendingPathComponent("chat/sessions.json")
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"id":"wave10-session","title":"Wave 10"}]"#.utf8).write(to: sessions)
        let messages = root.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: messages.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"role\":\"assistant\",\"runId\":\"wave10-live-run\"}\n".utf8).write(to: messages)
        let liveReceipt = root.appendingPathComponent("context/wave10-live-run.json")
        try Data(#"{"runId":"wave10-live-run","mode":"active"}"#.utf8).write(to: liveReceipt)

        let receipt = await SwiftNativeContextClient(dataRoot: root).latestContextReceipt(sessionId: sessionID)
        guard case .object(let value)? = receipt else { Issue.record("live run receipt was not read"); return }
        #expect(value["runId"] == .string("wave10-live-run"))
        #expect(value["content"] == nil)
    }
}
