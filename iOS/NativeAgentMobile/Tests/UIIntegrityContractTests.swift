import Foundation
import XCTest

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
        XCTAssertTrue(pairing.contains("Settings → Apple Account"))
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

    func testSkillsAndToolsShareOnePrimaryDestination() throws {
        let content = try Self.source("ContentView.swift")
        let combined = try Self.source("SkillsToolsView.swift")
        let toolSnapshot = try Self.source("iCloudSyncEngine+Snapshots.swift")

        XCTAssertTrue(content.contains("SkillsToolsView()"))
        XCTAssertFalse(content.contains("SkillLifecycleView()\n                .tabItem"))
        XCTAssertTrue(combined.contains("case skills = \"Skills\""))
        XCTAssertTrue(combined.contains("case tools = \"Tools\""))
        XCTAssertTrue(combined.contains("tools_snapshot.json"))
        XCTAssertTrue(toolSnapshot.contains("loadSnapshotArrayAsync"))
    }

    func testPublicCloudKitContinuityDoesNotFallBackToDrivePolling() throws {
        let client = try Self.source("MacBridgeClient.swift")
        let bridge = try Self.source("iCloudBridge.swift")
        let actions = try Self.source("iCloudSyncEngine+Actions.swift")

        XCTAssertTrue(client.contains("await iCloudBridge.shared.pollIncomingNow()"))
        XCTAssertFalse(client.contains("await iCloudBridge.shared.checkMacOutbox()"))
        XCTAssertTrue(bridge.contains("NAMobileSnapshotGroup.allCases"))
        XCTAssertTrue(bridge.contains(#""kind": "icloud_action""#))
        XCTAssertTrue(bridge.contains("icloud_action_response"))
        XCTAssertTrue(actions.contains("sendActionEnvelope"))
        XCTAssertTrue(actions.contains("persistCloudKitActionResponse"))
    }

    func testVisualNotificationReadinessRequiresSuccessfulRegistration() throws {
        let bridge = try Self.source("iCloudBridge.swift")

        XCTAssertTrue(bridge.contains("let ready = await transport.ensurePushSubscriptions()"))
        XCTAssertTrue(bridge.contains("ready: ready && transport.presentsVisualNotifications"))
        XCTAssertFalse(bridge.contains("if !transport.presentsVisualNotifications"))
    }

    func testSnapshotGroupsDriveVisibleStoresWithoutCloudPolling() throws {
        let setup = try Self.source("iCloudSyncEngine+Setup.swift")
        let content = try Self.source("ContentView.swift")
        let workshop = try Self.source("WorkshopView.swift")
        let memory = try Self.source("MemoryView.swift")
        let advanced = try Self.source("AdvancedView.swift")
        let inspector = try Self.source("TurnInspectorView.swift")

        XCTAssertTrue(setup.contains("func refreshSnapshotGroup("))
        XCTAssertTrue(setup.contains("await refreshActivitySnapshot()"))
        XCTAssertTrue(setup.contains("await refreshCatalogSnapshot()"))
        XCTAssertTrue(content.contains("while !Task.isCancelled, !pairingStore.usesICloudTransport"))
        XCTAssertTrue(workshop.contains(".onChange(of: sync.workshopTasks)"))
        XCTAssertTrue(memory.contains(".onChange(of: sync.memories)"))
        XCTAssertTrue(advanced.contains(".onChange(of: sync.runs)"))
        XCTAssertTrue(inspector.contains(".onChange(of: sync.turnSummaries)"))
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
}
