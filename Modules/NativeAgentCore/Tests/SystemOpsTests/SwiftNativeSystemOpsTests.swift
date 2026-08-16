import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import TrustCenter
@testable import SystemOps

/// Permissive trust policy for tests that need the wave-8 autonomy gate to
/// allow the action through. Every flag is on.
private func _permissiveAutonomyPolicy() -> AutonomyTrustPolicyView {
    AutonomyTrustPolicyView(
        enableAutonomy: true,
        systemRebuildEnabled: true,
        gitStashRecoverEnabled: true,
        raw: .object([:])
    )
}

// MARK: - Subprocess stub

actor _SubprocessStub: SubprocessRunner {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let cwd: String?
        let timeout: TimeInterval
        let detached: Bool
    }
    private var responses: [(exitCode: Int32, stdout: String, stderr: String)] = []
    private(set) var invocations: [Invocation] = []
    private var throwAtIndex: Int? = nil

    func queue(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        responses.append((exitCode, stdout, stderr))
    }

    func run(
        executable: String,
        arguments: [String],
        cwd: URL?,
        timeout: TimeInterval,
        detached: Bool
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        invocations.append(.init(
            executable: executable,
            arguments: arguments,
            cwd: cwd?.path,
            timeout: timeout,
            detached: detached
        ))
        if responses.isEmpty {
            return (0, "", "")
        }
        return responses.removeFirst()
    }
}

// MARK: - Helpers

private func makeTempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SystemOpsTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readJSONFile(_ url: URL) -> JSONValue? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONValue.parse(data)
}

// MARK: - RouterPlan parity tests

@Test func routerPlanClassifiesApproval() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "please approve this")
    #expect(r.goalType == "approval")
    #expect(r.recommendedSurface == "activity")
    #expect(r.contextMode == "ops")
}

@Test func routerPlanClassifiesTelegram() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "telegram bot config")
    #expect(r.goalType == "telegram")
    #expect(r.recommendedSurface == "telegram")
}

@Test func routerPlanClassifiesSchedule() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "schedule a reminder")
    #expect(r.goalType == "schedule")
}

@Test func routerPlanClassifiesCalendarReadAsScheduleWithoutApproval() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "Do I have anything on my calendar today that would affect whether I should keep coding?"
    )
    #expect(r.goalType == "schedule")
    #expect(r.contextMode == "ops")
    #expect(r.risk == "low")
    #expect(r.requiresApproval == false)
}

@Test func routerPlanClassifiesMemoryUpdate() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "remember my preferences")
    #expect(r.goalType == "memory_update")
}

@Test func routerPlanClassifiesResearch() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "research the topic")
    #expect(r.goalType == "research")
}

@Test func routerPlanClassifiesWorkflow() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "automate this workflow")
    #expect(r.goalType == "workflow")
}

@Test func routerPlanClassifiesBuildTask() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "fix the swift build")
    #expect(r.goalType == "build_task")
}

@Test func routerPlanClassifiesGitStatusAsBuildTask() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "check git status in the NativeAgent repo")
    #expect(r.goalType == "build_task")
    #expect(r.contextMode == "capability")
}

@Test func routerPlanClassifiesRepoStandsAsBuildTask() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "Can you check where the NativeAgent repo stands right now? I just need the short version."
    )
    #expect(r.goalType == "build_task")
    #expect(r.contextMode == "capability")
}

@Test func routerPlanClassifiesSelfImprovement() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "improve self-improvement loop")
    #expect(r.goalType == "self_improvement")
}

@Test func routerPlanClassifiesChat() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "hello")
    #expect(r.goalType == "chat")
}

@Test func routerPlanWatchSetupRoutesToSchedule() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "watch my email inbox")
    #expect(r.goalType == "schedule")
    #expect(r.risk == "medium")
}

@Test func routerPlanEmailKeywordRisesRisk() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "send an email to bob")
    #expect(r.risk == "high")
    #expect(r.requiresApproval == true)
}

@Test func routerPlanIdAndCreatedAtPopulated() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "hello")
    #expect(!r.id.isEmpty)
    #expect(r.createdAt.contains("+00:00"))
}

@Test func routerPlanEmptyMessageThrows() async throws {
    let client = SwiftNativeRouterPlanClient()
    do {
        _ = try await client.planRoute(message: "")
        Issue.record("expected SystemOpsError.missingMessage")
    } catch SystemOpsError.missingMessage {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - GitStashRecover tests

@Test func gitStashRecoverHappyPath() async throws {
    let runner = _SubprocessStub()
    await runner.queue(exitCode: 0, stdout: "stash@{0}: WIP on main: my-label here\nstash@{1}: WIP on dev: other\n")
    await runner.queue(exitCode: 0, stdout: "Applied stash@{0}", stderr: "")
    let client = SwiftNativeGitStashRecoverClient(
        repoRoot: URL(fileURLWithPath: "/tmp/repo"),
        runner: runner,
        daemonAutonomy: true,
        policyProvider: { _permissiveAutonomyPolicy() }
    )
    let r = try await client.gitStashRecover(label: "my-label")
    #expect(r.ok == true)
    #expect(r.stashRef == "stash@{0}")
    #expect(r.output == "Applied stash@{0}")
}

@Test func gitStashRecoverEmptyLabelThrows() async throws {
    let runner = _SubprocessStub()
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() })
    do {
        _ = try await client.gitStashRecover(label: "   ")
        Issue.record("expected missingLabel")
    } catch SystemOpsError.missingLabel {
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func gitStashRecoverNotFoundThrows() async throws {
    let runner = _SubprocessStub()
    await runner.queue(exitCode: 0, stdout: "stash@{0}: WIP on main: something else\n")
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() })
    do {
        _ = try await client.gitStashRecover(label: "nope-not-there")
        Issue.record("expected stashNotFound")
    } catch SystemOpsError.stashNotFound(let l) {
        #expect(l == "nope-not-there")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func gitStashRecoverPopFailureThrows() async throws {
    let runner = _SubprocessStub()
    await runner.queue(exitCode: 0, stdout: "stash@{0}: WIP on main: my-label\n")
    await runner.queue(exitCode: 1, stdout: "", stderr: "conflict")
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() })
    do {
        _ = try await client.gitStashRecover(label: "my-label")
        Issue.record("expected stashPopFailed")
    } catch SystemOpsError.stashPopFailed(let msg) {
        #expect(msg.contains("conflict"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - SystemRebuild tests

@Test func systemRebuildHappyPath() async throws {
    let tmp = makeTempDir()
    let scriptDir = tmp.appendingPathComponent("script", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    let scriptPath = scriptDir.appendingPathComponent("install_app.sh")
    try Data("#!/bin/bash\necho ok\n".utf8).write(to: scriptPath)

    let runner = _SubprocessStub()
    // Isolate the cross-process rebuild lock per test — each tmp dir gets
    // its own .rebuild.lock. Production intentionally leaks the lock fd
    // (daemon dies mid-install in install_app.sh, matching Python L45185);
    // in-process tests would otherwise collide on the shared default-dataRoot
    // lock once the first happy-path test runs.
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() }, rebuildLock: RebuildLock(dataRoot: tmp))
    let r = try await client.systemRebuild()
    #expect(r.ok == true)
    #expect(r.message?.contains("Rebuild started") == true)

    let invocations = await runner.invocations
    #expect(invocations.count == 1)
    #expect(invocations.first?.executable == "/bin/bash")
    #expect(invocations.first?.arguments == [scriptPath.path])
    #expect(invocations.first?.detached == true)
}

@Test func systemRebuildScriptMissingThrows() async throws {
    let tmp = makeTempDir()
    let runner = _SubprocessStub()
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() }, rebuildLock: RebuildLock(dataRoot: tmp))
    do {
        _ = try await client.systemRebuild()
        Issue.record("expected scriptMissing")
    } catch SystemOpsError.scriptMissing(let p) {
        #expect(p.hasSuffix("install_app.sh"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func systemRebuildIsDetached() async throws {
    let tmp = makeTempDir()
    let scriptDir = tmp.appendingPathComponent("script", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    try Data("#!/bin/bash\n".utf8).write(to: scriptDir.appendingPathComponent("install_app.sh"))
    let runner = _SubprocessStub()
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() }, rebuildLock: RebuildLock(dataRoot: tmp))
    _ = try await client.systemRebuild()
    let invocations = await runner.invocations
    #expect(invocations.allSatisfy { $0.detached })
}

// MARK: - Factory routing

@Test func factoriesReturnSwiftNative() {
    #expect(makeRouterPlanClient() is SwiftNativeRouterPlanClient)
    #expect(makeSystemRebuildClient() is SwiftNativeSystemRebuildClient)
    #expect(makeGitStashRecoverClient() is SwiftNativeGitStashRecoverClient)
}

// MARK: - Production-gate refusal tests

@Test func systemRebuildRefusesByDefault() async throws {
    let tmp = makeTempDir()
    let scriptDir = tmp.appendingPathComponent("script", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    try Data("#!/bin/bash\n".utf8).write(to: scriptDir.appendingPathComponent("install_app.sh"))
    let runner = _SubprocessStub()
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner)
    do {
        _ = try await client.systemRebuild()
        Issue.record("expected SystemOpsError.autonomyDenied")
    } catch SystemOpsError.autonomyDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let invocations = await runner.invocations
    #expect(invocations.isEmpty)
}

@Test func gitStashRecoverRefusesByDefault() async throws {
    let runner = _SubprocessStub()
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner)
    do {
        _ = try await client.gitStashRecover(label: "anything")
        Issue.record("expected SystemOpsError.autonomyDenied")
    } catch SystemOpsError.autonomyDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let invocations = await runner.invocations
    #expect(invocations.isEmpty)
}

@Test func routerPlanToolCreationIsHighRiskRequiringApproval() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "create a tool to parse logs")
    #expect(r.goalType == "tool_creation")
    #expect(r.risk == "high")
    #expect(r.requiresApproval == true)
}

@Test func routerPlanToolProhibitionAndSlashProseStayMinimalChat() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "What does your current inner/body posture feel like? Please don't call a tool for this."
    )
    #expect(r.goalType == "chat")
    #expect(r.contextMode == "minimal")
    #expect(r.risk == "low")
    #expect(r.requiresApproval == false)
}

@Test func routerPlanExplicitCreationStillWinsBesideToolProhibition() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "Don't call a tool now; create a tool that can parse these logs."
    )
    #expect(r.goalType == "tool_creation")
    #expect(r.requiresApproval == true)
}

@Test func routerPlanExactCommunicationTokensRemainHighRisk() async throws {
    let client = SwiftNativeRouterPlanClient()
    let message = try await client.planRoute(message: "send that message for me")
    #expect(message.risk == "high")
    #expect(message.requiresApproval == true)

    let calendar = try await client.planRoute(message: "add this to my calendar")
    #expect(calendar.risk == "high")
    #expect(calendar.requiresApproval == true)
}

@Test func routerPlanWordFragmentsDoNotAllocateFileWork() async throws {
    let client = SwiftNativeRouterPlanClient()
    let profile = try await client.planRoute(message: "How does my profile look to you?")
    #expect(profile.goalType == "chat")
    #expect(profile.contextMode == "minimal")

    let file = try await client.planRoute(message: "Read the profile file for me")
    #expect(file.goalType == "file_work")
}

// MARK: - Wave-11 capability scoring tests

private func _capObjString(_ entry: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = entry else { return nil }
    guard case .string(let s) = obj[key] ?? .null else { return nil }
    return s
}

private func _capObjArray(_ entry: JSONValue, _ key: String) -> [JSONValue]? {
    guard case .object(let obj) = entry else { return nil }
    guard case .array(let a) = obj[key] ?? .null else { return nil }
    return a
}

private func _capObjDouble(_ entry: JSONValue, _ key: String) -> Double? {
    guard case .object(let obj) = entry else { return nil }
    if case .double(let d) = obj[key] ?? .null { return d }
    if case .int(let i) = obj[key] ?? .null { return Double(i) }
    return nil
}

@Test func capabilityRecordsCountMatchesFeaturesPlusActions() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    #expect(recs.count == featureSurfaceRecordsCount + connectorActionDescriptorsCount)
}

@Test func scoreContextCapabilityMemoryParity() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    guard let memory = recs.first(where: { $0.id == "feature:memory_system" }) else {
        Issue.record("memory_system record missing")
        return
    }
    let parts = scoreContextCapabilityParts(memory, message: "I want memory recall", mode: "memory")
    #expect(parts.reasons.contains("trigger:memory"))
    #expect(parts.reasons.contains("trigger:recall"))
    #expect(parts.reasons.contains("mode:memory"))
    #expect(parts.score > 0)
}

@Test func selectContextCapabilitiesMinimalLimitDefault() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let r = selectContextCapabilities(
        records: recs,
        message: "workflow tool memory remember research chat command center status",
        mode: "minimal"
    )
    #expect(r.count <= 2)
    #expect(r.count > 0)
}

@Test func selectContextCapabilitiesCapabilityLimitDefault() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let r = selectContextCapabilities(
        records: recs,
        message: "workflow tool memory remember research chat command center status",
        mode: "capability"
    )
    #expect(r.count <= 8)
}

@Test func selectContextCapabilitiesFullLimitDefault() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let r = selectContextCapabilities(records: recs, message: "qxzpv blarg nomatch", mode: "full")
    #expect(r.count <= 18)
    #expect(r.count > 0)
}

@Test func selectContextCapabilitiesDropsZeroScoreOutsideFull() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let nonFull = selectContextCapabilities(records: recs, message: "qxzpv blarg nomatch", mode: "capability")
    for entry in nonFull {
        if let s = _capObjDouble(entry, "score") {
            #expect(s > 0)
        }
    }
}

@Test func selectContextCapabilitiesSortsByScoreThenStatusDescending() throws {
    let a = CapabilityScoringRecord(
        id: "feature:synth_a", sourceId: "synth_a", name: "Synth A",
        kind: "feature", status: "active",
        description: "Alpha trigger gamma.",
        triggers: ["alpha", "gamma"], permissions: [], riskClass: "read_only",
        endpoints: [], useCount: 0
    )
    let b = CapabilityScoringRecord(
        id: "feature:synth_b", sourceId: "synth_b", name: "Synth B",
        kind: "feature", status: "ready",
        description: "Alpha trigger gamma.",
        triggers: ["alpha", "gamma"], permissions: [], riskClass: "read_only",
        endpoints: [], useCount: 0
    )
    let r = selectContextCapabilities(records: [a, b], message: "alpha gamma", mode: "full")
    #expect(r.count == 2)
    #expect(_capObjString(r[0], "status") == "ready")
    #expect(_capObjString(r[1], "status") == "active")
}

@Test func selectContextCapabilitiesTruncatesFields() throws {
    let longDesc = String(repeating: "X", count: 800)
    let manyTriggers = (0..<12).map { "t\($0)" }
    let manyPerms = (0..<10).map { "p\($0)" }
    let manyEndpoints = (0..<10).map { "/v1/e\($0)" }
    let rec = CapabilityScoringRecord(
        id: "feature:synth_big", sourceId: "synth_big", name: "Synth Big",
        kind: "feature", status: "ready",
        description: longDesc,
        triggers: manyTriggers, permissions: manyPerms, riskClass: "read_only",
        endpoints: manyEndpoints, useCount: 0
    )
    let r = selectContextCapabilities(records: [rec], message: "synth big", mode: "full")
    #expect(r.count == 1)
    #expect(_capObjString(r[0], "description")?.count == 500)
    #expect(_capObjArray(r[0], "triggers")?.count == 6)
    #expect(_capObjArray(r[0], "permissions")?.count == 6)
    #expect(_capObjArray(r[0], "endpoints")?.count == 6)
    if let matched = _capObjArray(r[0], "matchedTerms") {
        #expect(matched.count <= 8)
    }
}

@Test func selectContextCapabilitiesFallbackRankingFullMode() throws {
    // kind="zzz_no_bias" + status="draft" → no kind/source bias, no status bonus,
    // no name match, no trigger substring → reasons stays empty → selectionReasons
    // falls back to ["fallback ranking"]. Mode "full" keeps the zero-score row.
    let rec = CapabilityScoringRecord(
        id: "synth:zero", sourceId: "zero", name: "Synth Zero",
        kind: "zzz_no_bias", status: "draft",
        description: "qqqq.",
        triggers: ["qqqqtrig"], permissions: [], riskClass: "read_only",
        endpoints: [], useCount: 0
    )
    let r = selectContextCapabilities(records: [rec], message: "totally unrelated", mode: "full")
    #expect(r.count == 1)
    guard let reasons = _capObjArray(r[0], "selectionReasons") else {
        Issue.record("selectionReasons missing")
        return
    }
    #expect(reasons.count == 1)
    if case .string(let s) = reasons[0] {
        #expect(s == "fallback ranking")
    } else {
        Issue.record("selectionReasons[0] not string")
    }
}

@Test func routerPlanWiresMatchedCapabilitiesEndToEnd() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "please update my memory")
    #expect(!r.matchedCapabilities.isEmpty)
    let ids: [String] = r.matchedCapabilities.compactMap { _capObjString($0, "id") }
    #expect(ids.contains("feature:memory_system"))
}

@Test func routerPlanHasMatchDrivesChatBranch() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "command center status overview")
    #expect(r.goalType == "chat")
    #expect(!r.matchedCapabilities.isEmpty)
    #expect(r.nextActions.contains("Load matched capability only for this turn"))
    #expect(r.nextActions.contains("Record usage metadata"))
}

@Test func routerPlanNoMatchChatBranch() async throws {
    // Faithfulness gate against Python L15238 (select_context_capabilities):
    // every FeatureSurfaceRecord ships with status="ready", which earns the
    // unconditional +0.3 status bonus in score_context_capability. So even a
    // nonsense message scores 0.3 on every feature record and survives the
    // `score <= 0` filter (filter is < strictly, not <=). matchedCapabilities
    // is NEVER empty in capability-mode when feature records are in the input
    // set — Python behaves the same way. What we CAN assert is: every entry
    // in this no-genuine-match case has selectionReasons == ["fallback
    // ranking"] (no triggers, no name-match, no mode-bias hits) and a score
    // of exactly 0.3 (just the status bonus).
    let client = SwiftNativeRouterPlanClient()
    // Avoid the letter `x` (and other 1-char letters used as standalone
    // triggers by connector actions like x.status / x.me / x.search_recent)
    // so the scorer's trigger-substring check produces zero hits.
    let r = try await client.planRoute(message: "qpzrn blarg")
    #expect(r.goalType == "chat")
    // Capability-mode default limit is 8; with only the +0.3 status bonus
    // surviving the filter, we expect a non-empty matched list of fallback-
    // ranked entries.
    #expect(!r.matchedCapabilities.isEmpty)
    for cap in r.matchedCapabilities {
        guard case .object(let obj) = cap else {
            Issue.record("capability entry not an object")
            continue
        }
        // Every entry should be a pure fallback rank — no triggers, no name,
        // no mode-bias matched.
        if case .array(let reasons) = obj["selectionReasons"] ?? .null {
            #expect(reasons.count == 1)
            if case .string(let r0) = reasons.first ?? .null {
                #expect(r0 == "fallback ranking")
            } else {
                Issue.record("selectionReasons[0] not string")
            }
        } else {
            Issue.record("selectionReasons missing")
        }
        // Pure status-bonus score: 1.2 * 0 (no overlap) + 0.3 (status=ready).
        if case .double(let s) = obj["score"] ?? .null {
            #expect(s == 0.3)
        } else {
            Issue.record("score not double")
        }
        // matchedTerms must be empty — no token overlap.
        if case .array(let terms) = obj["matchedTerms"] ?? .null {
            #expect(terms.isEmpty)
        } else {
            Issue.record("matchedTerms missing")
        }
    }
}

@Test func capabilityRecordsPreSortedByUpdatedAtDesc() async throws {
    // Python L15742 pre-sorts records by (updatedAt or name) DESC before
    // select_context_capabilities sees them. The later score-sort is
    // STABLE so pre-sort order is the final tie-breaker on equal
    // score+status rows. Feature records all share `now` for updatedAt,
    // so the tie-breaker for them is name DESC.
    let now = "2026-05-31T00:00:00.000000+00:00"
    let records = swiftNativeCapabilityRecords(nowISO: now)
    // First 19 entries should be the feature records (all share `now` for
    // updatedAt) ordered by name DESC as the tie-breaker.
    let featureRecords = records.prefix(19)
    let names = featureRecords.map { $0.name }
    let sortedNames = names.sorted(by: >)
    #expect(names == sortedNames)
}

@Test func connectorActionStatusReflectsNativeConnectorSet() async throws {
    let now = "2026-05-31T00:00:00.000000+00:00"
    let records = swiftNativeCapabilityRecords(nowISO: now)
    // Find a known native connector action (local_files.search) — should be active.
    let lf = records.first { $0.id == "connector_action:local_files.search" }
    #expect(lf != nil)
    #expect(lf?.status == "active")
    // Find a known non-native connector action (gmail.list_inbox) — should be needs_setup.
    let gm = records.first { $0.id == "connector_action:gmail.list_inbox" }
    if gm != nil {
        #expect(gm?.status == "needs_setup")
    }
    // Slack has a native Swift connector executor; auth health is layered elsewhere.
    let sk = records.first { $0.id == "connector_action:slack.post_message" }
    if sk != nil {
        #expect(sk?.status == "active")
    }
}

// MARK: - Wave 31 — ProductionMigrationPlan parity tests

@Test func migrationPlanMatchesPythonStaticShape() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let client = SwiftNativeProductionMigrationPlanClient(now: { fixedNow })
    let result = try await client.migrationPlan()
    guard case .object(let obj) = result.toJSON() else {
        Issue.record("migration plan is not an object"); return
    }
    // Static fields are byte-accurate against the retired daemon.
    if case .string(let id) = obj["id"] ?? .null { #expect(id == "nativeagent-production-migration-v1") }
    else { Issue.record("missing id") }
    if case .string(let status) = obj["status"] ?? .null { #expect(status == "ready") }
    else { Issue.record("missing status") }
    guard case .array(let steps) = obj["steps"] ?? .null else {
        Issue.record("steps not an array"); return
    }
    #expect(steps.count == 5)
    // Step ids + statuses in order.
    let expected: [(String, String)] = [
        ("backup", "available"),
        ("export", "available"),
        ("install", "planned"),
        ("daemon_lifecycle", "available"),
        ("verify", "available"),
    ]
    for (i, step) in steps.enumerated() {
        guard case .object(let s) = step,
              case .string(let sid) = s["id"] ?? .null,
              case .string(let sstatus) = s["status"] ?? .null else {
            Issue.record("step \(i) malformed"); continue
        }
        #expect(sid == expected[i].0)
        #expect(sstatus == expected[i].1)
    }
    // createdAt comes from the injected clock.
    #expect(result.createdAt == SwiftNativeRouterPlanClient.isoTimestamp(fixedNow))
}

// MARK: - Wave 31 — ProductionExports parity tests

private func writeRegistry(_ value: JSONValue, into dir: URL) -> URL {
    let path = dir.appendingPathComponent("registry.json")
    let data = (try? value.serializedData(pretty: false)) ?? Data("[]".utf8)
    try? data.write(to: path)
    return path
}

@Test func productionExportsSortsByCreatedAtDescending() async throws {
    let dir = makeTempDir()
    let registry = JSONValue.array([
        .object(["id": .string("a"), "createdAt": .string("2026-05-01T00:00:00.000000+00:00"), "kind": .string("export")]),
        .object(["id": .string("b"), "createdAt": .string("2026-05-03T00:00:00.000000+00:00"), "kind": .string("support")]),
        .object(["id": .string("c"), "createdAt": .string("2026-05-02T00:00:00.000000+00:00"), "kind": .string("export")]),
    ])
    let path = writeRegistry(registry, into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.count == 3)
    // DESC by createdAt → b, c, a.
    func idOf(_ r: ProductionExportReceipt) -> String {
        if case .object(let o) = r.toJSON(), case .string(let s) = o["id"] ?? .null { return s }
        return ""
    }
    #expect(idOf(receipts[0]) == "b")
    #expect(idOf(receipts[1]) == "c")
    #expect(idOf(receipts[2]) == "a")
}

@Test func productionExportsMissingFileReturnsEmpty() async throws {
    let dir = makeTempDir()
    // Point at a non-existent registry.json — read_json(path, []) → [].
    let path = dir.appendingPathComponent("does-not-exist.json")
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.isEmpty)
}

@Test func productionExportsNonListPayloadReturnsEmpty() async throws {
    let dir = makeTempDir()
    // Python: `if not isinstance(exports, list): return []`.
    let path = writeRegistry(.object(["unexpected": .string("shape")]), into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.isEmpty)
}

@Test func productionExportsPreservesAllReceiptFields() async throws {
    let dir = makeTempDir()
    let registry = JSONValue.array([
        .object([
            "id": .string("x1"),
            "kind": .string("support"),
            "path": .string("/tmp/x1.tar.gz"),
            "scope": .array([.string("trust"), .string("catalog")]),
            "checksum": .string("deadbeef"),
            "sizeBytes": .int(4096),
            "createdAt": .string("2026-05-05T00:00:00.000000+00:00"),
        ]),
    ])
    let path = writeRegistry(registry, into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.count == 1)
    guard case .object(let o) = receipts[0].toJSON() else {
        Issue.record("receipt not an object"); return
    }
    if case .string(let p) = o["path"] ?? .null { #expect(p == "/tmp/x1.tar.gz") }
    else { Issue.record("path not preserved") }
    if case .string(let c) = o["checksum"] ?? .null { #expect(c == "deadbeef") }
    else { Issue.record("checksum not preserved") }
    if case .int(let sz) = o["sizeBytes"] ?? .null { #expect(sz == 4096) }
    else { Issue.record("sizeBytes not preserved") }
    if case .array(let scope) = o["scope"] ?? .null { #expect(scope.count == 2) }
    else { Issue.record("scope not preserved") }
}

@Test func productionExportsEmptyCreatedAtStableTieBreak() async throws {
    let dir = makeTempDir()
    // Two rows missing createdAt → both sort key "" → registry order preserved.
    let registry = JSONValue.array([
        .object(["id": .string("first")]),
        .object(["id": .string("second")]),
    ])
    let path = writeRegistry(registry, into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    func idOf(_ r: ProductionExportReceipt) -> String {
        if case .object(let o) = r.toJSON(), case .string(let s) = o["id"] ?? .null { return s }
        return ""
    }
    #expect(idOf(receipts[0]) == "first")
    #expect(idOf(receipts[1]) == "second")
}

// MARK: - SystemSubprocessRunner bounded-run regression (audit fix 2026-07-21)
//
// The old impl ran waitUntilExit() and only THEN drained the pipes — a child
// writing >64KB blocked on a full pipe and never exited; the deadline fired
// terminate() once with no SIGKILL escalation; and the deadline task was
// cancelled before the drains, so a grandchild holding the FDs hung the read
// unwatched. These tests pin the concurrent-drain + TERM→KILL contract.

@Test func systemSubprocessRunner_drainsLargeOutputWithoutDeadlock() async throws {
    let runner = SystemSubprocessRunner()
    // ~300KB stdout — far past the 64KB pipe buffer. The old read-after-wait
    // shape deadlocked here (child blocked on write, waitUntilExit never
    // returned). Wall-clock bound below is a gross-regression tripwire, not
    // a perf assertion.
    let start = Date()
    let result = try await runner.run(
        executable: "/usr/bin/python3",
        arguments: ["-c", "import sys; sys.stdout.write('x' * 300000); sys.stderr.write('y' * 70000)"],
        cwd: nil,
        timeout: 30,
        detached: false
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.count == 300000)
    #expect(result.stderr.count == 70000)
    #expect(Date().timeIntervalSince(start) < 60)
}

@Test func systemSubprocessRunner_timeoutEscalatesTermToKill() async throws {
    let runner = SystemSubprocessRunner()
    // Child IGNORES SIGTERM — the watchdog must escalate to SIGKILL after the
    // grace or run() never returns.
    let start = Date()
    let result = try await runner.run(
        executable: "/bin/bash",
        arguments: ["-c", "trap '' TERM; sleep 120"],
        cwd: nil,
        timeout: 1,
        detached: false
    )
    let elapsed = Date().timeIntervalSince(start)
    #expect(result.exitCode != 0)
    // timeout(1s) + kill grace(2s) + drain grace(≤2s each) ≈ 5s worst case;
    // 30s is the structural tripwire that proves escalation ran.
    #expect(elapsed < 30)
}
