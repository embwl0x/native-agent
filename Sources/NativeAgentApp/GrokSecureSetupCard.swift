import GrokLink
import SwiftUI
import Agents
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
                Text("Routine credentials").font(.headline)
                if contact.grokConversation == nil {
                    Text("Connect briefly brings Grok Bot forward to send the routine request. If the current Bot cannot be identified, enter its exact sidebar name here, then Connect again.").font(.caption)
                    TextField("Bot name", text: $botName)
                    Button("Use this Bot") {
                        do {
                            let name = botName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            try GrokBotConnection.selectBot(peer: contact.id, name: name, dataRoot: dataRoot)
                            status = "Bot selected. Connect again to send the routine request."
                        } catch { status = "Could not save the Bot selection." }
                    }.disabled(busy || botName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(contact.grokSetup == "creating" ? "Routine setup is not confirmed. Check Grok Bot for its approval or sign-in prompt; the request will not be resent. Paste the URL and key together at Agents → Grok Bot → Routine credentials; never in chat." : GrokBotRoute.securePasteBlocker).font(.caption)
                Button("Read routine securely") { importNative(contact) }.disabled(busy)
                SecureField("Paste {\"url\":\"…\",\"key\":\"…\"}", text: $paste)
                    .textFieldStyle(.roundedBorder).privacySensitive()
                    .onChange(of: paste) { _, value in
                        if value.utf8.count > 16_384 { paste = ""; status = "Paste exceeds the secure field limit." }
                    }
                Button("Save securely to Keychain") { save(contact) }.disabled(paste.isEmpty || busy)
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
            guard try GrokBotConnection.saveSecureCredentials(peer: contact.id, paste: paste, dataRoot: dataRoot) else {
                status = "Paste one JSON object with url and key. Nothing was saved."; return
            }
            ready()
        } catch { status = "Could not save the routine credentials securely. Nothing was sent." }
    }
    private func importNative(_ contact: AgentPeerContact) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                guard try await GrokBotConnection.importSecureCredentials(peer: contact.id, dataRoot: dataRoot,
                    desktop: NativeAgentEngine.live.agents.desktop) else { return }
                ready()
            } catch {
                status = (error as? GrokRoutineAccessibility.Blocker)?.rawValue ?? "The credentials could not be imported securely."
            }
        }
    }
    private func ready() {
        status = "Set up. Credentials are in Keychain. Send a test message; approve the local reply command in Grok Bot if asked."
    }
}
