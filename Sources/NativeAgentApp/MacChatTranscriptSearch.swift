import Foundation
import Observation
import SwiftUI
import ChatSessionWork
import NativeAgentCore
// Blueprint: | `MacChatTranscriptSearch.swift` | `MacChatTranscriptSearch` alias to `ChatSessionWork.TranscriptSearch`; `MacChatTranscriptSearchCursor`, `MacChatTranscriptSearchController`, `MacChatTranscriptSearchBar`; source preparation and search results publish through `LatestRead`, with input revisions retained only for coalescing; `TranscriptSearch.scrollTargetID` |

typealias MacChatTranscriptSearchDocument = TranscriptSearchDocument
typealias MacChatTranscriptSearchResult = TranscriptSearchResult
typealias MacChatTranscriptSearchResponse = TranscriptSearchResponse
typealias MacChatTranscriptSearch = TranscriptSearch

extension TranscriptSearch {
    static func scrollTargetID(for messageID: String) -> String {
        "chat-message-\(messageID)"
    }
}

struct MacChatTranscriptSearchCursor: Sendable, Equatable {
    private(set) var selectedIndex: Int?

    init(resultCount: Int) {
        selectedIndex = resultCount > 0 ? resultCount - 1 : nil
    }

    mutating func selectNext(resultCount: Int) -> Int? {
        guard resultCount > 0 else {
            selectedIndex = nil
            return nil
        }
        selectedIndex = ((selectedIndex ?? -1) + 1) % resultCount
        return selectedIndex
    }

    mutating func selectPrevious(resultCount: Int) -> Int? {
        guard resultCount > 0 else {
            selectedIndex = nil
            return nil
        }
        selectedIndex = ((selectedIndex ?? resultCount) - 1 + resultCount) % resultCount
        return selectedIndex
    }
}

@MainActor
@Observable
final class MacChatTranscriptSearchController {
    enum Phase: Equatable {
        case idle
        case searching
        case noResults
        case results
    }

    var query = ""
    private(set) var phase: Phase = .idle
    private(set) var results: [MacChatTranscriptSearchResult] = []
    private(set) var totalMatchCount = 0
    private(set) var cursor = MacChatTranscriptSearchCursor(resultCount: 0)
    /// Parents observe this value from inside their ScrollViewReader. It changes
    /// only when a current, existing result should become the navigation target.
    private(set) var selectionRevision: UInt = 0

    @ObservationIgnored private var documents: [MacChatTranscriptSearchDocument] = []
    @ObservationIgnored private var sourceMessages: [ChatMessage] = []
    @ObservationIgnored private var structureVersion: UInt64?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private let sourceRead = LatestRead()
    @ObservationIgnored private var sourceSessionID = ""
    @ObservationIgnored private var sourceRevision: UInt = 0
    @ObservationIgnored private let searchRead = LatestRead()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    typealias SearchOperation = @Sendable (String, [MacChatTranscriptSearchDocument]) async -> MacChatTranscriptSearchResponse?
    @ObservationIgnored private let search: SearchOperation

    init(search: @escaping SearchOperation = MacChatTranscriptSearchController.searchOffMainActor) {
        self.search = search
    }

    var selectedMessageID: String? {
        guard let selectedIndex = cursor.selectedIndex, results.indices.contains(selectedIndex) else {
            return nil
        }
        return results[selectedIndex].messageID
    }

    // Same-query results remain useful while a newer transcript snapshot scans.
    // A query/session change clears them before starting its own search.
    var canNavigate: Bool { !results.isEmpty }

    var statusText: String {
        switch phase {
        case .idle:
            return "Type to search"
        case .searching:
            return "Searching…"
        case .noResults:
            return "No matches"
        case .results:
            guard let selectedIndex = cursor.selectedIndex else { return "No matches" }
            if totalMatchCount > results.count {
                return "\(selectedIndex + 1) of \(results.count) recent · \(totalMatchCount) messages"
            }
            return "\(selectedIndex + 1) of \(results.count) messages"
        }
    }

    func replaceSource(messages: [ChatMessage], sessionID: String, revision: UInt64) {
        if sourceSessionID != sessionID {
            reset(for: sessionID)
        }
        guard structureVersion != revision else { return }
        structureVersion = revision
        sourceMessages = messages
        sourceTask?.cancel()
        sourceTask = Task {
            _ = await sourceRead.read({
            var prepared = await Task.detached(priority: .userInitiated) {
                MacChatTranscriptSearch.documents(from: messages)
            }.value
            // A token can arrive while the structure is being prepared.
            let ordinal = sourceMessages.count - 1
            if prepared.last?.ordinal == ordinal { prepared.removeLast() }
            if let tail = sourceMessages.last,
               let document = MacChatTranscriptSearch.document(from: tail, ordinal: ordinal) {
                prepared.append(document)
            }
            return prepared
            }, publish: { prepared in
            documents = prepared
            sourceTask = nil
            sourceRevision &+= 1
            if !query.isEmpty || phase != .results { scheduleSearch() }
            })
        }
    }

    /// Streaming changes only the last row. Updating that projection in O(1)
    /// avoids rebuilding a long transcript on every token batch; appends,
    /// removals, compaction, and session changes still use `replaceSource`.
    func replaceLastMessage(_ message: ChatMessage?, ordinal: Int, sessionID: String) {
        guard sourceSessionID == sessionID else { return }
        if let message, sourceMessages.indices.contains(ordinal) { sourceMessages[ordinal] = message }
        guard sourceTask == nil else { return }
        let previousDocument = documents.last?.ordinal == ordinal ? documents.last : nil
        let replacement = message.flatMap { MacChatTranscriptSearch.document(from: $0, ordinal: ordinal) }
        guard previousDocument != replacement else { return }

        if previousDocument != nil { documents.removeLast() }
        if let replacement { documents.append(replacement) }
        sourceRevision &+= 1
        scheduleSearch()
    }

    func setQuery(_ newValue: String) {
        let boundedInput = MacChatTranscriptSearch.boundedInput(newValue)
        guard query != boundedInput else { return }
        query = boundedInput
        results = []
        totalMatchCount = 0
        cursor = MacChatTranscriptSearchCursor(resultCount: 0)
        scheduleSearch(restarting: true)
    }

    @discardableResult
    func selectNext() -> String? {
        guard let selectedIndex = cursor.selectNext(resultCount: results.count) else { return nil }
        selectionRevision &+= 1
        return results[selectedIndex].messageID
    }

    @discardableResult
    func selectPrevious() -> String? {
        guard let selectedIndex = cursor.selectPrevious(resultCount: results.count) else { return nil }
        selectionRevision &+= 1
        return results[selectedIndex].messageID
    }

    /// Select one message by id as a search result is selected, so the
    /// transcript pages to it and scrolls there. False when it is not here.
    @discardableResult
    func reveal(messageID: String) -> Bool {
        guard let ordinal = sourceMessages.firstIndex(where: { $0.id == messageID }),
              let document = MacChatTranscriptSearch.document(from: sourceMessages[ordinal], ordinal: ordinal) else { return false }
        setQuery("")
        results = [MacChatTranscriptSearchResult(messageID: messageID, ordinal: document.ordinal)]
        totalMatchCount = 1
        cursor = MacChatTranscriptSearchCursor(resultCount: 1)
        phase = .results
        selectionRevision &+= 1
        return true
    }

    func reset(for sessionID: String) {
        searchTask?.cancel()
        sourceTask?.cancel()
        sourceTask = nil
        sourceRead.write {}
        structureVersion = nil
        sourceMessages = []
        searchTask = nil
        searchRead.write {}
        sourceRevision &+= 1
        sourceSessionID = sessionID
        documents = []
        query = ""
        phase = .idle
        results = []
        totalMatchCount = 0
        cursor = MacChatTranscriptSearchCursor(resultCount: 0)
    }

    private func scheduleSearch(restarting: Bool = false) {
        if restarting {
            searchTask?.cancel()
            searchTask = nil
            searchRead.write {}
        }
        let bounded = MacChatTranscriptSearch.boundedQuery(query)

        guard !bounded.isEmpty else {
            phase = .idle
            results = []
            totalMatchCount = 0
            cursor = MacChatTranscriptSearchCursor(resultCount: 0)
            return
        }

        // Source updates coalesce into the active pass instead of restarting
        // its deadline on every token. Only a changed query restarts debounce.
        guard searchTask == nil else { return }
        let rawQuery = query
        phase = .searching
        searchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self else { return }
                let revision = self.sourceRevision
                let response = await self.searchRead.read({ await self.search(rawQuery, self.documents) }, publish: { response in
                    if let response { self.apply(response, preserving: self.selectedMessageID) }
                })
                guard !Task.isCancelled else { return }
                guard response != nil else {
                    self.searchTask = nil
                    return
                }
                // The reader may have navigated during the scan. Anchor to
                // that latest selection, not the one at refresh submission.
                guard revision != self.sourceRevision else {
                    self.searchTask = nil
                    return
                }
                // A mutation during this scan queues one more sequential pass.
                // Mutations during that pass can queue another; no finite tail
                // is lost and scans never overlap within a query.
            }
        }
    }

    nonisolated private static func searchOffMainActor(
        query: String,
        documents: [MacChatTranscriptSearchDocument]
    ) async -> MacChatTranscriptSearchResponse? {
        let worker = Task.detached(priority: .userInitiated) {
            MacChatTranscriptSearch.searchCancellable(query: query, documents: documents)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func apply(
        _ response: MacChatTranscriptSearchResponse,
        preserving preferredMessageID: String?
    ) {
        let previousSelection = selectedMessageID
        results = response.results
        totalMatchCount = response.totalMatchCount
        guard !results.isEmpty else {
            cursor = MacChatTranscriptSearchCursor(resultCount: 0)
            phase = .noResults
            return
        }

        var nextCursor = MacChatTranscriptSearchCursor(resultCount: results.count)
        if let preferredMessageID,
           let preservedIndex = results.firstIndex(where: { $0.messageID == preferredMessageID }) {
            nextCursor = MacChatTranscriptSearchCursor(resultCount: 0)
            for _ in 0...preservedIndex {
                _ = nextCursor.selectNext(resultCount: results.count)
            }
        }
        cursor = nextCursor
        phase = .results
        if selectedMessageID != previousSelection || previousSelection == nil {
            selectionRevision &+= 1
        }
    }
}

struct MacChatTranscriptSearchBar: View {
    @Bindable var controller: MacChatTranscriptSearchController
    let focusRequest: UInt
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            // The Mac's own search field (User 09-27: all controls native).
            NativeSearchField(
                text: Binding(get: { controller.query }, set: { controller.setQuery($0) }),
                prompt: "Search conversation",
                identifier: "chat.transcript.search",
                accessibilityLabel: "Search conversation",
                onSubmit: { _ = controller.selectNext() },
                onEscape: onDismiss,
                focusRequest: focusRequest
            )

            Text(controller.statusText)
                .font(NativeAgentFont.tag)
                .foregroundStyle(controller.phase == .noResults ? Color.orange : Color.secondary)
                .lineLimit(1)
                .accessibilityLabel("Search status: \(controller.statusText)")
                .accessibilityAddTraits(.updatesFrequently)

            Button { _ = controller.selectPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canNavigate)
            .help("Previous match (Shift-Command-G)")
            .accessibilityLabel("Previous search match")

            Button { _ = controller.selectNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canNavigate)
            .help("Next match (Command-G)")
            .accessibilityLabel("Next search match")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close transcript search")
            .accessibilityLabel("Close transcript search")
        }
        .padding(.horizontal, NativeAgentSpacing.md)
        .padding(.vertical, NativeAgentSpacing.sm)
        .houseSurface(in: Rectangle())
        .onExitCommand(perform: onDismiss)
    }
}
