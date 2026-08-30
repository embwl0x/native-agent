import Foundation
import XCTest
import NativeAgentShared
import NativeAgentSharedTestSupport
@testable import NativeAgentMobile

@MainActor
private final class CloudKitContinuityRecorder {
    private(set) var messageIDs: [String] = []

    func append(_ message: BridgeMessage) {
        messageIDs.append(message.id)
    }
}

final class UIIntegrityContractTests: XCTestCase {
    func testMoreMenuContainsOnlyImplementedDestinations() throws {
        let sources = try Self.sourcesRoot()
        for retired in ["MCPHubView.swift", "CapabilitiesView.swift", "CommandCenterView.swift", "OnboardingWizard.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sources.appendingPathComponent(retired).path))
        }

        let advanced = try Self.source("AdvancedView.swift")
        XCTAssertFalse(advanced.contains("MCPHubView()"))
        XCTAssertFalse(advanced.contains("CapabilitiesView()"))
        XCTAssertFalse(advanced.contains("CommandCenterView()"))
        XCTAssertFalse(advanced.contains("DoctorView("))
    }

    func testVisibleSkillAndProviderControlsHaveRealOwners() throws {
        let skills = try Self.source("SkillLifecycleView.swift")
        XCTAssertFalse(skills.contains("skill_action"))
        XCTAssertFalse(skills.contains("func install("))
        XCTAssertFalse(skills.contains("func activate("))
        XCTAssertTrue(skills.contains("Lifecycle changes remain on the Mac"))

        let providers = try Self.source("ProviderSettingsView.swift")
        XCTAssertFalse(providers.contains("cognition_cue"))
        XCTAssertFalse(providers.contains(".disabled(true)"))
        XCTAssertFalse(providers.contains("connect_oauth"))
        XCTAssertTrue(providers.contains("configureSurfaceSelection("))
    }

    func testPairingSecretIsNotRenderedAndMacPermissionsUseSignedAuthority() throws {
        let advanced = try Self.source("AdvancedView.swift")
        let settings = try Self.source("SettingsViewFull.swift")
        let app = try Self.source("NativeAgentMobileApp.swift")
        XCTAssertFalse(advanced.contains("base64EncodedString"))
        XCTAssertFalse(settings.contains("base64EncodedString"))
        XCTAssertTrue(settings.contains("Replace the current pairing?"))
        XCTAssertTrue(
            app.contains(
                """
                iCloudSyncEngine.shared.pairingStore = pairingStore
                                        iCloudBridge.shared.pairingStore = pairingStore
                """
            ),
            "Fresh-install pairing must bind the authoritative PairingStore to both CloudKit consumers before PairingView starts its drain."
        )

        let projection = try Self.source("MacIntegrationPermissionsSync.swift")
        XCTAssertFalse(projection.contains("kvs.set("))
        XCTAssertFalse(projection.contains("func set(id:"))
        XCTAssertTrue(projection.contains("func applyProjection("))

        let actions = try Self.source("iCloudSyncEngine+Actions.swift")
        XCTAssertTrue(actions.contains("set_mac_integration_permission"))
        XCTAssertTrue(actions.contains("requireSuccessfulActionResponse"))
    }

    func testPublicPairingCopyContainsNoTemplatePlaceholder() throws {
        let pairing = try Self.source("PairingView.swift")
        let bridge = try Self.source("iCloudBridge.swift")

        XCTAssertFalse(pairing.contains("[Your Name]"))
        XCTAssertFalse(bridge.contains("[Your Name]"))
        XCTAssertTrue(pairing.contains("does not scan a QR code yet"))
        XCTAssertTrue(pairing.contains("copy the pairing key"))
        XCTAssertTrue(pairing.contains("Settings -> Apple Account"))
        XCTAssertTrue(bridge.contains("Settings → Apple Account"))
    }

    func testAppearanceIsOwnedAtTheAppRootAndExposedInSettings() throws {
        let design = try Self.source("NativeAgentDesign.swift")
        let app = try Self.source("NativeAgentMobileApp.swift")
        let settings = try Self.source("SettingsViewFull.swift")

        XCTAssertTrue(design.contains("enum NativeAgentAppearance"))
        XCTAssertTrue(design.contains("case system"))
        XCTAssertTrue(design.contains("case light"))
        XCTAssertTrue(design.contains("case dark"))
        XCTAssertTrue(app.contains(".preferredColorScheme(NativeAgentAppearance.resolved(appearanceRawValue).colorScheme)"))
        XCTAssertTrue(settings.contains("@AppStorage(NativeAgentAppearance.storageKey)"))
        XCTAssertTrue(settings.contains("Picker(\"Color scheme\""))
    }

    func testSharedDecorativeMotionHonorsReduceMotion() throws {
        let design = try Self.source("NativeAgentDesign.swift")
        let theme = try Self.source("NativeAgentTheme.swift")

        XCTAssertGreaterThanOrEqual(
            design.components(separatedBy: "@Environment(\\.accessibilityReduceMotion)").count - 1,
            4
        )
        XCTAssertTrue(theme.contains("@Environment(\\.accessibilityReduceMotion)"))
    }

    func testDeskIsPrimaryAndSkillsAndToolsShareOneMoreDestination() throws {
        let content = try Self.source("ContentView.swift")
        let advanced = try Self.source("AdvancedView.swift")
        let combined = try Self.source("SkillsToolsView.swift")
        let toolSnapshot = try Self.source("iCloudSyncEngine+Snapshots.swift")

        XCTAssertTrue(content.contains("MobileDeskView()"))
        XCTAssertTrue(content.contains("Label(\"Desk\", systemImage: \"rectangle.3.group\")"))
        XCTAssertFalse(content.contains("Label(\"Skills\", systemImage:"))
        XCTAssertTrue(advanced.contains("SkillsToolsView(embedInNavigationStack: false)"))
        XCTAssertTrue(advanced.contains("Label(\"Skills & Tools\", systemImage: \"puzzlepiece.extension\")"))
        XCTAssertFalse(content.contains("SkillLifecycleView()\n                .tabItem"))
        XCTAssertTrue(combined.contains("case skills = \"Skills\""))
        XCTAssertTrue(combined.contains("case tools = \"Tools\""))
        XCTAssertTrue(combined.contains("tools_snapshot.json"))
        XCTAssertTrue(toolSnapshot.contains("loadSnapshotArrayAsync"))
    }

    @MainActor
    func testPublicCloudKitContinuityDoesNotFallBackToDrivePolling() async throws {
        let suite = "NativeAgentMobileTests.publicCloudKitContinuity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let secret = Data(repeating: 0xC7, count: 32)
        let pairing = PairingStore()
        pairing.iCloudPairingSecret = secret
        defer { pairing.iCloudPairingSecret = nil }
        let cloud = MockDeviceCloud()
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        // No Ubiquity Documents mount is available in this fixture. Delivery
        // succeeding therefore proves the current client catch-up drains the
        // active CloudKit transport rather than polling a Drive outbox.
        let bridge = iCloudBridge(
            deviceTransport: iosTransport,
            pairingStore: pairing,
            userDefaults: defaults,
            ubiquityContainerURL: { _ in nil }
        )
        let client = MacBridgeClient(bridge: bridge)
        client.configureICloud()
        let recorder = CloudKitContinuityRecorder()
        let observer = client.observeICloudReplies { recorder.append($0) }
        defer { client.removeICloudReplyObserver(observer) }
        XCTAssertTrue(bridge.usesCloudKitDeviceTransport)

        let message = try BridgeMessage.make(
            sender: "mac",
            text: "CloudKit continuity reply",
            metadata: ["kind": "final"]
        ).signed(with: secret)
        try await macTransport.send(message)
        await client.pollICloudRepliesNow()

        XCTAssertEqual(recorder.messageIDs, [message.id])
    }

    func testVisualNotificationReadinessRequiresSuccessfulRegistration() throws {
        let bridge = try Self.source("iCloudBridge.swift")

        XCTAssertTrue(bridge.contains("let ready = await transport.ensurePushSubscriptions()"))
        XCTAssertTrue(bridge.contains("ready: ready && transport.presentsVisualNotifications"))
        XCTAssertFalse(bridge.contains("if !transport.presentsVisualNotifications"))
    }

    func testEveryFullScreenCoverHostsTheSharedToastBar() throws {
        let sources = try Self.sourcesRoot()
        let fileManager = FileManager.default
        let sourceFiles = try fileManager.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var coverCount = 0

        for file in sourceFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            var searchRange = source.startIndex..<source.endIndex
            while let coverRange = source.range(of: ".fullScreenCover", range: searchRange) {
                coverCount += 1
                guard let body = Self.closureBody(startingAt: coverRange.lowerBound, in: source) else {
                    XCTFail("\(file.lastPathComponent) has an unbalanced full-screen cover closure.")
                    break
                }
                XCTAssertTrue(
                    body.contains("iOSSystemToastBar(center: iOSSystemToastCenter.shared)"),
                    "\(file.lastPathComponent) presents a full-screen cover above ContentView's toast host without re-hosting the shared toast bar."
                )
                searchRange = coverRange.upperBound..<source.endIndex
            }
        }

        XCTAssertGreaterThan(coverCount, 0, "The eval must exercise at least one full-screen presentation path.")
    }

    func testSelfImprovementBadgePathMakesMacOnlyAuthorityExplicit() throws {
        let activity = try Self.source("ActivityView.swift")
        let autonomy = try Self.source("AutonomyView.swift")
        let inlineCard = try Self.body(of: "InlineSelfImprovementPreviewCard", keyword: "private struct", in: activity)

        XCTAssertTrue(activity.contains("count: pendingSelfImprovementCount"))
        XCTAssertTrue(inlineCard.contains("Apply changes on the Mac"))
        XCTAssertTrue(inlineCard.contains("onView()"))
        XCTAssertTrue(
            autonomy.contains("Applying training changes and approving learned behavior remain local-admin actions on the Mac."),
            "The self-improvement drill-down must state that the badge cannot be resolved on iOS."
        )
    }

    func testApprovalWarningIsReservedForAnUnpublishedDecision() throws {
        XCTAssertNil(ApprovalBannerPresentation.warning(hasPendingLocalDecision: false))
        XCTAssertEqual(
            ApprovalBannerPresentation.warning(hasPendingLocalDecision: true),
            ApprovalBannerPresentation.pendingDecisionMessage
        )

        let approvals = try Self.source("ApprovalsView.swift")
        let applySnapshot = try Self.body(of: "applySyncedApprovalsFromSnapshot", keyword: "func", in: approvals)
        XCTAssertTrue(applySnapshot.contains("ApprovalBannerPresentation.warning("))
        XCTAssertTrue(applySnapshot.contains("!locallyFinalizedApprovals.isEmpty"))
        XCTAssertFalse(applySnapshot.contains("Approvals are syncing through iCloud"))
    }

    func testApprovalNotificationsIgnoreColdAndVisibleSnapshotsThenCollapseBursts() throws {
        let firstLoad = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: false,
            isVisible: false,
            pendingIDs: ["first"],
            notifiedIDs: []
        )
        XCTAssertEqual(firstLoad, .none)

        let hiddenNewItems = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: true,
            isVisible: false,
            pendingIDs: ["already-notified", "new-a", "new-b", "new-a"],
            notifiedIDs: ["already-notified"]
        )
        XCTAssertEqual(hiddenNewItems.individualApprovalIDs, ["new-a", "new-b"])
        XCTAssertNil(hiddenNewItems.summaryCount)

        let repeatedSnapshot = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: true,
            isVisible: false,
            pendingIDs: ["already-notified", "new-a", "new-b"],
            notifiedIDs: ["already-notified", "new-a", "new-b"]
        )
        XCTAssertEqual(repeatedSnapshot, .none)

        let visibleNewItem = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: true,
            isVisible: true,
            pendingIDs: ["new-c"],
            notifiedIDs: []
        )
        XCTAssertEqual(visibleNewItem, .none)

        let burst = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: true,
            isVisible: false,
            pendingIDs: ["one", "two", "three", "four"],
            notifiedIDs: []
        )
        XCTAssertTrue(burst.individualApprovalIDs.isEmpty)
        XCTAssertEqual(burst.summaryCount, 4)

        let approvals = try Self.source("ApprovalsView.swift")
        let notifier = try Self.body(of: "notifyForNewPendingApprovals", keyword: "func", in: approvals)
        XCTAssertTrue(notifier.contains("ApprovalPendingNotificationPresentation.plan("))
        XCTAssertTrue(notifier.contains("plan.individualApprovalIDs"))
        XCTAssertTrue(notifier.contains("plan.summaryCount"))
    }

    func testProviderRollbackRestoresOnlyTheRequestThatFailed() throws {
        let initial = ProviderSelectionRollbackPresentation.Selection(
            providerID: "alpha",
            modelID: "alpha-model"
        )
        let newer = ProviderSelectionRollbackPresentation.Selection(
            providerID: "gamma",
            modelID: "gamma-model"
        )

        XCTAssertEqual(
            ProviderSelectionRollbackPresentation.rollback(
                currentGeneration: 1,
                requestGeneration: 1,
                previous: initial
            ),
            initial
        )
        XCTAssertNil(
            ProviderSelectionRollbackPresentation.rollback(
                currentGeneration: 2,
                requestGeneration: 1,
                previous: initial
            )
        )

        var displayed = newer
        if let staleRestore = ProviderSelectionRollbackPresentation.rollback(
            currentGeneration: 2,
            requestGeneration: 1,
            previous: initial
        ) {
            displayed = staleRestore
        }
        XCTAssertEqual(displayed, newer, "A late pick-A failure must not overwrite a newer pick-B tuple.")

        let providers = try Self.source("ProviderSettingsView.swift")
        let sender = try Self.body(of: "sendSelection", keyword: "private func", in: providers)
        XCTAssertTrue(sender.contains("ProviderSelectionRollbackPresentation.rollback("))
        XCTAssertTrue(sender.contains("requestedModel[surface] = restored.modelID"))
        XCTAssertTrue(sender.contains("ProviderSelectionRollbackPresentation.acceptReceipt("))
        XCTAssertTrue(sender.contains("currentGeneration: selectionGeneration[surface] ?? 0"))
    }

    func testWaitingRemoteActionsExplicitlyIdentifyTheirLocalOnlyApprovalState() throws {
        let tools = try Self.source("MacToolsView.swift")
        let card = try Self.body(of: "RemoteActionCardView", keyword: "private struct", in: tools)
        XCTAssertTrue(card.contains("action.state == .waitingApproval"))
        XCTAssertTrue(card.contains("Approval status is local to this session; review it in Activity."))
        XCTAssertTrue(card.contains("Review Approval"))
    }

    func testKnowledgeGraphEntityCountHeaderAlwaysMatchesVisibleRows() throws {
        XCTAssertEqual(KnowledgeGraphPresentation.entityCountHeader(visibleCount: 1), "1 entity")
        XCTAssertEqual(KnowledgeGraphPresentation.entityCountHeader(visibleCount: 40), "40 entities")
        XCTAssertEqual(
            KnowledgeGraphPresentation.filterContext(visibleCount: 1, totalCount: 900, isFiltered: true),
            "Showing 1 of 900 published entities."
        )
        XCTAssertNil(KnowledgeGraphPresentation.filterContext(visibleCount: 900, totalCount: 900, isFiltered: true))

        let graph = try Self.source("KnowledgeGraphView.swift")
        XCTAssertTrue(graph.contains("entityCountHeader(visibleCount: displayEntities.count)"))
        XCTAssertTrue(graph.contains("filterContext("))
        XCTAssertFalse(graph.contains("Section(searchText.isEmpty ?"))
    }

    func testMorePowerUserRowsRouteToDataBackedDestinations() throws {
        let advanced = try Self.source("AdvancedView.swift")
        let graph = try Self.source("KnowledgeGraphView.swift")
        let inspector = try Self.source("TurnInspectorView.swift")
        let tools = try Self.source("MacToolsView.swift")

        XCTAssertTrue(advanced.contains("ForEach(MorePowerUserDestination.allCases)"))
        XCTAssertTrue(advanced.contains("case .knowledgeGraph:\n            KnowledgeGraphView()"))
        XCTAssertTrue(advanced.contains("case .turnInspector:\n            TurnInspectorView()"))
        XCTAssertTrue(advanced.contains("case .macTools:\n            MacToolsView()"))
        XCTAssertTrue(advanced.contains("Mac-published iCloud snapshot"))
        XCTAssertTrue(advanced.contains("Synced turn summaries"))
        XCTAssertTrue(advanced.contains("Paired-Mac policy and actions"))

        XCTAssertTrue(graph.contains("@StateObject private var store = KGStore()"))
        XCTAssertTrue(graph.contains(".task { await store.refresh(client: bridgeClient) }"))
        XCTAssertTrue(inspector.contains("@StateObject private var store = TurnInspectorStore()"))
        XCTAssertTrue(inspector.contains(".onAppear { Task { await store.refresh() } }"))
        XCTAssertTrue(tools.contains(".task { await refresh() }"))
        XCTAssertTrue(tools.contains("await iCloudSyncEngine.shared.refreshTrustSnapshot()"))
    }

    func testAppEmptyStatesDeclareWhetherDataIsEmptyOrUnavailable() throws {
        XCTAssertEqual(AppEmptyStateKind.empty.statusLabel, "No current items")
        XCTAssertEqual(AppEmptyStateKind.unavailable.statusLabel, "Data unavailable")
        XCTAssertEqual(
            MobileDeskEmptyStatePresentation.state(
                hasAttemptedLoad: false,
                isRefreshing: false,
                loadError: nil
            ),
            .loading
        )
        XCTAssertEqual(
            MobileDeskEmptyStatePresentation.state(
                hasAttemptedLoad: true,
                isRefreshing: false,
                loadError: "Desk snapshot missing"
            ),
            .unavailable("Desk snapshot missing")
        )
        XCTAssertEqual(
            MobileDeskEmptyStatePresentation.state(
                hasAttemptedLoad: true,
                isRefreshing: false,
                loadError: "  "
            ),
            .empty
        )

        let design = try Self.source("NativeAgentDesign.swift")
        XCTAssertTrue(design.contains("let kind: AppEmptyStateKind"))
        XCTAssertTrue(design.contains(".accessibilityLabel(\"\\(kind.statusLabel): \\(title)\")"))

        let sources = try Self.sourcesRoot()
        let files = try FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var callCount = 0

        for file in files where file.lastPathComponent != "NativeAgentDesign.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            var searchRange = source.startIndex..<source.endIndex
            while let call = source.range(of: "AppEmptyState(", range: searchRange) {
                callCount += 1
                guard let arguments = Self.parenthesizedArguments(startingAt: call.lowerBound, in: source) else {
                    return XCTFail("\(file.lastPathComponent) has an unbalanced AppEmptyState call.")
                }
                XCTAssertTrue(
                    arguments.contains("kind: .empty") || arguments.contains("kind: .unavailable"),
                    "\(file.lastPathComponent) renders an AppEmptyState without declaring empty vs unavailable data."
                )
                searchRange = call.upperBound..<source.endIndex
            }
        }

        XCTAssertGreaterThan(callCount, 0, "The eval must audit live AppEmptyState call sites.")
    }

    func testSnapshotGroupsDriveVisibleStoresWithoutCloudPolling() throws {
        let setup = try Self.source("iCloudSyncEngine+Setup.swift")
        let content = try Self.source("ContentView.swift")
        let desk = try Self.source("DeskView.swift")
        let memory = try Self.source("MemoryView.swift")
        let advanced = try Self.source("AdvancedView.swift")
        let inspector = try Self.source("TurnInspectorView.swift")

        XCTAssertTrue(setup.contains("func refreshSnapshotGroup("))
        XCTAssertTrue(setup.contains("await refreshActivitySnapshot()"))
        XCTAssertTrue(setup.contains("await refreshCatalogSnapshot()"))
        XCTAssertTrue(content.contains("while !Task.isCancelled, !pairingStore.usesICloudTransport"))
        XCTAssertTrue(desk.contains("await sync.refreshDeskSnapshot()"))
        XCTAssertTrue(desk.contains("iCloudSyncEngine.shared.setDeskItemStatus"))
        XCTAssertTrue(memory.contains(".onChange(of: sync.memories)"))
        XCTAssertTrue(advanced.contains(".onChange(of: sync.runs)"))
        XCTAssertTrue(inspector.contains(".onChange(of: sync.turnSummaries)"))
    }

    // MARK: - ios.sync fence evals (2026-08-23, coverage ledger wave A)
    //
    // Three structural invariants of the iOS bridge that no runtime test can
    // reach (the bridge is a singleton with private state) and that fail
    // silently when broken:
    //   * a field added to the bridge and NOT reset in tearDown() survives a
    //     re-pair, so the new pairing runs against the old device's state;
    //   * draining on the per-token progress key queues a drain storm that
    //     accumulates across a conversation and stalls later messages (CK-5);
    //   * eviction that is not insertion-ordered can forget a RECENT message
    //     id and replay a Mac reply into the transcript as a new message.
    //
    // Ledger rows: ios.bridge.tearDown, ios.bridge.kvsDidChange,
    // ios.bridge.processedMacReplyIDs, ios.bridge.kvsChatProgressChannel,
    // ios.macBridgeClient.retiredHTTPSurface.

    /// Every resettable field the bridge owns must be cleared by tearDown().
    /// The allow-list below names the ONLY fields that are deliberately
    /// durable across a re-pair; anything new must be reset or explicitly
    /// added here, which is the point — a silent addition fails this test.
    func testEveryResettableBridgeFieldIsClearedOnTearDown() throws {
        let file = try Self.source("iCloudBridge.swift")
        // Scope to the bridge CLASS body — the file also holds small private
        // helper types whose state is not part of the pairing lifecycle.
        let bridge = try Self.body(of: "final class iCloudBridge", in: file)
        let tearDown = try Self.body(of: "func tearDown()", in: bridge)

        // Deliberately durable: the seen-id ledgers (their whole job is to
        // survive), their ordered twins, the generation counter (monotonic),
        // and the injected pairing store (owned by the app, not the bridge).
        let intentionallyDurable: Set<String> = [
            "seenMessageIDs",
            "seenMessageIDsOrdered",
            "seenKVSProgressMessageIDs",
            "seenKVSProgressMessageIDsOrdered",
            "setupGeneration",
            "pairingStore",
            "lastSyncAt",
        ]

        var unreset: [String] = []
        for name in Self.mutableStoredProperties(in: bridge) where !intentionallyDurable.contains(name) {
            let assigned = tearDown.contains("\(name) =")
                || tearDown.contains("\(name)?.cancel()")
                || tearDown.contains("\(name)?.stop()")
                || tearDown.contains("self.\(name) =")
            if !assigned { unreset.append(name) }
        }
        XCTAssertTrue(
            unreset.isEmpty,
            "these bridge fields survive tearDown() and will leak into the next pairing: \(unreset)"
        )

        // The two that historically caused a permanently-stopped bridge and a
        // stale transport are pinned by name.
        XCTAssertTrue(tearDown.contains("isSetUp = false"),
                      "tearDown must clear isSetUp or setup() returns early forever")
        XCTAssertTrue(tearDown.contains("deviceTransport = nil"),
                      "tearDown must drop the transport so setup() re-resolves it")
    }

    /// CK-5: the per-token progress key must dispatch progress ONLY. Draining
    /// on it queued a drain per streamed token, which accumulated across the
    /// conversation and stalled later messages. The once-per-message nudge is
    /// the only key that may drain.
    func testProgressKeyDispatchesProgressAndNeverQueuesADrain() throws {
        let bridge = try Self.source("iCloudBridge.swift")
        let handler = try Self.body(of: "func kvsDidChange(", in: bridge)

        XCTAssertTrue(handler.contains("KVSKey.chatProgressLatest"))
        XCTAssertTrue(handler.contains("KVSKey.newMessageInDrive"))
        XCTAssertTrue(handler.contains("if progressChanged {"))

        // Isolate the progressChanged branch and prove no drain call lives in it.
        guard let start = handler.range(of: "if progressChanged {"),
              let end = handler.range(of: "if driveChanged {", range: start.upperBound..<handler.endIndex) else {
            return XCTFail("kvsDidChange no longer has the progress/drive branch shape this guard depends on")
        }
        let progressBranch = String(handler[start.upperBound..<end.lowerBound])
        XCTAssertTrue(progressBranch.contains("dispatchLatestKVSChatProgress()"))
        for drain in ["drainDeviceTransport", "checkMacOutbox", "pollIncomingNow", "refreshSnapshotGroup"] {
            XCTAssertFalse(
                progressBranch.contains(drain),
                "\(drain) runs on every streamed token — this is the CK-5 drain storm"
            )
        }
        // …and the drive nudge is where the drain belongs.
        let driveBranch = String(handler[end.upperBound...])
        XCTAssertTrue(driveBranch.contains("drainDeviceTransport"))
    }

    /// Both seen-id ledgers must evict OLDEST-FIRST from an insertion-ordered
    /// array. `Array(set.suffix(cap))` / `sorted().suffix(cap)` keep an
    /// arbitrary subset (opaque ids sort unrelated to arrival), so a recent id
    /// can be forgotten and its message replayed as new.
    func testSeenIDLedgersEvictOldestFirstFromInsertionOrder() throws {
        let bridge = try Self.source("iCloudBridge.swift")

        for (recorder, ordered, set) in [
            ("func recordSeenMacReplyID(", "seenMessageIDsOrdered", "seenMessageIDs"),
            ("func recordSeenKVSProgressMessageID(", "seenKVSProgressMessageIDsOrdered", "seenKVSProgressMessageIDs"),
        ] {
            let body = try Self.body(of: recorder, in: bridge)
            XCTAssertTrue(body.contains("\(ordered).append(id)"),
                          "\(recorder) must append in arrival order")
            XCTAssertTrue(body.contains("\(ordered).removeFirst()"),
                          "\(recorder) must evict the OLDEST id, not an arbitrary one")
            XCTAssertTrue(body.contains("\(set).remove("),
                          "\(recorder) must keep the set and the ordered array in step")
            XCTAssertFalse(body.contains("sorted()"),
                           "sorting opaque message ids is unrelated to arrival order")
        }

        // Persistence must carry the same order to disk, or the eviction
        // guarantee is lost across a relaunch.
        let persist = try Self.body(of: "func persistSeenMacReplyIDs()", in: bridge)
        XCTAssertTrue(persist.contains("seenMessageIDsOrdered.suffix(maxProcessedMacReplyIDs)"))
        XCTAssertFalse(persist.contains("seenMessageIDs.suffix"),
                       "persisting Array(set.suffix(cap)) keeps an arbitrary subset")
    }

    /// ios.macBridgeClient.retiredHTTPSurface — a dead route BY DESIGN. The
    /// verdict is pinned here so it stays dated: if a view ever calls `get`
    /// or `postDict` again it silently receives a throw that `try?` swallows
    /// into an empty screen.
    func testTheRetiredHTTPSurfaceHasNoCallersAndFailsLoudlyIfUsed() throws {
        let client = try Self.source("MacBridgeClient.swift")
        XCTAssertTrue(client.contains("throw Self.transportRemoved"))
        XCTAssertTrue(client.contains("Direct HTTP transport removed"))
        // No live URLSession on the iOS transport path (the header comment
        // still names it as the thing that was removed, so match a CALL).
        XCTAssertFalse(client.contains("URLSession.shared"))
        XCTAssertFalse(client.contains("URLSession("))
        XCTAssertFalse(client.contains("URLRequest("))

        var callers: [String] = []
        let sources = try Self.sourcesRoot()
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        for case let url as URL in walker! where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(".postDict(") || trimmed.contains("bridge.get(") else { continue }
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if url.lastPathComponent == "MacBridgeClient.swift" { continue }
                callers.append("\(url.lastPathComponent): \(trimmed)")
            }
        }
        XCTAssertTrue(
            callers.isEmpty,
            "the retired HTTP surface has callers again; they degrade to empty screens: \(callers)"
        )
    }

    /// Extract a brace-balanced function body by header prefix.
    private static func body(of header: String, in text: String) throws -> String {
        guard let headerRange = text.range(of: header),
              let open = text.range(of: "{", range: headerRange.upperBound..<text.endIndex) else {
            throw NSError(
                domain: "UIIntegrityContractTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "could not find \(header)"]
            )
        }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[open.upperBound..<index])
                }
            }
            index = text.index(after: index)
        }
        throw NSError(
            domain: "UIIntegrityContractTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "unbalanced braces after \(header)"]
        )
    }

    /// Names of `private var` / `var` stored properties declared at class
    /// scope (four-space indentation), excluding computed ones.
    private static func mutableStoredProperties(in text: String) -> [String] {
        var names: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("    ") , !line.hasPrefix("     ") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "var ") else { continue }
            guard trimmed.hasPrefix("var ")
                || trimmed.hasPrefix("private var ")
                || trimmed.hasPrefix("@Published var ")
                || trimmed.hasPrefix("weak var ")
                || trimmed.hasPrefix("private weak var ") else { continue }
            let rest = trimmed[range.upperBound...]
            guard let stop = rest.firstIndex(where: { $0 == ":" || $0 == " " || $0 == "=" }) else { continue }
            let name = String(rest[..<stop])
            guard !name.isEmpty else { continue }
            // Computed properties open a brace on the same or next line with
            // no assignment — skip those; they hold no state to reset.
            let declaration = trimmed
            // Computed properties carry a `{ … }` body and no initial value.
            // Stored properties with an observer keep `= value` before the
            // brace (`var x: T = v { didSet … }`). Only the text BEFORE the
            // first brace counts — a computed body such as
            // `{ deviceTransport != nil }` contains `=` inside `!=`.
            let beforeBrace = declaration.split(separator: "{", maxSplits: 1).first.map(String.init) ?? declaration
            let opensBlock = declaration.contains("{")
                || (index + 1 < lines.count && lines[index + 1].trimmingCharacters(in: .whitespaces) == "{")
            let hasInitialValue = beforeBrace.contains(" = ")
            if opensBlock && !hasInitialValue { continue }
            names.append(name)
        }
        return names
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: sourcesRoot().appendingPathComponent(name), encoding: .utf8)
    }

    private static func sourcesRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let sources = directory.appendingPathComponent("Sources", isDirectory: true)
            let project = directory.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: sources.path),
               FileManager.default.fileExists(atPath: project.path) {
                return sources
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw NSError(
            domain: "UIIntegrityContractTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate NativeAgentMobile/Sources from \(#filePath)"]
        )
    }

    private static func closureBody(startingAt start: String.Index, in source: String) -> String? {
        guard let openingBrace = source[start...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var body = ""
        for character in source[openingBrace...] {
            if character == "{" {
                depth += 1
                if depth == 1 { continue }
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            if depth >= 1 { body.append(character) }
        }
        return nil
    }

    private static func parenthesizedArguments(startingAt start: String.Index, in source: String) -> String? {
        guard let openingParenthesis = source[start...].firstIndex(of: "(") else { return nil }

        var depth = 0
        var arguments = ""
        for character in source[openingParenthesis...] {
            if character == "(" {
                depth += 1
                if depth == 1 { continue }
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return arguments }
            }
            if depth >= 1 { arguments.append(character) }
        }
        return nil
    }

    private static func body(of name: String, keyword: String, in source: String) throws -> String {
        guard let declaration = source.range(of: "\(keyword) \(name)"),
              let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{") else {
            throw NSError(
                domain: "UIIntegrityContractTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find \(keyword) \(name)"]
            )
        }
        guard let body = closureBody(startingAt: openingBrace, in: source) else {
            throw NSError(
                domain: "UIIntegrityContractTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not balance \(keyword) \(name)"]
            )
        }
        return body
    }
}
