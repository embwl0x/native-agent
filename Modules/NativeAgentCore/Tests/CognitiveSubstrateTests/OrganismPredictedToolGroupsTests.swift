import Testing
import Foundation
@testable import CognitiveSubstrate

// Mind-into-circulation (2026-07-10), fence B acceptance: pending TOOL expectations in
// the prospective-affect ledger map to bounded `predictedToolGroups` query terms for
// Fluid Context. Pure read — only pending, unexpired, TOOL-shaped predictions
// contribute; the group vocabulary is derived from the real chat-tool name families
// (CognitiveSomaticSignalAdapter encodes sourceOrgan as "tool.<toolName>").
@Suite("OrganismPredictedToolGroups")
struct OrganismPredictedToolGroupsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Build a prediction whose sourceOrgan mirrors what the somatic adapter stores:
    /// canonicalToken("tool.<toolName>") == "tool-<dashed-tool-name>".
    private func toolPrediction(
        toolName: String?,
        status: OrganismPredictionStatus = .pending,
        dueIn: TimeInterval = 60,
        kind: OrganismPredictionKind = .toolCompletion
    ) -> OrganismPrediction {
        let organ = toolName.map { "tool-\($0.replacingOccurrences(of: "_", with: "-"))" } ?? "tool"
        return OrganismPrediction(
            id: UUID().uuidString,
            kind: kind,
            sourceOrgan: organ,
            createdAt: now.addingTimeInterval(-30),
            dueAt: now.addingTimeInterval(dueIn),
            status: status,
            confidence: 0.55,
            uncertainty: 0.4,
            evidenceCount: 2,
            lastUpdatedAt: now
        )
    }

    private func ledger(_ predictions: [OrganismPrediction]) -> OrganismPredictionLedger {
        var dict: [String: OrganismPrediction] = [:]
        for prediction in predictions { dict[prediction.id] = prediction }
        return OrganismPredictionLedger(predictions: dict)
    }

    // MARK: - Required acceptance

    @Test func emptyLedgerYieldsEmptySet() {
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: .empty, at: now)
        #expect(groups.isEmpty)
    }

    @Test func pendingToolShapedPredictionYieldsItsMappedGroup() {
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger([toolPrediction(toolName: "github_get_issue")]), at: now)
        #expect(groups == ["github"])
    }

    @Test func expiredPredictionYieldsNothing() {
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger([toolPrediction(toolName: "github_get_issue", status: .expired)]),
            at: now)
        #expect(groups.isEmpty)
    }

    @Test func resolvedPredictionYieldsNothing() {
        // Both terminal resolutions must contribute nothing.
        let satisfied = toolPrediction(toolName: "recall_memory", status: .satisfied)
        let violated = toolPrediction(toolName: "desk_add_item", status: .violated)
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger([satisfied, violated]), at: now)
        #expect(groups.isEmpty)
    }

    @Test func providerShapedPredictionYieldsNothing() {
        // Every non-tool kind is a system/infrastructure outcome — none map, even if
        // (defensively) they carried a tool-looking sourceOrgan.
        let provider = toolPrediction(
            toolName: nil, dueIn: 30, kind: .providerCompletion)
        let phone = toolPrediction(toolName: nil, dueIn: 120, kind: .phoneDelivery)
        let approval = toolPrediction(toolName: nil, dueIn: 300, kind: .approvalResolution)
        let workflow = toolPrediction(toolName: "desk_close", dueIn: 300, kind: .workflowAdvance)
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger([provider, phone, approval, workflow]), at: now)
        #expect(groups.isEmpty)
    }

    @Test func capHoldsAtEight() {
        // Nine distinct tool families, all pending and live → capped to 8, deterministic.
        let families = [
            "github_status", "git_diff", "desk_add_item", "mail_send", "music_control",
            "notes_search", "contacts_search", "market_quote", "slack_status",
        ]
        let predictions = families.map { toolPrediction(toolName: $0) }
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger(predictions), at: now)
        #expect(groups.count == 8)
        // Deterministic keep-set: the 8 lexicographically-smallest of the 9 groups.
        let allGroups = ["contacts", "desk", "git", "github", "mail", "market", "music", "notes", "slack"]
        #expect(groups == Set(allGroups.sorted().prefix(8)))
    }

    // MARK: - Mapping-table evidence

    @Test func mappingCollapsesMachinePrefixesOntoConsumableWords() {
        let cases: [(tool: String, group: String)] = [
            ("github_list_repos", "github"),
            ("git_status", "git"),
            ("recall_memory", "memory"),
            ("commit_memory", "memory"),
            ("agentmail_send", "mail"),
            ("mail_reply", "mail"),
            ("mac_calendar_create_event", "calendar"),
            ("mac_reminders_list_due_today", "reminders"),
            ("mac_spotlight_search", "spotlight"),
            ("tradingview_watchlist", "market"),
            ("desk_close", "desk"),
            ("music_now_playing", "music"),
        ]
        for c in cases {
            let groups = OrganismProspectiveAffect.predictedToolGroups(
                ledger: ledger([toolPrediction(toolName: c.tool)]), at: now)
            #expect(groups == [c.group], "\(c.tool) should map to \(c.group)")
        }
    }

    @Test func unnamedToolExpectationMapsToGenericGroup() {
        // A toolStarted signal with no toolName metadata → bare "tool" sourceOrgan.
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger([toolPrediction(toolName: nil)]), at: now)
        #expect(groups == ["tools"])
    }

    @Test func duplicateFamiliesCollapseToOneGroup() {
        let predictions = [
            toolPrediction(toolName: "github_get_issue"),
            toolPrediction(toolName: "github_list_pull_requests"),
            toolPrediction(toolName: "github_status"),
        ]
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger(predictions), at: now)
        #expect(groups == ["github"])
    }

    // MARK: - Liveness comes from the ledger's lifecycle, not wall-clock

    /// gpt-5.5 review MED (2026-07-10): the generic 90s prediction horizon is
    /// far shorter than real dispatches (interactive tools run minutes;
    /// explicit timeouts reach 3600s). An overdue-but-still-.pending tool
    /// expectation is a LONG-RUNNING tool whose result is still expected —
    /// exactly when its group should steer context. Only the ledger's own
    /// expiry sweep (status == .expired) retires it.
    @Test func overduePendingPredictionStillContributesUntilExpirySweep() {
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger([toolPrediction(toolName: "github_status", dueIn: -1)]),
            at: now)
        #expect(groups == ["github"], "a late tool is still an expected tool: \(groups)")
    }

    @Test func mixedLedgerKeepsOnlyLiveToolExpectations() {
        let predictions = [
            toolPrediction(toolName: "github_status"),                       // live tool → github
            toolPrediction(toolName: "mail_send", status: .satisfied),       // resolved → drop
            toolPrediction(toolName: "git_diff", dueIn: -5),                 // overdue but pending → keep (git)
            toolPrediction(toolName: nil, kind: .providerCompletion),        // provider → drop
            toolPrediction(toolName: "desk_note"),                           // live tool → desk
        ]
        let groups = OrganismProspectiveAffect.predictedToolGroups(
            ledger: ledger(predictions), at: now)
        #expect(groups == ["github", "desk", "git"])
    }

    /// The verb-tool overrides (gpt-5.5 review LOW, 2026-07-10): core tools
    /// whose first segment is a weak verb map onto the content word their
    /// outputs co-occur with; MCP names surface the server segment.
    @Test func verbToolsAndMCPNamesMapToContentWords() {
        let cases: [(String, String)] = [
            ("read_file", "files"), ("write_file", "files"), ("list_dir", "files"),
            ("apply_patch", "files"), ("shell", "shell"), ("invoke_codex", "agents"),
        ]
        for (tool, expected) in cases {
            let groups = OrganismProspectiveAffect.predictedToolGroups(
                ledger: ledger([toolPrediction(toolName: tool)]), at: now)
            #expect(groups == [expected], "\(tool) → \(groups), wanted \(expected)")
        }
    }

    // MARK: - Purity

    @Test func readIsPureAndDeterministic() {
        let source = ledger([
            toolPrediction(toolName: "github_status"),
            toolPrediction(toolName: "mail_send"),
        ])
        let a = OrganismProspectiveAffect.predictedToolGroups(ledger: source, at: now)
        let b = OrganismProspectiveAffect.predictedToolGroups(ledger: source, at: now)
        #expect(a == b)
        #expect(a == ["github", "mail"])
        // The ledger is a value type passed by copy; the read cannot mutate the caller's.
        #expect(source.predictions.count == 2)
    }

    // MARK: - Kernel exposure

    @Test func kernelExposesLivePendingGroups() async {
        let fixed = now
        let kernel = OrganismKernel(
            configuration: OrganismConfiguration(enabled: true),
            dependencies: OrganismDependencies(now: { fixed }),
            predictionLedger: ledger([
                toolPrediction(toolName: "github_get_issue"),
                toolPrediction(toolName: "recall_memory"),
            ])
        )
        let groups = await kernel.predictedToolGroups()
        #expect(groups == ["github", "memory"])
    }

    @Test func disabledKernelYieldsEmptySet() async {
        let fixed = now
        let kernel = OrganismKernel(
            configuration: OrganismConfiguration(enabled: false),
            dependencies: OrganismDependencies(now: { fixed }),
            predictionLedger: ledger([toolPrediction(toolName: "github_get_issue")])
        )
        let groups = await kernel.predictedToolGroups()
        #expect(groups.isEmpty)
    }
}
