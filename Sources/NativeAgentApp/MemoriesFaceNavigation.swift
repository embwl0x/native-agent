import EngineRuntime
import Foundation
import MemoryV2
import NativeAgentShared
import PersistenceCore
import SwiftUI
// Blueprint: | `MemoriesFaceNavigation.swift` | Memory face links to native graph, full text/correction and upkeep |

/// The page is FacePageView. These are its native destinations, not another memory list or write owner.
@MainActor struct MemoriesFaceNavigation: ViewModifier {
    var initialQuery: String?
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.quietRailTab) private var quietRailTab
    @AppStorage(ShellRailTab.storageKey(.memories)) private var tab = "memories"
    @State private var target: MemoriesFaceTarget?
    @State private var showing = false
    @State private var fullText: String?
    @State private var failure: String?
    @State private var selectionRead = LatestRead()

    static let tabs = [ShellTab(key: "memories", title: "Memories"), ShellTab(key: "knowledge", title: "Knowledge graph")]

    func body(content: Content) -> some View {
        Group {
            if quietOffscreenRead, quietRailTab == "knowledge" {
                KnowledgeGraphView()
            } else { content }
        }
        .sheet(isPresented: $showing, onDismiss: {
            tab = "memories"
            selectionRead.write { target = nil; fullText = nil; failure = nil }
        }) { destination }
        .task(id: target) { await readTarget() }
        .onChange(of: tab, initial: true) { _, value in
            guard !quietOffscreenRead else { return }
            if value == "knowledge" { open(.graph) }
        }
        .onChange(of: appModel.pendingMemoryFaceTarget, initial: true) { _, value in
            guard !quietOffscreenRead, let value else { return }
            appModel.pendingMemoryFaceTarget = nil
            open(value)
        }
        .onChange(of: appModel.pendingPaletteDestination, initial: true) { _, value in
            guard !quietOffscreenRead, case .memory(let id)? = value else { return }
            appModel.pendingPaletteDestination = nil
            open(.memory(id))
        }
        .quietReadTask(live: false) { await appModel.engine.pages.refresh(page: "memories") }
        .task {
            guard !quietOffscreenRead, let initialQuery else { return }
            await appModel.engine.memory.search(query: initialQuery)
            await appModel.engine.pages.refresh(page: "memories")
        }
    }

    @ViewBuilder private var destination: some View {
        switch target {
        case .graph:
            VStack(alignment: .trailing) {
                Button("Done") { showing = false }.keyboardShortcut(.cancelAction)
                KnowledgeGraphView()
            }.padding(20).frame(width: 960, height: 720)
        case .upkeep:
            VStack(alignment: .trailing) {
                Button("Done") { showing = false }.keyboardShortcut(.cancelAction)
                ScrollView { MemoryUpkeepPanel().padding() }
            }.padding(20).frame(width: 720, height: 620)
        case .memory(let id):
            if let fullText {
                MemoryFullTextView(text: fullText, onCorrect: { correct(id: id, text: fullText) })
            } else { reading }
        case .rejected:
            if let fullText { MemoryFullTextView(text: fullText) }
            else { reading }
        case nil: EmptyView()
        }
    }

    private var reading: some View {
        VStack(spacing: 16) {
            if let failure { Text(failure).textSelection(.enabled) }
            else { ProgressView("Reading the selected memory…") }
            Button("Done") { showing = false }.keyboardShortcut(.cancelAction)
        }.padding(20).frame(width: 560, height: 420)
    }

    private func open(_ value: MemoriesFaceTarget) {
        guard !showing || target != value else { return }
        selectionRead.write { fullText = nil; failure = nil; target = value }
        showing = true
    }

    private func readTarget() async {
        guard let selected = target else { return }
        switch selected {
        case .graph, .upkeep: return
        case .memory, .rejected: break
        }
        _ = await selectionRead.read({ () async -> Result<String, Error> in
            do {
                let text: String?
                switch selected {
                case .memory(let id):
                    text = try await appModel.engine.memory.activeMemories(limit: nil).first { $0.id == id }?.text
                case .rejected(let id):
                    text = try await appModel.engine.memory.proposals(status: "rejected").first { $0.id == id }?.content
                case .graph, .upkeep: return .failure(CancellationError())
                }
                guard let text else {
                    throw PartCallError(code: "memory_unavailable", message: "The selected memory is unavailable in the current store.")
                }
                try Task.checkCancellation()
                return .success(text)
            } catch { return .failure(error) }
        }, publish: { result in
            guard !Task.isCancelled, target == selected else { return }
            switch result {
            case .success(let text): fullText = text; failure = nil
            case .failure(let error): fullText = nil; failure = error.localizedDescription
            }
        })
    }

    private func correct(id: String, text: String) {
        showing = false
        let draft = """
            Correct what you remember. The memory (id \(id)) says:

            "\(text)"

            What's actually true:
            """
        NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
    }
}
