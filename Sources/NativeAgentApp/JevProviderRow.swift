import SwiftUI
import ChatOrchestration
import PersistenceCore

/// The one control anyone ever sees for Jev: a name, a line saying what it
/// does, and somewhere to paste the key.
///
/// A key present turns all five advisory checks on. Removing the key turns
/// every one of them off again. The per-check switches are settings the agent
/// changes itself with `app_setting_set`, not controls on this page.
struct JevProviderRow: View {
    @State private var draft: String = ""
    @State private var configured: Bool = JevSettings.isConfigured(dataRoot: NativeAgentPaths.dataRoot)
    // Seeded once at init, which is stale the moment a key is written while
    // this page is open — by the agent through its own settings, or by another
    // window. Re-read the disk whenever the row appears as well as after save.
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        ProviderCard {
            VStack(alignment: .leading, spacing: 12) {
                ProviderCardTitle(
                    title: "Jev (TypeSafe)",
                    line: "A second opinion on each turn: which tools to have ready, whether a tool call "
                        + "matches the request, whether a reply finished the job, and whether a memory "
                        + "about to be saved already exists. Every answer is a hint — nothing it says "
                        + "grants, denies or blocks anything."
                )
                HStack(spacing: 8) {
                    SecureField(
                        configured ? "A key is saved. Paste a new one to replace it." : "Paste the key here",
                        text: $draft
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(ProviderType.code)
                    Button("Save") { save(draft) }
                        .buttonStyle(.bordered)
                        .font(ShellType.labelMedium)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if configured {
                        Button("Remove") { save("") }
                            .buttonStyle(.bordered)
                            .font(ShellType.labelMedium)
                    }
                }
                if let failure {
                    ProviderNote(text: failure, color: NativeAgentShell.trouble)
                } else {
                    ProviderNote(
                        text: configured
                            ? "On. The checks run beside each turn and disappear on any error or timeout."
                            : "Off. Without a key every turn runs exactly as it does now."
                    )
                }
            }
        }
        .onAppear { refreshConfigured() }
    }

    private func refreshConfigured() {
        configured = JevSettings.isConfigured(dataRoot: NativeAgentPaths.dataRoot)
    }

    private func save(_ value: String) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            let root = NativeAgentPaths.dataRoot
            do {
                try await JevSettings.saveAPIKey(value, dataRoot: root)
                draft = ""
                failure = nil
            } catch {
                failure = "The key could not be saved: \(error.localizedDescription)"
            }
            // Read the disk back rather than assume: the row says "on" only
            // when a key is really resolvable under this root.
            refreshConfigured()
        }
    }
}
