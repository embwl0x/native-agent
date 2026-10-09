import SwiftUI
import NativeAgentShared

struct MobileTrustEditor: View {
    let policy: TrustPolicy
    @ObservedObject var store: SettingsStore
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var pending: MobileTrustAction?
    @State private var showConfirmation = false
    @State private var isSaving = false
    @State private var feedback: String?
    @State private var showsPermissionLevel = false

    private var current: TrustPolicy { policy }
    private var effectiveLevel: String? {
        // Match MacControlGate.fullMacActive, including older mixed policies.
        if current.effectiveOutsideDefault == "allow"
            || current.permissionLevel == "wide_open_receipts"
            || current.permissionLevel == "full_mac_os" { return "full_mac_os" }
        return current.permissionLevel
    }
    private var fullMacConfirmation: Bool {
        if case .preset(.fullMac, _) = pending { return true }
        return false
    }

    private var currentPreset: MobileTrustAction.Preset? {
        if effectiveLevel == "full_mac_os", current.effectiveOutsideDefault == "allow" { return .fullMac }
        guard current.effectiveRequireBackups == true,
              current.developerMode == false,
              current.filePolicy?.allowDestructiveActions == false,
              current.macControlPolicy?.shellAllowed == false,
              current.macControlPolicy?.systemControlAllowed == false else { return nil }
        if current.permissionLevel == "strict", current.autonomyDefault == "supervised",
           current.effectiveOutsideDefault == "deny" { return .safe }
        guard current.permissionLevel == "balanced", current.autonomyDefault == "workspace_autonomous" else { return nil }
        switch current.effectiveOutsideDefault {
        case "deny": return .workMode
        case "ask": return .builder
        default: return nil
        }
    }

    var body: some View {
        sections
            .confirmationDialog(
                fullMacConfirmation ? MobileTrustAction.fullMacTitle : "Save trust policy?",
                isPresented: $showConfirmation, titleVisibility: .visible
            ) {
                Button(fullMacConfirmation ? MobileTrustAction.fullMacButton : "Save", role: .destructive) {
                    confirm()
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(fullMacConfirmation ? MobileTrustAction.fullMacMessage : confirmationMessage)
            }
    }

    @ViewBuilder
    private var sections: some View {
        if !pairingStore.isPaired { AliveUnpairedReason() }
        AliveSection("Access and policy") {
            Menu(currentPreset?.title ?? "Custom") {
                ForEach(MobileTrustAction.Preset.allCases, id: \.rawValue) { preset in
                    Button { propose(.preset(preset, confirmed: false)) } label: {
                        if currentPreset == preset {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                        Text(preset.summary)
                    }
                }
            }
            .aliveRow()
            .frame(minHeight: 44)
            .disabled(isSaving || !pairingStore.isPaired)
            AliveDivider()
            AliveValueRow(label: "Level", value: effectiveLevel.map(label) ?? TrustPolicySummaryPresentation.unknownValue)
            if effectiveLevel == "full_mac_os" {
                Text("Full Mac stays on until you change it.").aliveRow()
            }
        }
        AliveSection(nil) {
            DisclosureGroup("Permission level", isExpanded: $showsPermissionLevel) {
                choice("Level", field: .permissionLevel, value: effectiveLevel)
                AliveDivider()
                choice("Autonomy default", field: .autonomyDefault, value: current.autonomyDefault)
                AliveDivider()
                choice("Outside default", field: .outsideDefault,
                       value: effectiveLevel == "full_mac_os" ? "allow" : current.effectiveOutsideDefault)
                AliveDivider()
                toggle("Developer mode", field: .developerMode, value: current.developerMode)
                AliveDivider()
                toggle("Require backups", field: .requireBackups, value: current.effectiveRequireBackups)
            }
            .aliveRow()
            .frame(minHeight: 44)
        }
        .disabled(isSaving || !pairingStore.isPaired)
        AliveSection("Desk") {
            toggle("Desk enabled", field: .workshopEnabled, value: current.workshopPolicy?.enabled)
            AliveDivider()
            toggle("Show timeline", field: .showTimeline, value: current.workshopPolicy?.showTimeline)
        }
        .disabled(isSaving || !pairingStore.isPaired)
        AliveSection("Training") {
            toggle("Autonomous training", field: .autonomousTraining, value: current.trainingPolicy?.autonomousTraining)
            AliveDivider()
            toggle("Dream scheduler", field: .dreamScheduler, value: current.trainingPolicy?.dreamScheduler)
        }
        .disabled(isSaving || !pairingStore.isPaired)
        if isSaving { Text("Saving trust policy…").aliveRow() }
        if let feedback { Text(feedback).aliveRow() }
    }

    private var confirmationMessage: String {
        switch pending {
        case .preset(let preset, _): "Apply \(preset.title) on your Mac?"
        case .policy(let field, let value, _): "Change \(title(field)) to \(label(value)) on your Mac?"
        case nil: ""
        }
    }

    private func choice(_ title: String, field: MobileTrustAction.Field, value: String?) -> some View {
        Picker(title, selection: Binding(
            get: { value ?? "" },
            set: { propose(.policy(field, value: $0, confirmed: false)) }
        )) {
            if let value, !field.values.contains(value) {
                Text(label(value)).tag(value)
            } else if value == nil {
                Text(TrustPolicySummaryPresentation.unknownValue).tag("")
            }
            ForEach(field.values, id: \.self) { Text(label($0)).tag($0) }
        }
        .aliveRow()
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func toggle(_ title: String, field: MobileTrustAction.Field, value: Bool?) -> some View {
        if let value {
            Toggle(title, isOn: Binding(
                get: { value },
                set: { propose(.policy(field, value: String($0), confirmed: false)) }
            )).aliveRow().frame(minHeight: 44)
        } else {
            AliveValueRow(label: title, value: TrustPolicySummaryPresentation.unknownValue)
        }
    }

    private func propose(_ request: MobileTrustAction) {
        guard !isSaving, pairingStore.isPaired else { return }
        if case .policy(.outsideDefault, "allow", _) = request {
            pending = .preset(.fullMac, confirmed: false)
        } else if case .policy(.outsideDefault, _, _) = request, effectiveLevel == "full_mac_os" {
            feedback = MobileTrustAction.outsideFullMacRefusal
            return
        } else if case .policy(.permissionLevel, let value, _) = request,
                  let preset = MobileTrustAction.Preset(permissionLevel: value) {
            pending = .preset(preset, confirmed: false)
        } else {
            pending = request
        }
        showConfirmation = true
    }

    private func confirm() {
        guard let pending, !isSaving, pairingStore.isPaired else { return }
        let request: MobileTrustAction
        switch pending {
        case .preset(let preset, _): request = .preset(preset, confirmed: true)
        case .policy(let field, let value, _): request = .policy(field, value: value, confirmed: true)
        }
        self.pending = nil
        isSaving = true
        feedback = nil
        Task { @MainActor in
            do {
                let saved = try await iCloudSyncEngine.shared.setTrustPolicy(request)
                store.trustPolicy = saved
                feedback = "Trust policy saved on your Mac."
            } catch {
                feedback = "Trust policy was not confirmed: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func title(_ field: MobileTrustAction.Field) -> String {
        switch field {
        case .permissionLevel: "Level"
        case .autonomyDefault: "Autonomy default"
        case .requireBackups: "Require backups"
        case .outsideDefault: "Outside default"
        case .developerMode: "Developer mode"
        case .workshopEnabled: "Desk enabled"
        case .showTimeline: "Show timeline"
        case .autonomousTraining: "Autonomous training"
        case .dreamScheduler: "Dream scheduler"
        }
    }

    private func label(_ value: String) -> String {
        switch value {
        case "strict": "Strict"
        case "balanced": "Balanced"
        case "full_mac_os": "Full Mac"
        case "supervised": "Supervised"
        case "app_data_autonomous": "App data autonomous"
        case "workspace_autonomous": "Workspace autonomous"
        case "deny": "Deny"
        case "ask": "Ask"
        case "allow": "Allow"
        case "true": "On"
        case "false": "Off"
        default: value
        }
    }
}
