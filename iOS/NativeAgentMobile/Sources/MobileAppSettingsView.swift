import SwiftUI
import NativeAgentShared

/// One section per settings page, in the Mac's order, or only `pages`. The
/// page that shows it refreshes the shared Mac readback.
struct MobileAppSettingsSections: View {
    var pages: [String]?
    var title: String?
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore

    var body: some View {
        let shown = MobileDesignSamples.rows(sync.appSettingRows).filter { pages?.contains($0.page) ?? true }
        let order = pages ?? shown.map(\.page).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Group {
            if let failure = sync.appSettingsFailure {
                AliveSection(title ?? "Mac settings") { AliveNote(failure) }
            }
            ForEach(order, id: \.self) { page in
                let rows = shown.filter { $0.page == page }
                if !rows.isEmpty {
                    AliveSection(title ?? page.replacingOccurrences(of: "_", with: " ").capitalized) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { AliveDivider() }
                            MobileAppSettingRow(row: row)
                        }
                    }
                    .disabled(!pairingStore.isPaired)
                }
            }
            if shown.isEmpty && sync.appSettingsFailure == nil {
                AliveSection(title ?? "Mac settings") {
                    AliveNote(sync.appSettingsLoading ? "Reading the Mac's settings…" : "No settings have arrived from the Mac yet.")
                }
            }
        }
    }
}

private struct MobileAppSettingRow: View {
    let row: MobileAppSetting
    private let sync = iCloudSyncEngine.shared
    @State private var draft = ""

    var body: some View {
        Group {
            if !row.writable {
                AliveValueRow(label: row.label,
                              value: row.value.isEmpty ? "—" : row.value.replacingOccurrences(of: "\n", with: ", "))
            } else if row.type == "boolean" {
                Toggle(row.label, isOn: Binding(get: { row.value == "true" }, set: { send($0 ? "true" : "false") }))
                    .aliveRow()
            } else if row.type == "choice" {
                MobileAdaptiveRow(spacing: 12) {
                    Text(row.label).foregroundStyle(AlivePalette.text)
                    Spacer(minLength: 8)
                    Picker(row.label, selection: Binding(get: { row.value }, set: { send($0) })) {
                        ForEach(row.choices.contains(row.value) ? row.choices : [row.value] + row.choices, id: \.self) {
                            Text(Self.label(forChoice: $0)).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .aliveRow()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.label).foregroundStyle(AlivePalette.text)
                    TextField(row.type == "list" ? "One per line" : row.label, text: $draft,
                              axis: row.type == "list" ? .vertical : .horizontal)
                        .keyboardType(row.type == "number" ? .numberPad : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(AlivePalette.secondary)
                        .onSubmit { send(draft) }
                    if draft != row.value {
                        Button("Save") { send(draft) }.aliveSecondaryButton()
                    }
                }
                .aliveRow()
                .onAppear { draft = row.value }
                .onChange(of: row.value) { _, value in draft = value }
            }
        }
        // The Mac's read-back moves the control; submission only stops taps.
        .allowsHitTesting(!sync.appSettingsSaving.contains(row.id))
    }

    /// A word id the Mac stores (`read_only`, `low_memory`) reads as words;
    /// anything else (a model id, a number) is shown as the Mac spells it.
    static func label(forChoice value: String) -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isLowercase || $0 == "_" }) else { return value }
        let words = value.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func send(_ value: String) {
        Task { await sync.setAppSetting(row, to: value) }
    }
}
