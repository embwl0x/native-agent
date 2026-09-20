import SwiftUI
import ChatOrchestration
import PersistenceCore

/// The masked field writes only to Keychain, never via chat or a tool.
struct GrokSecureSetupCard: View {
    let dataRoot: URL
    @State private var contact: AgentPeerContact?
    @State private var paste = ""
    @State private var status = ""
    @State private var busy = false
    @State private var botName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let contact, ["creating", "secure-paste"].contains(contact.grokSetup ?? "") {
                if contact.grokConversation == nil {
                    Text("Connect briefly brings Grok Bot forward to send the routine request. If the current Bot cannot be identified, enter its exact sidebar name here, then Connect again.").font(.caption)
                    TextField("Bot name", text: $botName)
                    Button("Use this Bot") {
                        do {
                            let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            try AgentPeerStore(dataRoot: dataRoot).updateGrok(contact.id) { current in
                                guard current.grokConversation == nil else { throw GrokLinkCredential.Failure.invalid }
                                current.conversationLabel = name
                            }
                            status = "Bot selected. Connect again to send the routine request."
                        } catch { status = "Could not save the Bot selection." }
                    }.disabled(busy || botName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(contact.grokSetup == "creating" ? "Routine setup is not confirmed. Check Grok Bot for its approval or sign-in prompt; the request will not be resent." : GrokBotRoute.securePasteBlocker).font(.caption)
                Button("Read routine securely") { importNative(contact) }.disabled(busy)
                if contact.grokSetup == "secure-paste" {
                    SecureField("Paste {\"url\":\"…\",\"key\":\"…\"}", text: $paste)
                        .textFieldStyle(.roundedBorder).privacySensitive()
                        .onChange(of: paste) { _, value in
                            if value.utf8.count > 16_384 { paste = ""; status = "Paste exceeds the secure field limit." }
                        }
                    Button("Save securely to Keychain") { save(contact) }.disabled(paste.isEmpty || busy)
                }
            }
            if !status.isEmpty { Text(status).font(.caption) }
        }
        .task {
            let events = FileChangeEvents(paths: [AgentPeerStore(dataRoot: dataRoot).fileURL], emitInitial: true)
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    if Task.isCancelled { break }
                    contact = try? AgentPeerStore(dataRoot: dataRoot).list().first { $0.transport == .grokBot && $0.grokSetup != "disconnected" }
                }
            } onCancel: { events.cancel() }
        }
        .onDisappear { paste = "" }
    }
    private func save(_ contact: AgentPeerContact) {
        defer { paste = "" }
        do {
            guard paste.utf8.count <= 16_384, let data = paste.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  Set(object.keys) == ["url", "key"], let url = object["url"], let key = object["key"] else {
                status = "Paste one JSON object with url and key. Nothing was saved."; return
            }
            let store = AgentPeerStore(dataRoot: dataRoot)
            try store.updateGrok(contact.id) { current in
                guard current.grokSetup == "secure-paste" else { throw GrokLinkCredential.Failure.invalid }
                var credential = try GrokLinkCredential.read(peer: contact.id)
                try credential.importWebhook(url: url, key: key)
                try credential.write(peer: contact.id)
                current.grokSetup = "set up"
                current.grokBootstrapConfirmed = true
            }
            ready()
        } catch { status = "Could not save the routine credentials securely. Nothing was sent." }
    }
    private func importNative(_ contact: AgentPeerContact) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let current = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == contact.id }),
                      ["creating", "secure-paste"].contains(current.grokSetup ?? "") else { return }
                try await DesktopAgentConversationRoute.shared.importGrokRoutine(peer: contact.id, dataRoot: dataRoot)
                ready()
            } catch {
                try? AgentPeerStore(dataRoot: dataRoot).updateGrok(contact.id) { $0.grokSetup = "secure-paste" }
                status = (error as? GrokRoutineAccessibility.Blocker)?.rawValue ?? "The credentials could not be imported securely."
            }
        }
    }
    private func ready() {
        status = "Set up. Credentials are in Keychain. Send a test message; approve the local reply command in Grok Bot if asked."
    }
}
