import SwiftUI
import NativeAgentShared
import UIKit
import QuickLook
// Blueprint: | `MobileInteractionCard.swift` | Inline interaction fields, setup routing and signed answers |

struct MobileInteractionCard: View {
    let card: InlineInteraction
    let descriptor: InlineInteractionDescriptor
    let sessionID: String
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var response: String?
    @State private var answeredRevision: Int?
    @State private var showsTrust = false
    @State private var showsProviders = false
    @StateObject private var settingsStore = SettingsStore()

    private var locallyRequired: Bool {
        [.internetAccounts, .chromeSetup, .pairDevice, .keyring, .macPermissionGrant].contains(descriptor.control)
    }
    private var editable: Bool {
        card.state.name == "pending" || card.state.isRetryable || (card.state.name == "running" && locallyRequired)
    }
    private var fields: [InlineCardField] {
        if descriptor.control == .providerAPIKey { return [.init(label: "API key or setup token", placeholder: "Paste the key")] }
        guard descriptor.control == .connectorManualToken else { return [] }
        let fields = descriptor.connectorFields
        return fields.isEmpty ? [.init(label: "Token", placeholder: "Token", id: "token")] : fields
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.title, systemImage: descriptor.icon ?? "questionmark.circle")
                .font(.headline)
            Text(card.why)
            if let outcome = card.state.outcome { Label(outcome.summary, systemImage: "checkmark.circle") }
            else if card.state == .declined { Text("Not now. " + card.declineConsequence).foregroundStyle(.secondary) }
            else if card.state == .superseded { Text("Replaced by a newer request.").foregroundStyle(.secondary) }
            else if card.state.isUnknown { Text("This build cannot answer this card.").foregroundStyle(.secondary) }
            else {
                if case .stopped(let reason) = card.state { Text("Stopped: " + reason).foregroundStyle(.secondary) }
                if let reason = card.state.failureReason { Text(reason).foregroundStyle(.orange) }
                if let note = card.persistenceNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                if card.kind == .permission {
                    Text("Access: " + (card.mode?.phrase ?? "read and write")).font(.footnote)
                    Text("macOS privacy grants still require approval on the Mac.").font(.footnote).foregroundStyle(.secondary)
                }
                if locallyRequired {
                    Text("Complete this setup on your Mac, then check again here.").font(.footnote)
                    Button("Check again") { answer("verify") }
                } else if descriptor.control == .trustPostureRequired {
                    Button("Review Trust") { showsTrust = true }
                    Button("Check again") { answer("verify") }
                } else if descriptor.isActionable {
                    if descriptor.control == .providerAPIKey || descriptor.control == .providerGroupModel {
                        Button("Provider settings") { showsProviders = true }
                        Button("Check again") { answer("verify") }
                    }
                    ForEach(fields, id: \.id) { field in
                        Group {
                            if field.isSecret { SecureField(field.label, text: fieldBinding(field.id)) }
                            else { TextField(field.label, text: fieldBinding(field.id)) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    }
                    if !fields.isEmpty {
                        Text("Encrypted to your paired Mac. Credentials never enter the conversation.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if card.kind == .choose || card.kind == .modelChoice {
                        ForEach(card.options.filter { $0.id != "__save_for_group__" }) { option in
                            Button { answer("primary", choice: option.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let detail = option.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if card.kind == .modelChoice {
                            Picker("Applies to", selection: fieldBinding("scope")) {
                                Text("This request").tag(InlineInteraction.Scope.thisRequestOnly.rawValue)
                                Text("Keep for this group").tag(InlineInteraction.Scope.persistent.rawValue)
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Button(card.state.name == "stopped" ? "Resume" : card.primaryActionLabel) { answer("primary") }
                    }
                } else { Text(descriptor.unavailableReason ?? "This control is unavailable.") }
                Button("Not now") { answer("decline") }
                Text(card.declineConsequence).font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView() }
            if let response, !response.isEmpty { Text(response).font(.footnote) }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(busy || !editable || answeredRevision == card.revision)
        .onAppear { values["scope"] = (card.primaryScope ?? .thisRequestOnly).rawValue }
        .onChange(of: card.revision) { _, _ in answeredRevision = nil; response = nil }
        .sheet(isPresented: $showsTrust) {
            NavigationStack {
                TrustPolicyView(store: settingsStore)
                    .toolbar { Button("Done") { showsTrust = false } }
            }
        }
        .sheet(isPresented: $showsProviders) {
            NavigationStack {
                ProviderSettingsView()
                    .toolbar { Button("Done") { showsProviders = false } }
            }
        }
    }

    private func fieldBinding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
    private func answer(_ action: String, choice: String? = nil) {
        var input = values
        if let choice { input["choice"] = choice }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await iCloudSyncEngine.shared.answerInteraction(card, sessionID: sessionID,
                    actionName: action, values: input)
                response = result["message"]
                answeredRevision = card.revision
                values = [:]
                await iCloudSyncEngine.shared.refreshChatTranscriptsSnapshot()
            } catch {
                response = error.localizedDescription
                await iCloudSyncEngine.shared.refreshChatTranscriptsSnapshot()
            }
        }
    }
}
