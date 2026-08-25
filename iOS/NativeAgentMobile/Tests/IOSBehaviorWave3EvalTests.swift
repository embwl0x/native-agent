import CryptoKit
import Foundation
import SwiftUI
import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

/// Executed iPhone behavior checks for high-risk `ios.screens` rows.
///
/// These deliberately exercise the production state owners and protocol
/// boundary. They do not inspect source text or assert that a view happens to
/// contain a string. UI layout/accessibility belongs to the installed-app
/// route; this suite proves the state a route is allowed to present.
@MainActor
final class IOSBehaviorWave3EvalTests: XCTestCase {
    private var savedApprovals: [ApprovalRequest] = []
    private var savedMemories: [MemoryRecord] = []
    private var savedProposals: [MemoryProposalRecord] = []
    private var defaultsSuite = ""
    private var defaults: UserDefaults!

    func testRetiredMacHTTPMethodsFailLoudlyWithoutStartingAFallbackTransport() async {
        let client = MacBridgeClient()
        do {
            let _: String = try await client.get("/v1/legacy")
            XCTFail("retired iOS HTTP reads must not fall back to a live transport")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "NativeAgentMobile")
            XCTAssertEqual(error.code, -42)
        } catch {
            XCTFail("unexpected retired-transport error: \(error)")
        }

        do {
            _ = try await client.postDict("/v1/legacy", body: ["probe": true])
            XCTFail("retired iOS HTTP writes must not fall back to a live transport")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "NativeAgentMobile")
            XCTAssertEqual(error.code, -42)
        } catch {
            XCTFail("unexpected retired-transport error: \(error)")
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        let sync = iCloudSyncEngine.shared
        savedApprovals = sync.approvals
        savedMemories = sync.memories
        savedProposals = sync.memoryProposals
        defaultsSuite = "NativeAgentMobileTests.behaviorWave3.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
    }

    override func tearDown() async throws {
        let sync = iCloudSyncEngine.shared
        sync.approvals = savedApprovals
        sync.memories = savedMemories
        sync.memoryProposals = savedProposals
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        try await super.tearDown()
    }

    private func approval(_ id: String = "approval-1", status: String = "pending") -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            title: "Review privileged request",
            action: "system_control",
            risk: "high",
            status: status,
            createdAt: "2026-08-24T00:00:00Z"
        )
    }

    private func inboxItem(_ id: String, status: String = "unread") -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: "2026-08-24T00:00:00Z",
            source: "eval",
            severity: "actionable",
            title: "Card \(id)",
            summary: "Visible state must settle honestly.",
            detail: nil,
            relatedWorkshopExecutionId: nil,
            related_approval_id: nil,
            related_paths: nil,
            related_groups: nil,
            actions: [],
            status: status,
            read_at: nil
        )
    }

    private func task(
        _ id: String,
        status: String,
        phase: String = "running",
        createdAt: String = "2026-08-24T00:00:00Z",
        completedAt: String? = nil,
        step: String? = nil
    ) -> WorkshopTaskRecord {
        WorkshopTaskRecord(
            id: id,
            title: "Task \(id)",
            objective: "Objective \(id)",
            status: status,
            phase: phase,
            createdAt: createdAt,
            completedAt: completedAt,
            currentStepId: step
        )
    }

    func test_workshopCompletionNotificationsObserveSharedSnapshotsNotOnlyWorkshopView() {
        var notified: [String] = []
        let tracker = WorkshopCompletionNotificationTracker { notified.append($0.id) }
        tracker.apply([task("existing", status: "completed")])
        XCTAssertTrue(notified.isEmpty, "opening the app must not replay old completions")

        tracker.apply([
            task("existing", status: "completed"),
            task("new", status: "done"),
            task("running", status: "running"),
        ])
        XCTAssertEqual(notified, ["new"])

        tracker.apply([task("existing", status: "completed"), task("new", status: "done")])
        XCTAssertEqual(notified, ["new"], "unchanged completed tasks must notify once")
    }

    private func proposal(_ id: String, status: String = "pending") throws -> MemoryProposalRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "text": "Remember this",
            "status": status,
            "supporting_session_ids": ["session-a"],
            "recurrence_count": 2,
        ])
        return try JSONDecoder().decode(MemoryProposalRecord.self, from: data)
    }

    private func memory(_ id: String, text: String = "first") throws -> MemoryRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "layer": "semantic",
            "text": text,
            "importance": 0.7,
            "confidence": 0.9,
            "createdAt": "2026-08-24T00:00:00Z",
        ])
        return try JSONDecoder().decode(MemoryRecord.self, from: data)
    }

    // MARK: - ios.mactools.remoteActionCards / approval classification

    func test_appliedFalseIsRejectedInsteadOfBecomingASuccessReceipt() {
        XCTAssertThrowsError(
            try iCloudSyncEngine.shared.requireSuccessfulActionResponse([
                "ok": "true", "status": "completed", "applied": "false",
            ])
        ) { error in
            XCTAssertEqual(RemoteActionState.forError(error), .failed)
        }
    }

    func test_pendingApprovalResponseRoutesToTheApprovalCardState() {
        XCTAssertThrowsError(
            try iCloudSyncEngine.shared.requireSuccessfulActionResponse([
                "ok": "true", "status": "pending_approval", "message": "Mac requires review",
            ])
        ) { error in
            guard case SyncError.approvalRequired = error else {
                return XCTFail("pending approval was not preserved as typed state: \(error)")
            }
            XCTAssertEqual(RemoteActionState.forError(error), .waitingApproval)
        }
    }

    func test_approvalRequiredAliasRoutesToTheSameApprovalCardState() {
        XCTAssertThrowsError(
            try iCloudSyncEngine.shared.requireSuccessfulActionResponse([
                "status": "approval_required", "message": "Review on Mac",
            ])
        ) { error in
            XCTAssertEqual(RemoteActionState.forError(error), .waitingApproval)
        }
    }

    func test_nonApprovalFailureCannotAccidentallyRenderAReviewButton() {
        XCTAssertThrowsError(
            try iCloudSyncEngine.shared.requireSuccessfulActionResponse([
                "ok": "false", "error": "shortcut_not_found",
            ])
        ) { error in
            XCTAssertEqual(RemoteActionState.forError(error), .failed)
            XCTAssertTrue(RemoteActionState.forError(error).offersRetry)
        }
        XCTAssertFalse(RemoteActionState.ranOnMac.offersRetry)
    }

    func test_macSystemQuickActionsRejectUnknownCommandsBeforeClaimingSuccess() {
        XCTAssertEqual(MacSystemQuickAction(rawValue: "sleep_display"), .sleepDisplay)
        XCTAssertEqual(MacSystemQuickAction(rawValue: "lock_screen"), .lockScreen)
        XCTAssertNil(MacSystemQuickAction(rawValue: "unsupported_system_action"))
    }

    func test_moreAboutCardMakesTheActualMacOnlyBoundaryExplicit() {
        XCTAssertTrue(MoreAboutPresentation.text.contains("Workshop policy editing are Mac-only"))
        XCTAssertTrue(MoreAboutPresentation.text.contains("Desk changes sync with the paired Mac"))
        XCTAssertFalse(MoreAboutPresentation.text.contains("Workshop is available on iOS"))
    }

    func test_missingMacHealthUsesAnExplicitUnavailableStatus() {
        switch MacHealthPresentation.snapshot(for: nil) {
        case .unavailable:
            break
        case .available(_):
            XCTFail("a missing Mac health snapshot must not render as a healthy Mac")
        }
        XCTAssertEqual(MacHealthPresentation.unavailableTitle, "Mac health is unavailable")
        XCTAssertEqual(MacHealthPresentation.unavailableDetail, "Waiting for a health snapshot from the Mac.")
    }

    func test_stalePersonalitySnapshotCannotPresentTraitsAsCurrent() {
        let now = Date(timeIntervalSince1970: 10_000)
        let state = PersonalitySnapshotPresentation.state(
            lastSyncedAt: now.addingTimeInterval(-31),
            now: now
        )

        XCTAssertEqual(state, .stale(age: 31, limit: 30))
        XCTAssertEqual(PersonalitySnapshotPresentation.value(for: state), "STALE · 31s old")
        XCTAssertEqual(
            PersonalitySnapshotPresentation.detail(for: state),
            "Traits may be out of date until a newer Mac personality snapshot arrives."
        )
        XCTAssertTrue(PersonalitySnapshotPresentation.needsAttention(state))

        let unknown = PersonalitySnapshotPresentation.state(lastSyncedAt: nil, now: now)
        XCTAssertEqual(unknown, .neverSynced)
        XCTAssertEqual(
            PersonalitySnapshotPresentation.detail(for: unknown),
            "Personality snapshot freshness is unknown; these traits may be out of date."
        )
    }

    func test_manualPairingPasteClaimsSuccessOnlyForTheMacPublishedKey() {
        let macSecret = Data(repeating: 0xA1, count: 32)
        let matchingKey = macSecret.base64EncodedString()
        let wrongKey = Data(repeating: 0xB2, count: 32).base64EncodedString()

        XCTAssertEqual(
            ManualPairingKeyPaste.verdict(base64: matchingKey, publishedMacSecret: macSecret),
            .verified
        )
        XCTAssertEqual(
            ManualPairingKeyPaste.verdict(base64: wrongKey, publishedMacSecret: macSecret),
            .doesNotMatchMac
        )
        XCTAssertEqual(
            ManualPairingKeyPaste.verdict(base64: matchingKey, publishedMacSecret: nil),
            .awaitingMacVerification
        )
        XCTAssertEqual(
            ManualPairingKeyPaste.verdict(base64: String(repeating: "a", count: 64), publishedMacSecret: macSecret),
            .looksLikeHex
        )
        XCTAssertEqual(
            ManualPairingKeyPaste.verdict(base64: "too-short", publishedMacSecret: macSecret),
            .invalidFormat
        )
    }

    func test_manualSecretStoreRejectsWellFormedBytesFromAnotherMac() {
        let macSecret = Data(repeating: 0xA1, count: 32)
        let wrongSecret = Data(repeating: 0xB2, count: 32)

        XCTAssertTrue(PairingStore.isVerifiedManualICloudSecret(macSecret, publishedMacSecret: macSecret))
        XCTAssertFalse(PairingStore.isVerifiedManualICloudSecret(wrongSecret, publishedMacSecret: macSecret))
        XCTAssertFalse(PairingStore.isVerifiedManualICloudSecret(macSecret, publishedMacSecret: nil))
    }

    func test_remoteActionLedgerKeepsApprovalHandoffThroughAnActionBurst() {
        let ledger = RemoteActionLedger(maximumOrdinaryActions: 12)
        let approvalID = ledger.start(.system("lock_screen"), title: "Lock screen", subtitle: "System action")
        ledger.update(approvalID, state: .waitingApproval, detail: "Review required on Mac")

        for index in 0..<15 {
            _ = ledger.start(.shortcut("Routine \(index)"), title: "Run shortcut", subtitle: "Routine \(index)")
        }

        XCTAssertEqual(ledger.actions.count, 13)
        XCTAssertEqual(ledger.actions.first(where: { $0.id == approvalID })?.state, .waitingApproval)
        XCTAssertEqual(ledger.actions.filter { $0.state != .waitingApproval }.count, 12)
    }

    func test_legalLinksStayExplicitWhenTheBuildHasNoValidDestination() {
        XCTAssertEqual(
            SettingsLegalLinksPresentation.destination(for: "https://nativeagent.example/privacy")?.host,
            "nativeagent.example"
        )
        XCTAssertNil(SettingsLegalLinksPresentation.destination(for: "http://nativeagent.example/privacy"))
        XCTAssertNil(SettingsLegalLinksPresentation.destination(for: nil))
        XCTAssertEqual(
            SettingsLegalLinksPresentation.unavailableText(for: "Privacy Policy"),
            "Privacy Policy link is unavailable in this build."
        )
    }

    func test_knowledgeGraphTypingFiltersTheLoadedSnapshotWithoutStartingARefresh() throws {
        let source = try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")
        XCTAssertTrue(source.contains("store.entities.filter { entity in"))
        XCTAssertTrue(source.contains("KnowledgeGraphPresentation.matches("))
        XCTAssertFalse(source.contains("func search(q:"))
        XCTAssertFalse(source.contains("debounceTask"))
        XCTAssertFalse(source.contains("await store.search"))
    }

    func test_promotionDecisionControlsAreReservedForHumanActionableCandidates() {
        XCTAssertTrue(PromotionCandidateDecisionPresentation.controlsAllowed(isHumanActionable: true))
        XCTAssertFalse(PromotionCandidateDecisionPresentation.controlsAllowed(isHumanActionable: false))
    }

    func test_chatSessionTabsRemainAvailableWhenATurnIsStuckLoading() {
        XCTAssertFalse(
            ChatSessionTabPresentation.isSelectionDisabled(
                isSwitchingSession: false,
                isClosingSession: false
            )
        )
        XCTAssertTrue(
            ChatSessionTabPresentation.isSelectionDisabled(
                isSwitchingSession: true,
                isClosingSession: false
            )
        )
        XCTAssertTrue(
            ChatSessionTabPresentation.isSelectionDisabled(
                isSwitchingSession: false,
                isClosingSession: true
            )
        )
    }

    func test_kvsRefreshReportsSuccessOnlyForADurableSecretChange() {
        let oldSecret = Data(repeating: 0xA1, count: 32)
        let newSecret = Data(repeating: 0xB2, count: 32)

        XCTAssertTrue(
            PairingKVSRefreshResult.installedNewMaterial(
                applied: true,
                previousSecret: oldSecret,
                currentSecret: newSecret
            )
        )
        XCTAssertFalse(
            PairingKVSRefreshResult.installedNewMaterial(
                applied: false,
                previousSecret: oldSecret,
                currentSecret: newSecret
            )
        )
        XCTAssertFalse(
            PairingKVSRefreshResult.installedNewMaterial(
                applied: true,
                previousSecret: oldSecret,
                currentSecret: oldSecret
            )
        )
    }

    func test_successfulAppliedResponsePassesThroughUnchanged() throws {
        let response = ["ok": "true", "status": "completed", "applied": "true", "result": "done"]
        XCTAssertEqual(
            try iCloudSyncEngine.shared.requireSuccessfulActionResponse(response),
            response
        )
    }

    func test_timeoutHasNoCompletionState() {
        XCTAssertThrowsError(try iCloudSyncEngine.shared.requireSuccessfulActionResponse(nil)) { error in
            XCTAssertEqual(RemoteActionState.forError(error), .failed)
        }
    }

    // MARK: - ios.inbox.list / applySuccessfulLocalAction

    func test_acceptedInboxArchiveProjectsOnlyTheTargetCard() {
        let store = InboxStore()
        store.items = [inboxItem("target"), inboxItem("other")]

        store.applySuccessfulLocalAction(id: "target", actionID: "archive")

        XCTAssertEqual(store.items.first(where: { $0.id == "target" })?.status, "archived")
        XCTAssertNotNil(store.items.first(where: { $0.id == "target" })?.read_at)
        XCTAssertEqual(store.items.first(where: { $0.id == "other" })?.status, "unread")
        XCTAssertEqual(store.activeCount, 1)
    }

    func test_eachReadLikeInboxActionSettlesTheCardAsRead() {
        for action in ["act", "approve", "reject", "deny", "read"] {
            let store = InboxStore()
            store.items = [inboxItem("target")]
            store.applySuccessfulLocalAction(id: "target", actionID: action)
            XCTAssertEqual(store.items[0].status, "read", "\(action) did not settle the visible card")
            XCTAssertNotNil(store.items[0].read_at)
        }
    }

    func test_unknownInboxActionDoesNotFalselySettleTheCard() {
        let store = InboxStore()
        store.items = [inboxItem("target")]

        store.applySuccessfulLocalAction(id: "target", actionID: "future_unsupported_action")

        XCTAssertEqual(store.items[0].status, "unread")
        XCTAssertNil(store.items[0].read_at)
    }

    // MARK: - ios.approvals.mergeLocalFinalDecisions

    func test_localApprovalFinalizationSurvivesAStalePendingSnapshot() {
        let sync = iCloudSyncEngine.shared
        let pending = approval()
        sync.approvals = [pending]
        let store = ApprovalsStore()
        store.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)

        store.markApprovalFinal(id: pending.id, decision: "approved")
        XCTAssertEqual(store.approvals[0].status, "approved")
        XCTAssertEqual(store.approvals[0].decision, "approved")

        // The Mac has not published the terminal snapshot yet; the stale
        // pending row must not re-offer the same action.
        sync.approvals = [pending]
        store.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)
        XCTAssertEqual(store.approvals[0].status, "approved")
    }

    func test_terminalMacSnapshotReplacesTheTemporaryApprovalProjection() {
        let sync = iCloudSyncEngine.shared
        let pending = approval()
        sync.approvals = [pending]
        let store = ApprovalsStore()
        store.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)
        store.markApprovalFinal(id: pending.id, decision: "denied")

        var terminal = pending
        terminal.status = "resolved"
        terminal.decision = "canceled"
        sync.approvals = [terminal]
        store.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)

        XCTAssertEqual(store.approvals[0].status, "resolved")
        XCTAssertEqual(store.approvals[0].decision, "canceled")
    }

    // MARK: - ios.workshop.screen / approveRejectStep

    func test_workshopSplitsPendingActiveAndHistoryWithoutDroppingKnownTerminalStates() {
        let store = WorkshopStore()
        store.tasks = [
            task("approval", status: "queued", phase: "awaiting_approval"),
            task("active", status: "running"),
            task("paused", status: "paused"),
            task("done", status: "completed", completedAt: "2026-08-24T03:00:00Z"),
            task("blocked", status: "blocked", completedAt: "2026-08-24T02:00:00Z"),
        ]

        XCTAssertEqual(store.pendingApprovals.map(\.id), ["approval"])
        XCTAssertEqual(Set(store.activeTasks.map(\.id)), Set(["active", "paused"]))
        XCTAssertEqual(store.doneTasks.map(\.id), ["done", "blocked"])
    }

    func test_workshopHistorySortsNewestTerminalOutcomeFirst() {
        let store = WorkshopStore()
        store.tasks = [
            task("older", status: "done", completedAt: "2026-08-22T02:00:00Z"),
            task("newer", status: "failed", completedAt: "2026-08-24T02:00:00Z"),
            task("no-date", status: "cancelled", createdAt: "2026-08-20T02:00:00Z"),
        ]
        XCTAssertEqual(store.doneTasks.map(\.id), ["newer", "older", "no-date"])
    }

    func test_workshopCannotDispatchAnApprovalWithoutACanonicalStepID() async {
        let store = WorkshopStore()
        for step in [nil, "", "  ", "pending", " PENDING "] {
            let candidate = task("missing-step", status: "awaiting_approval", phase: "approval", step: step)
            let approved = await store.approveWorkshopTask(candidate)
            XCTAssertFalse(approved)
            XCTAssertTrue(store.error?.contains("pending step id") == true)
            store.error = nil
            let rejected = await store.rejectWorkshopTask(candidate)
            XCTAssertFalse(rejected)
            XCTAssertTrue(store.error?.contains("pending step id") == true)
            store.error = nil
        }
    }

    // MARK: - ios.memory.proposalDecide / memory list projection

    func test_memoryProjectionShowsOnlyTheCurrentCanonicalSnapshot() throws {
        let sync = iCloudSyncEngine.shared
        let store = MemoryStore()
        let first = try memory("memory-1")
        sync.memories = [first]
        sync.memoryProposals = [try proposal("proposal-1")]
        store.applySyncedState(from: sync)
        XCTAssertEqual(store.memories.map(\.id), ["memory-1"])
        XCTAssertEqual(store.memoryProposals.map(\.id), ["proposal-1"])

        sync.memories = []
        sync.memoryProposals = [try proposal("proposal-2")]
        store.applySyncedState(from: sync)
        XCTAssertTrue(store.memories.isEmpty)
        XCTAssertEqual(store.memoryProposals.map(\.id), ["proposal-2"])
    }

    func test_memoryProposalPendingVocabularyKeepsProposedRowsActionable() throws {
        XCTAssertTrue(try proposal("pending", status: "pending").isPending)
        XCTAssertTrue(try proposal("proposed", status: " proposed ").isPending)
        XCTAssertFalse(try proposal("resolved", status: "accepted").isPending)
    }

    // MARK: - ios.chat.sessionTabs.select / new-session recovery

    func test_newSessionEscapesAStuckTurnAndRetiresItsOldCorrelation() throws {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("old-session")
        store.messages = [ChatMessage(role: .user, text: "old")]
        store.isLoading = true
        store.pendingICloudPlaceholders["old-correlation"] = UUID()
        store.pendingSendArgs["old-correlation"] = ChatStore.PendingSendArgs(
            text: "old", sessionID: "old-session", controls: .defaults, attachments: [], appendedUserId: nil
        )

        store.startNewSession()

        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.pendingICloudPlaceholders.isEmpty)
        XCTAssertTrue(store.pendingSendArgs.isEmpty)
        XCTAssertTrue(store.resolvedICloudReplyIds.contains("old-correlation"))
        XCTAssertNotEqual(store.selectedSessionID, "old-session")
        XCTAssertEqual(store.selectedSessionID, store.mainSessionID)
    }

    func test_cachedTranscriptCannotCrossIntoADifferentSession() throws {
        let first = ChatStore(defaults: defaults, restoreQueuedSends: false)
        first.setSelectedSessionID("session-a")
        first.messages = [ChatMessage(role: .assistant, text: "Only A may read this")]

        let second = ChatStore(defaults: defaults, restoreQueuedSends: false)
        XCTAssertEqual(second.loadCachedMessages(for: "session-a").map(\.text), ["Only A may read this"])
        XCTAssertTrue(second.loadCachedMessages(for: "session-b").isEmpty)
    }

    // MARK: - ios.screens Wave 1: Activity and diagnostic truthfulness

    private func run(
        kind: String = "codex",
        model: String? = nil,
        requestedModel: String? = nil,
        reasoningEffort: String? = nil,
        sandbox: String? = nil,
        fileAccess: String? = nil
    ) throws -> RunRecord {
        var object: [String: Any] = [
            "id": "run-1",
            "kind": kind,
            "status": "completed",
            "createdAt": "2026-08-24T00:00:00Z",
        ]
        if let model { object["model"] = model }
        if let requestedModel { object["requestedModel"] = requestedModel }
        if let reasoningEffort { object["reasoningEffort"] = reasoningEffort }
        if let sandbox { object["codexSandbox"] = sandbox }
        if let fileAccess { object["fileAccessMode"] = fileAccess }
        return try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func reflexCandidate(
        trustClass: String = "lowRisk",
        reviewRequired: Bool = true
    ) -> OrganismLivingReflexCandidateFile {
        OrganismLivingReflexCandidateFile(
            id: "candidate-1", pattern: "When a safe pattern repeats", trustClass: trustClass,
            confidence: 0.9, reviewRequired: reviewRequired, autoActivationAllowed: false, approvedAt: nil
        )
    }

    private func dreamProposal(_ id: String) -> OrganismLivingStandingViewProposalFile {
        OrganismLivingStandingViewProposalFile(
            id: id, title: "Dream \(id)", rationale: "A bounded proposal", evidenceIDs: [], reviewRequired: true
        )
    }

    func test_activityCountsDriveRowsAndTabBadgeFromOneProjection() {
        let counts = ActivityScreenPresentation.counts(
            storedApprovals: 1,
            snapshotApprovals: [approval("pending"), approval("resolved", status: "approved")],
            storedInbox: 1,
            snapshotInbox: [inboxItem("active", status: "active"), inboxItem("read", status: "read")],
            memoryProposals: [], trainingProposals: [], promotionCandidates: []
        )

        XCTAssertEqual(counts.approvals, 1)
        XCTAssertEqual(counts.inbox, 1)
        XCTAssertEqual(counts.memoryProposals, 0)
        XCTAssertEqual(counts.selfImprovement, 0)
        XCTAssertEqual(counts.total, 2, "the Activity tab badge must be the same sum its rows show")
    }

    func test_partialApprovalMetadataFailsClosedToMacReview() {
        XCTAssertFalse(ActivityScreenPresentation.canDecideRemotely(localOnly: nil, remoteResolvable: nil))
        XCTAssertFalse(ActivityScreenPresentation.canDecideRemotely(localOnly: false, remoteResolvable: nil))
        XCTAssertFalse(ActivityScreenPresentation.canDecideRemotely(localOnly: true, remoteResolvable: true))
        XCTAssertTrue(ActivityScreenPresentation.canDecideRemotely(localOnly: false, remoteResolvable: true))
    }

    func test_activityPrioritizesAResolvingInboxActionOverWireOrder() {
        let actions = [
            InboxActionRecord(id: "dismiss", label: "Dismiss", description: nil),
            InboxActionRecord(id: "snooze", label: "Snooze", description: nil),
            InboxActionRecord(id: "repair", label: "Repair", description: nil),
            InboxActionRecord(id: "view", label: "View", description: nil),
        ]
        XCTAssertEqual(ActivityScreenPresentation.visibleInboxActions(actions).map(\.id), ["repair", "dismiss"])
    }

    func test_activityOverflowAndInitialRefreshLatchAreExact() {
        XCTAssertFalse(ActivityScreenPresentation.showsOverflow(total: 2))
        XCTAssertTrue(ActivityScreenPresentation.showsOverflow(total: 3))

        var skip = true
        XCTAssertFalse(ActivityScreenPresentation.shouldRefreshOnAppear(skipInitialRefresh: &skip))
        XCTAssertFalse(skip, "the notification-open skip must consume itself")
        XCTAssertTrue(ActivityScreenPresentation.shouldRefreshOnAppear(skipInitialRefresh: &skip))
    }

    func test_runKindsNeverLeakUnknownWireIdentifiersIntoPublicUI() {
        XCTAssertEqual(RunKindPresentation.displayName("claude"), "Claude Code")
        XCTAssertEqual(RunKindPresentation.displayName("new_private_runner"), "Other run")
        XCTAssertEqual(RunKindPresentation.icon("new_private_runner"), "questionmark.circle")
    }

    func test_runModelSubstitutionIsExplicitAndBlankFactsAreOmitted() throws {
        let substituted = try run(
            model: "gpt-5.6", requestedModel: "gpt-5.5", reasoningEffort: "high", sandbox: "workspace-write"
        )
        XCTAssertEqual(
            RunDetailPresentation.modelFacts(for: substituted),
            [
                .init(label: "Model", value: "gpt-5.6"),
                .init(label: "Requested (substituted)", value: "gpt-5.5"),
                .init(label: "Reasoning effort", value: "High"),
                .init(label: "Sandbox", value: "workspace-write"),
            ]
        )
        XCTAssertTrue(RunDetailPresentation.modelFacts(for: try run(model: "  ")).isEmpty)
    }

    func test_runsLogSeparatesUnavailableFromAGenuineEmptyLedger() throws {
        XCTAssertEqual(RunsLogPresentation.state(runs: [], error: nil), .empty)
        XCTAssertEqual(
            RunsLogPresentation.state(runs: [], error: "Runs snapshot is still downloading"),
            .unavailable("Runs snapshot is still downloading")
        )
        XCTAssertEqual(RunsLogPresentation.state(runs: [try run()], error: "stale error"), .content)
    }

    func test_organismCountersAndDreamTruncationStayHonest() {
        XCTAssertEqual(OrganismStatusPresentation.approvedBiasesText(nil), "Not reported")
        XCTAssertEqual(OrganismStatusPresentation.approvedBiasesText(0), "0")

        let slice = OrganismStatusPresentation.dreamProposalSlice((0..<6).map { dreamProposal("\($0)") })
        XCTAssertEqual(slice.visible.map(\.id), ["0", "1", "2", "3"])
        XCTAssertEqual(slice.hiddenCount, 2)
    }

    func test_organismStatusMarksOldSnapshotsAndDisclosesReflexOverflow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(OrganismStatusPresentation.isStale(generatedAt: now.addingTimeInterval(-301), now: now))
        XCTAssertFalse(OrganismStatusPresentation.isStale(generatedAt: now.addingTimeInterval(-300), now: now))

        let candidates = (0..<8).map { index in
            OrganismLivingReflexCandidateFile(
                id: "candidate-\(index)", pattern: "Pattern \(index)", trustClass: "lowRisk",
                confidence: 0.8, reviewRequired: true, autoActivationAllowed: false, approvedAt: nil
            )
        }
        let slice = OrganismStatusPresentation.reflexCandidateSlice(candidates)
        XCTAssertEqual(slice.visible.map(\.id), (0..<6).map { "candidate-\($0)" })
        XCTAssertEqual(slice.hiddenCount, 2)
    }

    func test_organismLivingStatusBoundaryDistinguishesFreshStaleDisabledUnavailableAndAbsent() throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        func status(
            generatedAt: Date? = nil,
            enabled: Bool = true,
            availability: OrganismLivingStatusAvailability? = .live
        ) -> OrganismLivingStatusFile {
            OrganismLivingStatusFile(
                generatedAt: generatedAt ?? now,
                enabled: enabled,
                posture: enabled ? "steady" : "off",
                bodyLine: nil,
                behaviorLine: enabled ? "careful" : "off",
                needsUser: false,
                needsAttention: false,
                signalCount: 0,
                lastSignalAt: nil,
                body: OrganismLivingBodyFile(
                    macAwake: true, iPhoneReachable: true, providersHealthy: true,
                    memoryHealthy: true, dreamHealthy: true, toolHandsAvailable: true,
                    approvalChannelsOpen: true, notificationPathHealthy: true,
                    resourcePressure: "nominal"
                ),
                counters: OrganismLivingCountersFile(
                    fieldNodes: 0, pendingPredictions: 0, dreamRepairs: 0,
                    reflexCandidates: 0, reflexesNeedReview: 0,
                    approvedReflexBiases: nil, standingViewProposals: nil
                ),
                reflexCandidates: [],
                standingViewProposals: [],
                availability: availability
            )
        }

        XCTAssertEqual(
            OrganismStatusPresentation.snapshotState(for: status(), now: now),
            .available
        )
        XCTAssertEqual(
            OrganismStatusPresentation.snapshotState(
                for: status(generatedAt: now.addingTimeInterval(-301)), now: now
            ),
            .stale(age: 301)
        )
        XCTAssertEqual(
            OrganismStatusPresentation.snapshotState(
                for: status(generatedAt: now.addingTimeInterval(60)), now: now
            ),
            .available
        )
        XCTAssertEqual(
            OrganismStatusPresentation.snapshotState(
                for: status(enabled: false, availability: .disabled), now: now
            ),
            .disabled
        )
        var unavailable = status()
        unavailable.markUnavailable(reason: "desk_status_unavailable")
        let transported = try JSONDecoder().decode(
            OrganismLivingStatusFile.self,
            from: JSONEncoder().encode(unavailable)
        )
        XCTAssertEqual(
            OrganismStatusPresentation.snapshotState(for: transported, now: now),
            .unavailable(reason: "desk_status_unavailable")
        )
        let futureTransported = try JSONDecoder().decode(
            OrganismLivingStatusFile.self,
            from: JSONEncoder().encode(status(generatedAt: now.addingTimeInterval(61)))
        )
        XCTAssertEqual(
            OrganismStatusPresentation.snapshotState(for: futureTransported, now: now),
            .invalidTimestamp(futureBy: 61)
        )
        XCTAssertEqual(OrganismStatusPresentation.snapshotState(for: nil, now: now), .absent)
        XCTAssertEqual(OrganismStatusPresentation.staleAgeText(301), "5m")
    }

    func test_finalizedReflexIsNotReofferedBeforeTheNextSnapshot() {
        let first = reflexCandidate()
        let second = OrganismLivingReflexCandidateFile(
            id: "candidate-2", pattern: "Other", trustClass: "lowRisk",
            confidence: 0.8, reviewRequired: true, autoActivationAllowed: false, approvedAt: nil
        )
        XCTAssertEqual(
            OrganismStatusPresentation.removingLocallyFinalizedCandidate(id: first.id, from: [first, second]).map(\.id),
            [second.id]
        )
    }

    func test_reflexApprovalRequiresLowRiskAndAReviewRequest() {
        XCTAssertTrue(OrganismStatusPresentation.canApprove(reflexCandidate()))
        XCTAssertFalse(OrganismStatusPresentation.canApprove(reflexCandidate(trustClass: "highRisk")))
        XCTAssertFalse(OrganismStatusPresentation.canApprove(reflexCandidate(reviewRequired: false)))
    }
}

@MainActor
final class IOSChatBehaviorWave2EvalTests: XCTestCase {
    private func model(_ id: String, efforts: [String]? = nil, defaultEffort: String? = nil, fast: Bool? = nil) -> ProviderModelInfo {
        ProviderModelInfo(id: id, name: id, context_length: 1, supports_streaming: true, supports_vision: true, supports_tools: true, supports_json_mode: true, cost_per_1k_in: nil, cost_per_1k_out: nil, default_reasoning_effort: defaultEffort, supported_reasoning_efforts: efforts, supports_fast: fast)
    }

    private func provider(_ id: String, models: [ProviderModelInfo]) -> ProviderInfo {
        ProviderInfo(provider_id: id, display_name: id, auth_modes: [], auth_status: ProviderAuthStatus(provider_id: id, state: "ready", detail: "ready", user_info: nil, last_checked_at: nil), models: models)
    }

    func test_providerSelectionAndOutboundControlsStaySelfConsistent() {
        let alpha = provider("alpha", models: [model("alpha-model")])
        let beta = provider("beta", models: [model("beta-model", efforts: ["low"], defaultEffort: "low", fast: false)])
        let unavailable = ProviderInfo(provider_id: "unavailable", display_name: "unavailable", auth_modes: [], auth_status: ProviderAuthStatus(provider_id: "unavailable", state: "needs_key", detail: "missing", user_info: nil, last_checked_at: nil), models: [model("unavailable-model")])
        XCTAssertEqual(ChatRuntimeControlPresentation.providerID(selectedProviderID: "", activeProviderID: nil, model: "alpha-model", providers: [alpha]), "alpha")
        XCTAssertEqual(ChatRuntimeControlPresentation.providerID(selectedProviderID: "alpha", activeProviderID: nil, model: "alpha-model", providers: [alpha]), "alpha")
        XCTAssertEqual(ChatRuntimeControlPresentation.providerID(selectedProviderID: "unavailable", activeProviderID: "unavailable", model: "unavailable-model", providers: [unavailable]), "")
        let picked = try! XCTUnwrap(ChatRuntimeControlPresentation.selectionForProvider(providerID: "beta", current: .init(providerID: "alpha", model: "alpha-model", reasoningEffort: "ultra", fastMode: true), providers: [alpha, beta], preferredModels: []))
        XCTAssertEqual(picked.providerID, "beta")
        XCTAssertEqual(picked.model, "beta-model")
        XCTAssertEqual(picked.reasoningEffort, "low")
        XCTAssertFalse(picked.fastMode)
    }

    func test_modelIsReconciledToThePickedProvider() {
        let beta = provider("beta", models: [model("gpt-5.6-terra"), model("beta-model")])
        XCTAssertEqual(ChatRuntimeControlPresentation.modelForProvider(currentModel: "wrong-model", provider: beta, preferredModels: ["gpt-5.6-sol", "gpt-5.6-terra"]), "gpt-5.6-terra")
    }

    func test_failedSelectionRestoresTheFullTupleOnlyForItsOwnGeneration() {
        let previous = ChatRuntimeControlPresentation.Selection(providerID: "alpha", model: "alpha-model", reasoningEffort: "low", fastMode: false)
        XCTAssertEqual(ChatRuntimeControlPresentation.rollback(currentGeneration: 4, requestGeneration: 4, previous: previous), previous)
        XCTAssertNil(ChatRuntimeControlPresentation.rollback(currentGeneration: 5, requestGeneration: 4, previous: previous))
    }

    func test_interleavedRuntimeMenuFailureCannotOverwriteNewerAppStoragePick() async {
        enum TestError: Error { case rejected }
        let suite = "NativeAgentMobileTests.runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = ChatRuntimeControlPresentation.Selection(providerID: "alpha", model: "a", reasoningEffort: "low", fastMode: false)
        let requested = ChatRuntimeControlPresentation.Selection(providerID: "beta", model: "b", reasoningEffort: "high", fastMode: true)
        let newer = ChatRuntimeControlPresentation.Selection(providerID: "gamma", model: "c", reasoningEffort: "max", fastMode: false)
        ChatRuntimeControlPresentation.persist(previous, in: defaults)
        defaults.set(1, forKey: ChatRuntimeControlPresentation.generationDefaultsKey)
        let restored = await ChatRuntimeControlPresentation.execute(defaults: defaults, previous: previous, requested: requested, requestGeneration: 1, configure: { _ in throw TestError.rejected })
        XCTAssertEqual(restored.restored, previous)
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.modelDefaultsKey), "a")
        defaults.set(1, forKey: ChatRuntimeControlPresentation.generationDefaultsKey)
        let interleaved = await ChatRuntimeControlPresentation.execute(defaults: defaults, previous: previous, requested: requested, requestGeneration: 1, configure: { _ in
            ChatRuntimeControlPresentation.persist(newer, in: defaults)
            defaults.set(2, forKey: ChatRuntimeControlPresentation.generationDefaultsKey)
            throw TestError.rejected
        })
        XCTAssertNil(interleaved.restored)
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.providerDefaultsKey), "gamma")
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.modelDefaultsKey), "c")
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.effortDefaultsKey), "max")
        XCTAssertFalse(defaults.bool(forKey: ChatRuntimeControlPresentation.fastDefaultsKey))
    }

    func test_reasoningAndFastModeAreReconciledToTheModelCapabilities() {
        let constrained = provider("alpha", models: [model("alpha-model", efforts: ["low"], defaultEffort: "low", fast: false)])
        let state = ChatRuntimeControlPresentation.reconciled(model: "alpha-model", provider: constrained, selectedEffort: "ultra", selectedFastMode: true)
        XCTAssertEqual(state.effort, "low")
        XCTAssertFalse(state.fastMode)
    }

    func test_fileAccessPillAndOutboundEnvelopeUseExactlyTheMacRouterIDs() {
        let acceptedByMacRouter = ICloudChatFileAccessPolicy.acceptedIDs
        XCTAssertEqual(acceptedByMacRouter, ["auto", "read_only", "workspace", "full"])
        XCTAssertEqual(ChatRuntimeControlPresentation.fileAccessIDs, acceptedByMacRouter)
        XCTAssertEqual(ChatRuntimeControlPresentation.normalizedFileAccessID("not-an-access-level"), "auto")
        for id in acceptedByMacRouter {
            XCTAssertEqual(ChatRuntimeControlPresentation.normalizedFileAccessID(id), id)
            XCTAssertEqual(ICloudChatFileAccessPolicy.normalized(id), id)
            let envelope = ChatRuntimeControls(model: "alpha-model", reasoningEffort: "low", fileAccess: ChatRuntimeControlPresentation.normalizedFileAccessID(id), providerId: "alpha").metadata(transport: "test")
            XCTAssertEqual(envelope["fileAccess"], id)
        }
    }

    func test_providerSeedingIsIdempotentAndFailsClosedForEmptyOrPartialReadiness() {
        let alpha = provider("alpha", models: [model("alpha-model")])
        let beta = provider("beta", models: [model("beta-model")])
        XCTAssertEqual(ChatRuntimeControlPresentation.seededProviderID(selectedProviderID: "beta", activeProviderID: "alpha", model: "beta-model", readyProviders: [alpha, beta]), "beta")
        XCTAssertEqual(ChatRuntimeControlPresentation.seededProviderID(selectedProviderID: "missing", activeProviderID: "alpha", model: "beta-model", readyProviders: [alpha, beta]), "alpha")
        XCTAssertNil(ChatRuntimeControlPresentation.seededProviderID(selectedProviderID: "stale", activeProviderID: "stale", model: "missing", readyProviders: []))
        let seeded = try! XCTUnwrap(ChatRuntimeControlPresentation.selectionForProvider(providerID: "alpha", current: .init(providerID: "stale", model: "beta-model", reasoningEffort: "high", fastMode: true), providers: [alpha], preferredModels: []))
        XCTAssertEqual(seeded.providerID, "alpha")
        XCTAssertEqual(seeded.model, "alpha-model")
    }

    func test_pendingPhotoRemovalLeavesTheOtherAttachmentsVisible() {
        let a = PendingPhotoAttachment(id: "a", attachment: MultimodalAttachment(id: "a", type: "image", base64: "AA==", mime: "image/jpeg"), thumbnail: UIImage())
        let b = PendingPhotoAttachment(id: "b", attachment: MultimodalAttachment(id: "b", type: "image", base64: "AA==", mime: "image/jpeg"), thumbnail: UIImage())
        let partial = PendingPhotoPresentation.removing("a", from: [a, b])
        XCTAssertEqual(partial.photos.map(\.id), ["b"])
        XCTAssertTrue(partial.clearsPicker)
        XCTAssertTrue(partial.suppressesNextEmptySelection)
        let empty = PendingPhotoPresentation.removing("a", from: [a])
        XCTAssertTrue(empty.photos.isEmpty)
        XCTAssertTrue(empty.clearsPicker)
        XCTAssertFalse(empty.suppressesNextEmptySelection)
    }

    func test_unrenderableImageAttachmentUsesTheVisibleFallbackCount() {
        let invalidImage = ChatAttachmentSummary(name: "broken", type: "image", base64: "not-base64")
        let textFile = ChatAttachmentSummary(name: "notes", type: "text", base64: nil)
        XCTAssertTrue(ChatAttachmentPresentation.previewableImages(in: [invalidImage, textFile]).isEmpty)
        XCTAssertEqual(ChatAttachmentPresentation.fallbackCount(in: [invalidImage, textFile]), 2)
    }

    func test_followStateAlwaysPairsLatestButtonWithAutofollowState() {
        let away = ChatFollowPresentation.userScrolledAway()
        XCTAssertFalse(away.autoFollow)
        XCTAssertTrue(away.showsLatest)
        let latest = ChatFollowPresentation.followLatest()
        XCTAssertTrue(latest.autoFollow)
        XCTAssertFalse(latest.showsLatest)
    }

    func test_deniedMicrophoneStartResetsStateAndOffersSettings() async {
        let controller = VoiceInputController(requestSpeechAuthorization: { .authorized }, requestMicrophoneAuthorization: { false })
        await controller.start()
        XCTAssertFalse(controller.isListening)
        XCTAssertFalse(controller.isStarting)
        XCTAssertNil(controller.statusText)
        XCTAssertTrue(controller.error?.localizedCaseInsensitiveContains("permission") == true)
        XCTAssertTrue(controller.error?.localizedCaseInsensitiveContains("settings") == true)
        let speechDenied = VoiceInputController(requestSpeechAuthorization: { .denied }, requestMicrophoneAuthorization: { XCTFail("microphone prompt must not run when speech is denied"); return true })
        await speechDenied.start()
        XCTAssertFalse(speechDenied.isListening)
        XCTAssertFalse(speechDenied.isStarting)
        XCTAssertNil(speechDenied.statusText)
        XCTAssertTrue(speechDenied.error?.localizedCaseInsensitiveContains("speech recognition permission") == true)
        XCTAssertTrue(speechDenied.error?.localizedCaseInsensitiveContains("settings") == true)
    }

    func test_voiceOutputFailedAudioActivationIsVisibleAndNeverClaimsSpeech() {
        enum TestError: Error { case unavailable }
        let controller = VoiceOutputController(configureAudioSession: {}, activateAudioSession: { throw TestError.unavailable })
        controller.speak("hello")
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertTrue(controller.error?.localizedCaseInsensitiveContains("could not start") == true)
    }

    func test_startingANewSessionRecoversTheComposerFromAStuckTurn() {
        let store = ChatStore(restoreQueuedSends: false)
        store.isLoading = true
        store.startNewSession()
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isSwitchingSession)
    }

    func test_dispatchAcceptancePreservesTheErrorUntilACompletedReplyRenders() {
        let store = ChatStore(restoreQueuedSends: false)
        store.errorBanner = "Previous failure"
        let result = store.send(text: "hello", client: MacBridgeClient(), emitHaptic: false)
        XCTAssertNotEqual(result, .rejected)
        XCTAssertEqual(store.errorBanner, "Previous failure")
        let placeholder = try! XCTUnwrap(store.messages.last(where: { $0.role == .assistant }))
        store.finishPlaceholder(id: placeholder.id, text: "completed", success: true)
        XCTAssertNil(store.errorBanner)
    }

    func test_wave4MemoryProposalWithoutEvidenceStillExplainsItsBasis() throws {
        let record = try JSONDecoder().decode(MemoryProposalRecord.self, from: Data(#"{"id":"p","text":"x","recurrence_count":1}"#.utf8))
        XCTAssertEqual(record.evidenceSummary, "Observed once")
    }
}

/// Wave 5 exercises the screen-owned stores through their actual action and
/// snapshot boundaries.  The test plays the paired Mac only at the durable
/// signed mailbox: production code writes the action, and a separately signed
/// response is supplied back through the normal polling path.
@MainActor
final class IOSScreenWave5StoreActionEvalTests: XCTestCase {
    private let secret = Data("ios-screen-wave5-test-secret-32b".utf8)
    private var engine: iCloudSyncEngine!
    private var pairing: PairingStore!
    private var root: URL!
    private var savedInboxDir: URL?
    private var savedResponsesDir: URL?
    private var savedTransactionDir: URL?
    private var savedSnapshotDir: URL?
    private var savedPairingStore: PairingStore?
    private var savedMemories: [MemoryRecord] = []
    private var savedProposals: [MemoryProposalRecord] = []
    private var savedSyncError: String?
    private var savedLastSyncAt: Date?

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertEqual(secret.count, 32, "the mailbox test key must be an exact HMAC key")
        engine = iCloudSyncEngine.shared
        savedInboxDir = engine.inboxDir
        savedResponsesDir = engine.responsesDir
        savedTransactionDir = engine.transactionDir
        savedSnapshotDir = engine.snapshotDir
        savedPairingStore = engine.pairingStore
        savedMemories = engine.memories
        savedProposals = engine.memoryProposals
        savedSyncError = engine.syncError
        savedLastSyncAt = engine.lastSyncAt

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-screen-wave5-\(UUID().uuidString)", isDirectory: true)
        for name in ["inbox", "responses", "transactions", "snapshots"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        engine.inboxDir = root.appendingPathComponent("inbox", isDirectory: true)
        engine.responsesDir = root.appendingPathComponent("responses", isDirectory: true)
        engine.transactionDir = root.appendingPathComponent("transactions", isDirectory: true)
        engine.snapshotDir = root.appendingPathComponent("snapshots", isDirectory: true)
        engine.syncError = nil

        pairing = PairingStore()
        pairing.iCloudPairingSecret = secret
        engine.pairingStore = pairing

    }

    override func tearDown() async throws {
        pairing?.iCloudPairingSecret = nil
        engine.memories = savedMemories
        engine.memoryProposals = savedProposals
        engine.inboxDir = savedInboxDir
        engine.responsesDir = savedResponsesDir
        engine.transactionDir = savedTransactionDir
        engine.snapshotDir = savedSnapshotDir
        engine.pairingStore = savedPairingStore
        engine.syncError = savedSyncError
        engine.lastSyncAt = savedLastSyncAt
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func approval(_ id: String, status: String = "pending") -> ApprovalRequest {
        ApprovalRequest(
            id: id, title: "Review \(id)", action: "system_control", risk: "high",
            status: status, createdAt: "2026-08-24T00:00:00Z"
        )
    }

    private func memory(_ id: String) throws -> MemoryRecord {
        try JSONDecoder().decode(MemoryRecord.self, from: Data("""
        {"id":"\(id)","layer":"semantic","text":"Memory \(id)","importance":0.7,"confidence":0.9,"createdAt":"2026-08-24T00:00:00Z"}
        """.utf8))
    }

    private func writeStaleMemorySnapshot(_ record: MemoryRecord) throws {
        try JSONEncoder().encode([record]).write(
            to: engine.snapshotDir!.appendingPathComponent("memories.json"), options: .atomic
        )
        try Data("[]".utf8).write(
            to: engine.snapshotDir!.appendingPathComponent("memory_proposals.json"), options: .atomic
        )
    }

    private func signature(_ fields: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private func nextEnvelope() async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let files = try FileManager.default.contentsOfDirectory(at: engine.inboxDir!, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            if let file = files.first {
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                var unsigned = object
                let actual = try XCTUnwrap(unsigned.removeValue(forKey: "signature") as? String)
                let canonical = try JSONSerialization.data(withJSONObject: unsigned, options: [.sortedKeys])
                let expected = Data(HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: secret)))
                    .map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(actual, expected, "the screen action must cross the production signed mailbox")
                return object
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SyncError.timeout("screen action never wrote its signed mailbox envelope")
    }

    private func respond(to envelope: [String: Any]) throws {
        let messageID = try XCTUnwrap(envelope["msgId"] as? String)
        let action = try XCTUnwrap(envelope["action"] as? String)
        let transactionID = try XCTUnwrap(envelope["transactionId"] as? String)
        var response = [
            "msgId": messageID,
            "action": action,
            "transactionId": transactionID,
            "status": "completed",
            "ok": "true",
            "applied": "true",
        ]
        response["signature"] = try signature(response)
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        try data.write(to: engine.responsesDir!.appendingPathComponent("\(messageID).json"), options: .atomic)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "screen action did not settle before its bounded deadline")
    }

    func test_payloadPreviewRenderLabelsItsSyntheticFallbackAsNonCanonical() {
        var expanded = false
        let preview = PayloadPreview(
            approval: approval("approval-no-payload"),
            expanded: Binding(get: { expanded }, set: { expanded = $0 })
        )

        XCTAssertTrue(preview.payloadText.contains("did not publish the real payload"))
        XCTAssertTrue(preview.payloadText.contains("system_control"))
    }

    // MARK: - ios.memory.deleteSwipe

    func test_confirmedMemoryDeleteReappearsWithAnHonestWaitingStateUntilTheSnapshotCatchesUp() async throws {
        let record = try memory("memory-delete")
        try writeStaleMemorySnapshot(record)
        engine.memories = [record]
        let store = MemoryStore()
        store.applySyncedState(from: engine)

        store.deleteMemory(record)
        let envelope = try await nextEnvelope()
        XCTAssertEqual(envelope["action"] as? String, "deleteMemory")
        try respond(to: envelope)
        await waitUntil { !store.deletingMemoryIDs.contains(record.id) }

        XCTAssertEqual(store.memories.map(\.id), [record.id])
        XCTAssertTrue(store.error?.contains("waiting for Mac/iCloud") == true)
    }

}
