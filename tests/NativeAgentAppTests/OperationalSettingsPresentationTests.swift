import Foundation
import AppKit
import Testing
@testable import NativeAgentApp

@Suite("Operational settings presentation")
struct OperationalSettingsPresentationTests {
    @Test func providerRowsStayGroupedAndPickersStayLabeled() throws {
        let source = try AppSourceScraping.appSource("ProviderSettingsView.swift")

        #expect(!source.contains("GlassCard(tint: providerTint"))
        #expect(source.contains("cornerRadius: NativeAgentRadius.control"))
        #expect(!source.contains("Picker(\"\","))
        #expect(source.contains("Picker(\"Provider\","))
        #expect(source.contains("Picker(\"Model\","))
        #expect(source.contains(".accessibilityLabel(\"\\(surfaceLabel(surface)) provider\")"))
        #expect(source.contains(".accessibilityLabel(\"\\(surfaceLabel(surface)) model\")"))
        #expect(source.contains("static let reasoningPickerWidth: CGFloat = 148"))
        #expect(source.contains(".frame(width: ProviderSurfaceRowLayout.reasoningPickerWidth)"))
        #expect(source.contains("static let fastToggleWidth: CGFloat = 88"))
        #expect(source.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(source.contains(".frame(width: ProviderSurfaceRowLayout.fastToggleWidth)"))
    }

    @Test func macPermissionTogglesStayLabeledAndTransactional() throws {
        let source = try AppSourceScraping.appSource("MacIntegrationView.swift")

        #expect(!source.contains(".labelsHidden()"))
        #expect(source.contains("Toggle(isOn: binding(for: id, mode: .read))"))
        #expect(source.contains("Toggle(isOn: binding(for: id, mode: .write))"))
        #expect(source.contains("MacIntegrationPermissionStore.shared.set("))
        #expect(source.contains("permissions[id] = previous"))
        #expect(source.contains("MacIntegrationICloudBridge.shared.push("))
        #expect(source.contains("frameworkPermission: .calendar"))
        #expect(source.contains("frameworkPermission: .reminders"))
        #expect(source.contains("frameworkPermission: .contacts"))
        #expect(source.contains("Task { await requestFrameworkGrant(permission) }"))
        #expect(source.contains("Text(status == \"limited\" ? \"Grant Full\" : \"Grant\")"))
        #expect(source.contains("permissionRequestError = \"macOS did not register"))
    }

    @Test func macPermissionStatusFollowsSceneActivationWithoutIdlePolling() throws {
        let source = try AppSourceScraping.appSource("MacIntegrationView.swift")

        #expect(source.contains("@Environment(\\.scenePhase) private var scenePhase"))
        #expect(source.contains(".task(id: scenePhase)"))
        #expect(source.contains("guard scenePhase == .active else { return }"))
        #expect(!source.contains("while !Task.isCancelled"))
        #expect(!source.contains("3_000_000_000"))
    }

    @Test func providerSavesSynchronizeTheOpenChatPickerCache() throws {
        let source = try AppSourceScraping.appSource("AppModel+ViewClientOps.swift")

        #expect(source.contains("chatProvider = providerId"))
        #expect(source.contains("applySurfacePickerSelection("))
        #expect(source.contains("chatReasoningEffort = reasoningEffort"))
        #expect(source.contains("chatFastMode = serviceTier == \"priority\""))
    }

    @Test func systemAndSidebarSettingsUseOneLiveRoot() throws {
        let menu = try AppSourceScraping.appSource("MenuBarController.swift")
        let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
        let inAppSettings = try AppSourceScraping.appSource("SlimSettingsView.swift")
        let appRoot = try AppSourceScraping.repositoryRoot().appendingPathComponent("Sources/NativeAgentApp")

        #expect(menu.contains("struct HotkeyControlView: View"))
        #expect(menu.contains("GlobalHotkeyManager.shared.setEnabled(newValue)"))
        #expect(app.contains("Settings {\n            SlimSettingsView()"))
        #expect(inAppSettings.contains("HotkeyControlView()"))
        #expect(!FileManager.default.fileExists(atPath: appRoot.appendingPathComponent("SettingsView.swift").path))
        #expect(!menu.contains("struct HotkeyPreferencesView"))
        #expect(!menu.contains("MenuBarStatusMonitor"))
    }

    @Test @MainActor func softwareUpdateConfigurationRequiresOneRealPublishedFeed() {
        let validKey = Data(repeating: 7, count: 32).base64EncodedString()
        let usable: [String: Any] = [
            "SUFeedURL": "https://updates.nativeagent.dev/appcast.xml",
            "SUPublicEDKey": validKey,
            "NativeAgentUpdateFeedPublished": true,
        ]

        #expect(UpdateController.resolveUnavailability(info: usable) == nil)
        #expect(UpdateController.resolveUnavailability(info: usable.merging([
            "NativeAgentUpdateFeedPublished": false,
        ]) { _, new in new }) == .feedNotPublished)
        #expect(UpdateController.resolveUnavailability(info: usable.merging([
            "SUFeedURL": "https://example.com/nativeagent/appcast.xml",
        ]) { _, new in new }) == .notConfigured)
        #expect(UpdateController.resolveUnavailability(info: usable.merging([
            "SUPublicEDKey": Data(repeating: 7, count: 31).base64EncodedString(),
        ]) { _, new in new }) == .notConfigured)
    }

    @Test func settingsAndAppMenuShareTheSingleUpdaterOwner() throws {
        let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
        let settings = try AppSourceScraping.appSource("SlimSettingsView.swift")
        let updater = try AppSourceScraping.appSource("UpdateController.swift")

        #expect(updater.contains("static let shared = UpdateController()"))
        #expect(app.contains("UpdateController.shared"))
        #expect(settings.contains("UpdateController.shared"))
        #expect(settings.contains("updateController.menuTitle"))
        #expect(settings.contains("updateController.checkForUpdates()"))
    }

    @Test func productionNavigationHasNoInvisibleQAButtonsOrMenuBarMaintenanceTriggers() throws {
        let content = try AppSourceScraping.appSource("ContentView.swift")
        let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
        let chat = try AppSourceScraping.appSource("ChatView.swift")
        let detachedChat = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        let focusedCommands = try AppSourceScraping.appSource("ChatFocusedCommands.swift")

        for hiddenTitle in ["QA Mode:", "User Mode:", "Jump:"] {
            #expect(!content.contains(hiddenTitle))
        }
        for retiredMenuItem in [
            "Browser Dry Run", "Gauntlet Dry Run", "Run Memory Consolidation",
            "Run REM Consolidation", "Run Self-Improvement",
        ] {
            #expect(!app.contains(retiredMenuItem))
        }
        #expect(app.contains("CommandMenu(\"Navigate\")"))
        #expect(app.contains("NativeAgentAppCoordinator.shared.request"))
        #expect(!chat.contains(".opacity(0)"))
        #expect(!detachedChat.contains(".opacity(0)"))
        #expect(chat.contains(".focusedSceneValue(\\.chatCommandActions"))
        #expect(detachedChat.contains(".focusedSceneValue(\\.chatCommandActions"))
        #expect(focusedCommands.contains("struct ChatFocusedCommands: Commands"))
    }

    @Test func cognitionRefreshDoesNotWriteControls() throws {
        let source = try AppSourceScraping.appSource("CognitionObservatoryView.swift")

        #expect(!source.contains(".onChange(of: enabled)"))
        #expect(!source.contains(".onChange(of: reflectionBudget)"))
        #expect(source.contains("Toggle(\"Cognitive substrate\", isOn: enabledBinding)"))
        #expect(source.contains("private var reflectionBudgetBinding: Binding<Int>"))
    }

    @Test func subconsciousMasterOwnsEveryResidentLaneAndFluidContextHasOneProductionControl() throws {
        let settings = try AppSourceScraping.appSource("SlimSettingsView.swift")
        let observatory = try AppSourceScraping.appSource("CognitionObservatoryView.swift")
        let onboarding = try AppSourceScraping.appSource("NativeClient+OnboardingActions.swift")
        let syncLifecycle = try AppSourceScraping.appSource("MacSyncEngine+Lifecycle.swift")

        #expect(settings.contains("@AppStorage(\"organismKernelEnabled\")"))
        #expect(settings.contains("Picker(\"Fluid Context\", selection: $contextFlowMode)"))
        #expect(settings.contains("NativeCognitionRuntime.shared.setSubconsciousMasterEnabled("))
        #expect(settings.contains("let actual = await NativeCognitionRuntime.shared.setSubconsciousMasterEnabled("))
        #expect(settings.contains("NativeContextFlowRuntime.shared.setMode(requested)"))
        #expect(!settings.contains("NativeCognitionRuntime.shared.setOrganismKernelEnabled"))
        #expect(!observatory.contains("Picker(\"Fluid Context\""))
        #expect(observatory.contains("Toggle(\"Organism body kernel\""))
        #expect(onboarding.contains("NativeCognitionRuntime.shared.refreshAfterOnboardingTransition()"))
        #expect(onboarding.contains("NativeContextFlowRuntime.shared.reloadConfiguration()"))
        #expect(syncLifecycle.contains("startCognitionSnapshotObservation()"))
        #expect(!syncLifecycle.contains("Task.sleep(for: .seconds(1)"))
    }

    @Test func visibleToolsCatalogRequestsDetailWithoutChangingChatDefault() throws {
        let source = try AppSourceScraping.appSource("AppModel+ProvidersAuth.swift")
        let tools = try AppSourceScraping.appSource("ToolsView.swift")

        #expect(source.contains("input: [\"detail\": .string(\"full\")]"))
        #expect(tools.contains("ChatToolCatalogSection("))
        #expect(tools.contains("\\(catalog.tools.count) tools"))
        #expect(tools.contains("DisclosureGroup(isExpanded: bucketExpandedBinding(bucket.id))"))
    }

    @Test func skillsAndToolsRenderAsSeparatePagesInsideOneSidebarTab() throws {
        let sidebar = try AppSourceScraping.appSource("Models/SidebarModels.swift")
        let content = try AppSourceScraping.appSource("ContentView.swift")
        let combined = try AppSourceScraping.appSource("SkillsToolsView.swift")
        let commands = try AppSourceScraping.appSource("CommandPalette.swift")

        #expect(sidebar.contains("case skills = \"Skills\""))
        #expect(sidebar.contains("case tools = \"Tools\""))
        #expect(sidebar.contains("normalized == .skills ? \"Skills & Tools\""))
        #expect(!sidebar.contains(".cognition, .inboxPolicy, .tools, .mcp"))
        #expect(content.contains("case .skills: SkillsToolsView(selection: skillsToolsSection)"))
        #expect(combined.contains("Picker(\"Skills and Tools page\""))
        #expect(combined.contains(".labelsHidden()"))
        #expect(combined.contains("case .skills:"))
        #expect(combined.contains("SkillLifecycleView()"))
        #expect(combined.contains("case .tools:"))
        #expect(combined.contains("ToolsView()"))
        #expect(commands.contains("request(.skillsTools(.tools))"))
    }

    @MainActor
    @Test func stationaryPointerCannotOverrideCommandPaletteKeyboardMatch() {
        #expect(commandPaletteShouldAdoptHover(true, eventType: .mouseMoved))
        #expect(commandPaletteShouldAdoptHover(true, eventType: .leftMouseDragged))
        #expect(!commandPaletteShouldAdoptHover(true, eventType: .mouseEntered))
        #expect(!commandPaletteShouldAdoptHover(true, eventType: .keyDown))
        #expect(!commandPaletteShouldAdoptHover(true, eventType: .keyUp))
        #expect(!commandPaletteShouldAdoptHover(true, eventType: nil))
        #expect(!commandPaletteShouldAdoptHover(false, eventType: .mouseMoved))
    }

    // Arrow keys always carry .function|.numericPad by hardware convention;
    // the palette's KeyCatcher must treat them as bare (the pre-fix guard
    // compared against an empty mask and rejected every arrow press), while
    // real user-held modifiers must still pass the event through to the field.
    @Test func paletteBareKeyEventIgnoresHardwareArrowFlags() {
        #expect(commandPaletteIsBareKeyEvent([]))
        #expect(commandPaletteIsBareKeyEvent([.function, .numericPad]))
        #expect(commandPaletteIsBareKeyEvent([.function]))
        #expect(!commandPaletteIsBareKeyEvent([.command]))
        #expect(!commandPaletteIsBareKeyEvent([.shift, .function, .numericPad]))
        #expect(!commandPaletteIsBareKeyEvent([.option, .function]))
        #expect(!commandPaletteIsBareKeyEvent([.control]))
    }

    @MainActor
    @Test func globalHotkeyRegistrationTransitionsAreIdempotent() {
        #expect(GlobalHotkeyManager.registrationTransition(enabled: true, isRegistered: false) == .register)
        #expect(GlobalHotkeyManager.registrationTransition(enabled: false, isRegistered: true) == .unregister)
        #expect(GlobalHotkeyManager.registrationTransition(enabled: true, isRegistered: true) == .none)
        #expect(GlobalHotkeyManager.registrationTransition(enabled: false, isRegistered: false) == .none)
    }

    @Test func retiredCompleteRootViewsStayDeletedAndPersonaResetIsRehomed() throws {
        let root = try AppSourceScraping.repositoryRoot().appendingPathComponent("Sources/NativeAgentApp")
        for file in [
            "AutonomyView.swift", "PairMobileView.swift", "ReleaseView.swift",
            "SetupView.swift", "SkillsView.swift",
        ] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path))
        }
        let personality = try AppSourceScraping.appSource("PersonalityView.swift")
        #expect(personality.contains("ResetPersonaView {"))
        #expect(personality.contains("await loadProfile(forceRefresh: true)"))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Models/MobilePairingModels.swift").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("PairingSecretManager.swift").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("MacPairingView.swift").path
        ))
        let pairingOwner = try AppSourceScraping.appSource("PairingSecretManager.swift")
        let signedBridge = try AppSourceScraping.appSource("iCloudBridge.swift")
        let syncSecurity = try AppSourceScraping.appSource("MacSyncEngine+Security.swift")
        #expect(pairingOwner.contains("SecRandomCopyBytes(kSecRandomDefault, 32"))
        #expect(signedBridge.contains("PairingSecretManager.loadOrGenerateSecret()"))
        #expect(syncSecurity.contains("PairingSecretManager.loadOrGenerateSecret()"))
    }

    @Test func publicCloudKitActionsReuseCanonicalMacSyncAuthority() throws {
        let bridge = try AppSourceScraping.appSource("iCloudBridge.swift")
        let inbox = try AppSourceScraping.appSource("MacSyncEngine+Inbox.swift")
        let lifecycle = try AppSourceScraping.appSource("MacSyncEngine+Lifecycle.swift")

        #expect(bridge.contains(#""kind": "icloud_action_response""#))
        #expect(bridge.contains("MacSyncEngine.shared.processCloudKitActionMessage(msg)"))
        #expect(inbox.contains("validateInboxAction(data: data, action: action)"))
        #expect(inbox.contains("var body = await dispatchAction(action)"))
        #expect(inbox.contains("recordProcessed(action.msgId)"))
        #expect(lifecycle.contains("loadProcessedIds()"))
    }

    @Test func snapshotProjectionWaitsForDriveTransportSelection() throws {
        let bridge = try AppSourceScraping.appSource("iCloudBridge.swift")
        let call = "MacSyncEngine.shared.startCloudKitSnapshotProjection()"
        #expect(bridge.components(separatedBy: call).count - 1 == 1)

        let fallback = try #require(bridge.range(of: "guard let containerURL else"))
        let projection = try #require(bridge.range(of: call))
        let drive = try #require(bridge.range(of: "MacSyncEngine.shared.start(docsURL: docsURL)"))
        #expect(projection.lowerBound > fallback.lowerBound)
        #expect(projection.lowerBound < drive.lowerBound)
    }

    // Source readers (appSource / repositoryRoot) live in the shared
    // AppSourceScraping enum.
}
