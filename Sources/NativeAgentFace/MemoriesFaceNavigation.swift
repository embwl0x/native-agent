import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `MemoriesFaceNavigation.swift` | Memory and helper document demands; existing correction/Forget controls and local graph/upkeep destinations |

@MainActor
struct MemoriesFaceNavigation: ViewModifier {
    var initialQuery: String?
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var offscreen
    @Environment(\.quietRailTab) private var drawnTab
    @AppStorage(ShellRailTab.storageKey(.memories)) private var tab = "memories"
    @State private var target: FaceDestination?
    @State private var document: DocumentRequest?
    @State private var showing = false

    static let tabs = [ShellTab(key: "memories", title: "Memories"), ShellTab(key: "knowledge", title: "Knowledge graph")]

    func body(content: Content) -> some View {
        Group {
            if offscreen, drawnTab == "knowledge" { KnowledgeGraphView() } else { content }
        }
        .sheet(isPresented: $showing, onDismiss: { tab = "memories"; target = nil; document = nil }) { destination }
        .onChange(of: tab, initial: true) { _, value in
            guard !offscreen, value == "knowledge" else { return }
            open(FaceDestination(page: "memories", item: "graph", session: nil, message: nil))
        }
        .onChange(of: appModel.pendingMemoryFaceTarget, initial: true) { _, value in
            guard !offscreen, let value else { return }
            appModel.pendingMemoryFaceTarget = nil
            open(value)
        }
        .onChange(of: appModel.pendingPaletteDestination, initial: true) { _, value in
            guard !offscreen, case .memory(let id)? = value else { return }
            appModel.pendingPaletteDestination = nil
            open(FaceDestination(page: "memories", item: "memory:" + id, session: nil, message: nil))
        }
        .task {
            guard !offscreen, let initialQuery else { return }
            do { _ = try await appModel.client.act(.searchMemories(query: initialQuery)).checkedValue() }
            catch { appModel.systemToasts.push(error: error.localizedDescription) }
        }
    }

    @ViewBuilder private var destination: some View {
        switch target?.item {
        case "graph":
            VStack(alignment: .trailing) {
                Button("Done") { showing = false }.keyboardShortcut(.cancelAction)
                KnowledgeGraphView()
            }.padding(20).frame(width: 960, height: 720)
        case "upkeep":
            VStack(alignment: .trailing) {
                Button("Done") { showing = false }.keyboardShortcut(.cancelAction)
                ScrollView { MemoryUpkeepPanel().padding() }
            }.padding(20).frame(width: 720, height: 620)
        default:
            if let document { FaceDocumentReadout(request: document) }
            else { Text("The selected memory destination is unavailable.").padding(20) }
        }
    }

    private func open(_ value: FaceDestination) {
        target = value
        document = nil
        if let item = value.item {
            if item.hasPrefix("memory:"), item.count > "memory:".count {
                document = DocumentRequest(id: UUID(), subject: .memory(id: String(item.dropFirst("memory:".count)), rejected: false))
            } else if item.hasPrefix("rejected:"), item.count > "rejected:".count {
                document = DocumentRequest(id: UUID(), subject: .memory(id: String(item.dropFirst("rejected:".count)), rejected: true))
            }
        }
        showing = true
    }
}

struct FaceDocumentReadout: View {
    let request: DocumentRequest
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var confirmingForget = false
    @State private var forgetting = false
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Document").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            FaceDocumentReader(identity: request.id, presentation: { _ in
                let answer = try await appModel.documentPresentation(request.subject)
                try Task.checkCancellation()
                text = answer.text
                return answer
            })
            if let text {
                if case .memory(let id, rejected: false) = request.subject {
                    HStack {
                        Button("Correct this") { correct(id: id, text: text) }
                        Spacer()
                        Button("Forget…", role: .destructive) { confirmingForget = true }.disabled(forgetting)
                    }
                }
            }
        }
        .padding(20).frame(width: 560, height: 420)
        .confirmationDialog("Forget this memory?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { forget() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func forget() {
        guard case .memory(let id, rejected: false) = request.subject, !forgetting else { return }
        forgetting = true
        Task {
            defer { forgetting = false }
            do {
                try await appModel.client.act(.forgetMemory(id: id)).checkedAcknowledgement()
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }

    private func correct(id: String, text: String) {
        dismiss()
        let draft = """
            Correct what you remember. The memory (id \(id)) says:

            "\(text)"

            What's actually true:
            """
        NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
    }
}
