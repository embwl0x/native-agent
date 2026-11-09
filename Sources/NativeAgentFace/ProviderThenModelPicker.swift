import SwiftUI
// Blueprint: | `ProviderThenModelPicker.swift` | Shared provider/model menu for onboarding and helper editors |

/// Retain the saved model label even when the catalog cannot offer it.
struct ProviderThenModelPicker: View {
    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
    }
    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        let ready: Bool
        let models: [Model]
    }

    let providers: [Provider]
    let currentProviderID: String
    let currentModelID: String
    let disabled: Bool
    let onSelect: (Provider, Model) -> Void

    private var selectedLabel: String {
        guard !currentModelID.isEmpty else { return "Choose model" }
        let provider = providers.first { $0.id == currentProviderID }
        let name = provider?.name ?? currentProviderID
        let suffix = provider?.ready == true
            ? (provider?.models.isEmpty == true ? " · no models available" : "")
            : (currentProviderID.isEmpty ? "" : " · not connected")
        let model = provider?.models.first { $0.id == currentModelID }?.name ?? currentModelID + " — unavailable"
        return "\(name)\(suffix) · \(model)"
    }

    /// Drop account-transport parentheticals so picker labels expose provider identity, not wiring.
    static func plainProviderName(_ displayName: String) -> String {
        guard let open = displayName.range(of: " (") else { return displayName }
        return String(displayName[..<open.lowerBound])
    }

    var body: some View {
            Menu {
                ForEach(providers.filter(\.ready)) { provider in
                    Section(provider.name) {
                        if provider.models.isEmpty { Text("No models available") }
                        ForEach(provider.models) { model in
                            Button("\(provider.name) · \(model.name)") { onSelect(provider, model) }
                        }
                    }
                }
            } label: {
                Text(selectedLabel)
            }
            .disabled(disabled).accessibilityLabel("Model and provider")
    }
}
