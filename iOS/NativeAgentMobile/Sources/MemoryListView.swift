import SwiftUI
import NativeAgentShared
import CloudKit
// Blueprint: | `MemoryListView.swift` | Local memory search, result rows and deletion confirmation |

// MARK: - Memories list

/// Local filtering searches only memory rows already synced to the phone.
enum MemorySearchPresentation {
    /// Empty means "no filter", never "no rows". Whitespace is not a query.
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Why the list is empty. A filtered-to-nothing list must never borrow the
    /// "waiting for iCloud" copy — that would blame the sync for the query.
    enum EmptyState: Equatable {
        case noSyncedMemories
        case noMatches(String)
    }

    static func emptyState(visibleCount: Int, syncedCount: Int, query: String) -> EmptyState? {
        guard visibleCount == 0 else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, syncedCount > 0 { return .noMatches(trimmed) }
        return .noSyncedMemories
    }
}

struct MemoryListView: View {
    @ObservedObject var store: MemoryStore
    var searchQuery: String = ""
    var header: AnyView = AnyView(EmptyView())
    @State private var pendingDeleteMemory: MemoryRecord?
    @State private var searchIndex = MobileSearchIndex<MemoryRecord>()
    @State private var searchResults: [MemoryRecord] = []

    private var isSample: Bool { MemorySamples.isOn }

    private var sourceMemories: [MemoryRecord] {
        isSample ? MemorySamples.memories : store.memories
    }

    private var visibleMemories: [MemoryRecord] {
        MemorySearchPresentation.normalizedQuery(searchQuery).isEmpty ? sourceMemories : searchResults
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteMemory != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteMemory = nil }
            }
        )
    }

    var body: some View {
        let visibleMemories = visibleMemories
        return ScrollViewReader { proxy in
        List {
            header.aliveListRow(top: 0, bottom: 10)
            if let emptyState = MemorySearchPresentation.emptyState(
                visibleCount: visibleMemories.count,
                syncedCount: sourceMemories.count,
                query: searchQuery
            ) {
                switch emptyState {
                case .noSyncedMemories:
                    AliveCalmState(
                        title: "Nothing here yet.",
                        line: "What I learn with you on the Mac arrives here once iCloud syncs."
                    )
                    .aliveListRow()
                case .noMatches(let query):
                    AliveCalmState(
                        title: "Nothing matches \u{201c}\(query)\u{201d}.",
                        line: "I only search the memories already on this iPhone."
                    )
                    .aliveListRow()
                }
            } else {
                ForEach(visibleMemories) { memory in
                    let isDeleting = store.deletingMemoryIDs.contains(memory.id)
                    MemoryCard(memory: memory, isDeleting: isDeleting)
                        .id(memory.id)
                        .aliveListRow(top: 5, bottom: 5)
                        .swipeActions(edge: .trailing) {
                            Button(
                                role: ButtonRole.destructive,
                                action: { pendingDeleteMemory = memory },
                                label: { Label("Delete", systemImage: "trash") }
                            )
                            .disabled(isDeleting || isSample)
                        }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            #if DEBUG
            if isSample, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-memorySampleRow"),
               ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
                proxy.scrollTo(ProcessInfo.processInfo.arguments[i + 1], anchor: .top)
            }
            // Account status can arrive after the first layout. Reposition the
            // fixture after the status changes the actual list viewport.
            if isSample && ProcessInfo.processInfo.arguments.contains("-memorySampleEnd"), let last = visibleMemories.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            if isSample, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-memorySampleRow"),
               ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
                proxy.scrollTo(ProcessInfo.processInfo.arguments[i + 1], anchor: .top)
            }
            if isSample && ProcessInfo.processInfo.arguments.contains("-memorySampleEnd"), let last = visibleMemories.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            #endif
        }
        .task(id: MobileSearchInput(rows: sourceMemories, query: searchQuery)) {
            let input = MobileSearchInput(rows: sourceMemories, query: MemorySearchPresentation.normalizedQuery(searchQuery))
            let result = await searchIndex.search(input, maximum: input.rows.count,
                fields: { [$0.text.lowercased(), $0.layer.lowercased()] + ($0.tags ?? []).map { $0.lowercased() } },
                matches: { $0.contains($1) })
            guard !Task.isCancelled else { return }
            searchResults = result
        }
        .confirmationDialog(
            "Delete memory?",
            isPresented: isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let memory = pendingDeleteMemory {
                Button("Delete Memory", role: .destructive) {
                    store.deleteMemory(memory)
                }
            }
        } message: {
            if let memory = pendingDeleteMemory {
                Text(MemoryDeleteConfirmationPresentation.message(for: memory))
            }
        }
        }
    }
}

/// One memory, as I would say it: the words first and large, what kind of
/// thing it is and its tags as quiet small words under it.
private struct MemoryCard: View {
    let memory: MemoryRecord
    let isDeleting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(memory.text)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(AlivePalette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MemoryWords.meta(kind: MemoryWords.kind(memory.layer),
                                      pinned: memory.pinned == true,
                                      importance: memory.importance,
                                      extra: memory.tags ?? []))
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isDeleting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard()
        .accessibilityElement(children: .combine)
    }
}

enum MemoryDeleteConfirmationPresentation {
    static func message(for memory: MemoryRecord) -> String {
        "Delete \u{201c}\(memory.text)\u{201d} from durable memory? This writes a tombstone so it does not come back."
    }
}
