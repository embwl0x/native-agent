import MacIntegration
import NativeAgentCore
import AppToolRuntime
import ChatToolParsing
import PersistenceCore
import AppKit
import MacControl
import NativeAgentShared
import SwiftUI
import TrustCenter
// Blueprint: | `MacControlPermissionsView.swift` | Checked consent controls, policy saves and explicit permission feedback |
struct MacControlPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    private var policy: MacControlPolicyWireSnapshot {
        get { appModel.editDraft("mac-control/policy", seed: savedPolicy) }
        nonmutating set { appModel.setEditDraft(newValue, for: "mac-control/policy", baseline: savedPolicy) }
    }
    @State private var savedPolicy = MacControlPolicyWireSnapshot()
    @State private var policyReadState: MacControlSetupStatusBadges.PolicyReadState = .loading
    @State private var policyRead = LatestRead()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showAuditSheet = false
    @State private var auditEntries: [MacControlAuditEntry] = []
    @State private var auditReadProblem: String?
    @State private var auditRead = LatestRead()
    @State private var isLoadingAudit = false
    @State private var pendingAuditReads = 0
    @State private var testNotifStatus: String?
    @State private var isTestingNotif = false
    // The advanced group contains unsaved policy controls. Keep its expansion
    // across ordinary navigation so a return to this surface does not hide the
    // only Save path behind a collapsed card.
    @AppStorage("macControl.showAdvancedControls") private var showAdvancedMacControls = false
    @State private var applyingPreset: MacIntegrationPreset?
    @State private var showFullMacConfirm = false
    @State private var isProbingAppleData = false
    @State private var appleDataProbeStatus: String?
    @State private var assistantWatchRefreshToken = 0

    private var hasUnsavedChanges: Bool {
        policy != savedPolicy
    }

    // Advanced controls state their Save and restart requirements once in the footnote.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            macIntegrationSetupPanel
            MacAssistantWatchSetupView(refreshToken: assistantWatchRefreshToken)

            // An eyebrow like its sibling sections; the fold row is a row.
            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                AliveEyebrow("Advanced Mac control")
                TrustFold(isExpanded: $showAdvancedMacControls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controls, commands and audit log")
                            .font(ShellType.rowTitle)
                            .foregroundStyle(NativeAgentShell.text)
                        Text("Each kind of control, shell commands, what I ask about first, the workbench and the audit log.")
                            .font(ShellType.rowDetail)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("macControl.advanced.disclosure")
                } trailing: {
                    // Unsaved edits wait on him: the one teal word here.
                    if hasUnsavedChanges {
                        Text("Unsaved")
                            .font(ShellType.captionSemibold)
                            .foregroundStyle(NativeAgentShell.needsYou)
                    }
                } content: {
                    if showAdvancedMacControls {
                        advancedMacControlControls
                    }
                }
            }
        }
        .task { await loadPolicy() }
        .onChange(of: appModel.engine.trust.policy) { _, newPolicy in
            policyRead.write {
            if let mp = newPolicy?.macControlPolicy {
                savedPolicy = mp
                policyReadState = .available
            } else {
                policyReadState = .unavailable
            }
            }
        }
        .sheet(isPresented: $showAuditSheet) {
            MacControlAuditSheet(
                entries: $auditEntries,
                isLoading: $isLoadingAudit,
                readProblem: $auditReadProblem
            )
        }
        .alert("Enable Full Mac access?", isPresented: $showFullMacConfirm) {
            Button("Enable Full Mac", role: .destructive) {
                Task { await applyIntegrationPreset(.full) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the Full Mac preset: files anywhere, shell, system control, and file move or trash, the same as the Full Mac card in Trust.")
        }
    }

    @ViewBuilder
    private var macIntegrationSetupPanel: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Mac control")
            // The presets are cards themselves, so they sit above the group
            // card rather than inside it — a card in a card is a plate.
            // The Mac's own radio group (User 09-27: all controls native).
            Picker("Mac control", selection: Binding<MacIntegrationPreset?>(
                get: { activePreset },
                set: { preset in
                    guard let preset else { return }
                    if preset == .full { showFullMacConfirm = true }
                    else { Task { await applyIntegrationPreset(preset) } }
                }
            )) {
                ForEach([MacIntegrationPreset.off, .watch, .assistant, .full]) { preset in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.title)
                        Text(preset.subtitle)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(preset))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(isSaving)
            .padding(.bottom, 2)

            AliveGroupCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setupBadges.access.text)
                        .font(ShellType.rowTitle)
                        .foregroundStyle(setupBadges.access.status == "failed" ? NativeAgentShell.trouble : NativeAgentShell.text)
                        .accessibilityIdentifier("mac-control.setup.access")
                    Text(setupBadges.detail)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(setupBadges.iOSRemote.text)
                            .accessibilityIdentifier("mac-control.setup.ios-remote")
                        Text("·")
                        Text(setupBadges.receipts.text)
                            .accessibilityIdentifier("mac-control.setup.receipts")
                    }
                    .font(ShellType.rowDetail)
                    .foregroundStyle(NativeAgentShell.secondary)
                    if let applyingPreset {
                        ProgressView("Applying \(applyingPreset.title)…")
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Set up Mac access", systemImage: "switch.2") {
                            Task { await enableMacAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                        .hazeTinted(.button)
                        .disabled(isSaving || isProbingAppleData)

                        Button("Check Calendar and Reminders", systemImage: "calendar.badge.checkmark") {
                            Task { await probeAppleDataAccess() }
                        }
                        .disabled(isSaving || isProbingAppleData)

                        if isProbingAppleData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Text(activePreset == .off || activePreset == .watch
                         ? "Set up Mac access turns on Assistant, then asks macOS for Calendar and Reminders."
                         : "Set up Mac access asks macOS for Calendar and Reminders. Your access level stays as it is.")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let appleDataProbeStatus {
                        Text(appleDataProbeStatus)
                            .font(ShellType.rowDetail)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS asks for these separately.")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                    AliveFlow(spacing: 8, lineSpacing: 8) {
                        Button("Open Accessibility", systemImage: "cursorarrow.motionlines") {
                            openSystemSettings(.accessibility)
                        }
                        Button("Open Automation", systemImage: "gearshape.2") {
                            openSystemSettings(.automation)
                        }
                        Button("Open Full Disk Access", systemImage: "externaldrive.badge.checkmark") {
                            openSystemSettings(.fullDiskAccess)
                        }
                        Button("Send a test notification", systemImage: "bell") {
                            Task { await sendTestNotification() }
                        }
                        .disabled(isTestingNotif || setupBadges.receipts.status != "ready")
                    }
                    if isSaving || isTestingNotif || testNotifStatus != nil {
                        HStack(spacing: 8) {
                            if isSaving || isTestingNotif {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if let status = testNotifStatus {
                                Text(status)
                                    .font(ShellType.rowDetail)
                                    .foregroundStyle(NativeAgentShell.secondary)
                            }
                        }
                    }
                }

                if let err = saveError {
                    Text(err)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var advancedMacControlControls: some View {
        VStack(alignment: .leading, spacing: 24) {
            AdvancedSection(title: "Mac control") {
                FeatureSwitchRow(
                    title: "Mac control",
                    detail: "I control this Mac with AppleScript, Accessibility, shell commands and more. The presets above choose safe defaults.",
                    isOn: Binding(
                        get: { policy.enabled },
                        set: { policy.enabled = $0 }
                    )
                )
                HStack(spacing: 10) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .hazeTinted(.button)
                    .disabled(isSaving || !hasUnsavedChanges)
                    .accessibilityIdentifier("macControl.advanced.save")

                    if isSaving {
                        ProgressView("Saving…")
                            .controlSize(.small)
                    } else if hasUnsavedChanges {
                        Text("Unsaved changes. Save before using the workbench.")
                            .font(ShellType.rowDetail)
                            .foregroundStyle(NativeAgentShell.needsYou)
                    }
                }
            }

            AdvancedSection(title: "Kinds of control") {
                MacControlCategoryRow(
                    label: "Notifications",
                    detail: "I post notifications on this Mac.",
                    safeDefault: true,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.notificationsAllowed)
                )
                MacControlCategoryRow(
                    label: "Spotlight search",
                    detail: "I search with Spotlight (read only).",
                    safeDefault: true,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.spotlightAllowed)
                )
                MacControlUnavailableCategoryRow(
                    label: "macOS Shortcuts",
                    detail: "Not built yet: I can't run Shortcuts in this version, so there is nothing to switch on."
                )
                MacControlUnavailableCategoryRow(
                    label: "System control",
                    detail: "Not built yet: system actions like locking the screen or sleeping the display aren't in this version, so there is nothing to switch on."
                )
                MacControlCategoryRow(
                    label: "File operations",
                    detail: "I read and write files. The file rules in Access and policy still apply.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.fileOpsAllowed)
                )
                MacControlCategoryRow(
                    label: "Accessibility",
                    detail: "I type, click and read the app in front. macOS must also allow it in System Settings → Privacy & Security → Accessibility.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.accessibilityAllowed)
                )
                MacControlCategoryRow(
                    label: "AppleScript",
                    detail: "I run AppleScript. I ask you first by default.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.applesScriptAllowed)
                )
                MacControlCategoryRow(
                    label: "JavaScript for Automation (JXA)",
                    detail: "I run JXA scripts. I ask you first by default.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.jxaAllowed)
                )
            }

            AdvancedSection(title: "Shell commands") {
                FeatureSwitchRow(
                    title: "Shell commands",
                    detail: "I can run any command, as if typed into Terminal. Powerful: keep this off unless you turned on developer mode on purpose.",
                    isOn: Binding(
                        get: { policy.shellAllowed },
                        set: {
                            if $0 { policy.enabled = true }
                            policy.shellAllowed = $0
                        }
                    )
                )
            }

            AdvancedSection(title: "iPhone remote control") {
                FeatureSwitchRow(
                    title: "Allow iPhone remote control",
                    detail: policy.enabled
                        ? "The paired iPhone app can ask me to run Mac control actions, through iCloud."
                        : "Turning this on also turns on Mac control.",
                    isOn: Binding(
                        get: { policy.remoteFromIosAllowed },
                        set: {
                            if $0 { policy.enabled = true }
                            policy.remoteFromIosAllowed = $0
                        }
                    )
                )
            }

            if let effectivePolicy {
                MacControlWorkbenchView(policy: effectivePolicy, policySaved: !hasUnsavedChanges)
            }

            AdvancedSection(title: "Audit log") {
                HStack(spacing: 12) {
                    Text("Every Mac control action I ran or was blocked from running.")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("View audit log") {
                        Task { await loadAudit() }
                        showAuditSheet = true
                    }
                }
            }

            Text("None of these switches change until you press Save. In restricted modes, the Mac control and shell switches take effect at the next restart; the rest apply right away. While Full Mac is active, its effective permissions apply; change the access mode to leave Full Mac.")
                .font(ShellType.rowDetail)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Logic

    private var effectivePolicy: MacControlPolicyWireSnapshot? {
        guard policyReadState == .available, let trust = appModel.engine.trust.policy else { return nil }
        return TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(trust)
    }

    private var activePreset: MacIntegrationPreset? {
        guard policyReadState == .available, let trust = appModel.engine.trust.policy,
              let effective = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(trust) else { return nil }
        if TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(trust) { return .full }
        let preset = TrustAccessModeCapabilityCatalog.macIntegrationPreset(for: effective)
        return preset == .full ? .assistant : preset
    }

    private var setupBadges: MacControlSetupStatusBadges.State {
        MacControlSetupStatusBadges.resolve(
            readState: policyReadState,
            savedPolicy: policyReadState == .available ? appModel.engine.trust.policy : nil
        )
    }

    private func applyIntegrationPreset(_ preset: MacIntegrationPreset) async {
        applyingPreset = preset
        isSaving = true
        saveError = nil
        testNotifStatus = nil
        defer {
            isSaving = false
            applyingPreset = nil
        }
        let submitted = policy
        do {
            let result = try await appModel
                .saveMacIntegrationPreset(preset.rawValue, currentPolicy: appModel.engine.trust.policy)
            appModel.applySavedTrustPolicy(result, status: "Applied \(preset.title).")
            if let mp = result.macControlPolicy {
                try appModel.acceptEditDraft("mac-control/policy", submitted: submitted, rebasingOn: mp)
                savedPolicy = mp
                policyReadState = .available
                testNotifStatus = "Applied \(preset.title)."
                assistantWatchRefreshToken += 1
            } else {
                policyReadState = .unavailable
                saveError = "Couldn't apply \(preset.title): saved Trust policy did not include Mac Control settings."
            }
        } catch {
            saveError = UserFacingError.message(error, action: "apply \(preset.title)")
        }
    }

    private func enableMacAccess() async {
        // Raises Off or Watch to Assistant; never lowers Assistant or Full Mac.
        if activePreset == .off || activePreset == .watch {
            await applyIntegrationPreset(.assistant)
            guard saveError == nil else { return }
        }
        await probeAppleDataAccess()
    }

    private func probeAppleDataAccess() async {
        isProbingAppleData = true
        appleDataProbeStatus = "Waiting for macOS Calendar and Reminders permission prompts..."
        defer { isProbingAppleData = false }

        do {
            let calendar = try await appModel.runConnectorAction(
                id: "mac.calendar_list_upcoming",
                dryRun: false,
                input: [
                    "hours_ahead": .int(24),
                    "limit": .int(5),
                ]
            )
            let reminders = try await appModel.runConnectorAction(
                id: "mac.reminders_list_due_today",
                dryRun: false,
                input: [
                    "include_completed": .bool(false),
                    "limit": .int(10),
                ]
            )
            appleDataProbeStatus = "Calendar \(calendar.status); Reminders \(reminders.status)."
            assistantWatchRefreshToken += 1
        } catch {
            appleDataProbeStatus = UserFacingError.message(error, action: "check Calendar and Reminders")
            assistantWatchRefreshToken += 1
        }
    }

    private func openSystemSettings(_ capability: SystemPermissionCapability) {
        if let message = SystemPermissionPreflight.openSettings(capability) {
            saveError = message
        }
    }

    private func macControlBinding(_ keyPath: WritableKeyPath<MacControlPolicyWireSnapshot, Bool>) -> Binding<Bool> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { newValue in
                if newValue { policy.enabled = true }
                policy[keyPath: keyPath] = newValue
            }
        )
    }

    /// Load saved Mac Control settings, reporting unavailable policy explicitly.
    private func loadPolicy() async {
        _ = await policyRead.read({ () async -> Result<MacControlPolicyWireSnapshot?, Error> in
        do {
            if let cached = appModel.engine.trust.policy?.macControlPolicy { return .success(cached) }
            return .success(try await appModel.engine.trust.load().macControlPolicy)
        } catch { return .failure(error) }
        }, publish: { result in
        do {
            if let mp = try result.get() {
                savedPolicy = mp
                policyReadState = .available
            } else {
                policyReadState = .unavailable
                saveError = "Couldn't load Mac Control settings: saved Trust policy did not include Mac Control settings."
            }
        } catch {
            // Fall through with default-zeroed policy + show inline error
            saveError = UserFacingError.message(error, action: "load Mac Control settings")
            policyReadState = .unavailable
        }
        })
    }

    private func save() async {
        isSaving = true
        saveError = nil
        let submitted = policy
        let baseline = appModel.editDraftBaseline("mac-control/policy", seed: savedPolicy)
        do {
            let result = try await appModel
                .saveMacControlPolicy(submitted, comparedTo: baseline)
            appModel.applySavedTrustPolicy(result, status: "Mac Control policy saved")
            if let mp = result.macControlPolicy {
                try appModel.acceptEditDraft("mac-control/policy", submitted: submitted, rebasingOn: mp)
                policyRead.write {
                    savedPolicy = mp
                    policyReadState = .available
                }
            } else {
                policyReadState = .unavailable
                saveError = "Mac Control policy saved without a readable Mac Control settings block."
            }
        } catch TrustCenterError.policyConflict {
            // Changed elsewhere meanwhile: start again from what is saved now.
            appModel.clearEditDraft("mac-control/policy")
            await loadPolicy()
            saveError = "Mac Control settings changed elsewhere while you edited, so your changes were not saved. The current settings are shown; make your change again."
        } catch {
            saveError = UserFacingError.message(error, action: "save Mac Control settings")
        }
        isSaving = false
    }

    private func sendTestNotification() async {
        isTestingNotif = true
        testNotifStatus = nil
        do {
            let ok = try await appModel
                .macControlNotify(title: "NativeAgent", message: "Mac Control test")
            testNotifStatus = ok ? "Sent." : "Swift app returned error."
        } catch {
            testNotifStatus = UserFacingError.message(error, action: "send the test notification")
        }
        isTestingNotif = false
    }

    private func loadAudit() async {
        pendingAuditReads += 1
        defer { pendingAuditReads -= 1; isLoadingAudit = pendingAuditReads > 0 }
        isLoadingAudit = true
        auditReadProblem = nil
        _ = await auditRead.read({ await appModel.engine.trust.auditLog() }, publish: { read in
        switch read {
        case .entries(let entries, let malformedLineCount):
            auditEntries = entries
            if malformedLineCount > 0 {
                auditReadProblem = "\(malformedLineCount) malformed audit \(malformedLineCount == 1 ? "line was" : "lines were") not shown."
            }
        case .sourceAbsent(let path):
            auditEntries = []
            auditReadProblem = "Audit source is absent at \(path.path)."
        case .unreadable(let reason):
            auditEntries = []
            auditReadProblem = "Couldn't read the audit log. \(reason)"
        }
        })
    }
}
