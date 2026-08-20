import Foundation
import Observation
import SwiftUI

/// A rebuildable, view-local projection over the transcript already loaded by
/// AppModel. JSONL remains authoritative: this type writes no sidecar index and
/// owns no session lifecycle.
struct MacChatTranscriptSearchDocument: Sendable, Equatable {
    let messageID: String
    let ordinal: Int
    let content: String
}

struct MacChatTranscriptSearchResult: Identifiable, Sendable, Equatable {
    let messageID: String
    let ordinal: Int

    var id: String { "\(ordinal):\(messageID)" }
}

struct MacChatTranscriptSearchResponse: Sendable, Equatable {
    let query: String
    let results: [MacChatTranscriptSearchResult]
    let totalMatchCount: Int

    var isTruncated: Bool { totalMatchCount > results.count }
}

enum MacChatTranscriptSearch {
    /// Query work is bounded before Foundation normalization or comparison.
    static let maximumQueryScalars = 256
    /// Huge repetitive histories remain searchable without retaining an
    /// unbounded navigation array. The exact total is still reported.
    static let maximumNavigableResults = 2_000

    static func documents(from messages: [ChatMessage]) -> [MacChatTranscriptSearchDocument] {
        messages.enumerated().compactMap { ordinal, message in
            document(from: message, ordinal: ordinal)
        }
    }

    static func document(from message: ChatMessage, ordinal: Int) -> MacChatTranscriptSearchDocument? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role != "tool" else { return nil }
        guard !(role == "system" && message.content.hasPrefix("[tool:")) else { return nil }
        guard !message.content.isEmpty else { return nil }
        return MacChatTranscriptSearchDocument(
            messageID: message.id,
            ordinal: ordinal,
            content: message.content
        )
    }

    static func boundedInput(_ raw: String) -> String {
        var bounded = ""
        bounded.reserveCapacity(maximumQueryScalars * 2)
        for scalar in raw.unicodeScalars.prefix(maximumQueryScalars) {
            bounded.unicodeScalars.append(scalar)
        }
        return bounded
    }

    static func boundedQuery(_ raw: String) -> String {
        let bounded = boundedInput(raw)
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func search(
        query rawQuery: String,
        documents: [MacChatTranscriptSearchDocument],
        maximumResults: Int = maximumNavigableResults
    ) -> MacChatTranscriptSearchResponse {
        searchCancellable(
            query: rawQuery,
            documents: documents,
            maximumResults: maximumResults,
            shouldCancel: { false }
        ) ?? MacChatTranscriptSearchResponse(query: boundedQuery(rawQuery), results: [], totalMatchCount: 0)
    }

    /// The controller uses this form so a superseded query stops consuming CPU
    /// instead of leaving an unstructured full-history scan behind it.
    static func searchCancellable(
        query rawQuery: String,
        documents: [MacChatTranscriptSearchDocument],
        maximumResults: Int = maximumNavigableResults,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> MacChatTranscriptSearchResponse? {
        let query = boundedQuery(rawQuery)
        guard !query.isEmpty, maximumResults > 0 else {
            return MacChatTranscriptSearchResponse(query: query, results: [], totalMatchCount: 0)
        }

        var newestFirst: [MacChatTranscriptSearchResult] = []
        newestFirst.reserveCapacity(min(maximumResults, documents.count))
        var totalMatchCount = 0
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")

        // Retain the newest bounded results, which are the useful ones in a
        // conversation, but continue the scan so the total remains exact.
        for (scanIndex, document) in documents.reversed().enumerated() {
            if scanIndex.isMultiple(of: 64), shouldCancel() { return nil }
            guard document.content.range(of: query, options: options, locale: locale) != nil else {
                continue
            }
            totalMatchCount += 1
            if newestFirst.count < maximumResults {
                newestFirst.append(MacChatTranscriptSearchResult(
                    messageID: document.messageID,
                    ordinal: document.ordinal
                ))
            }
        }

        return MacChatTranscriptSearchResponse(
            query: query,
            results: newestFirst.reversed(),
            totalMatchCount: totalMatchCount
        )
    }

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
    @ObservationIgnored private var sourceSessionID = ""
    @ObservationIgnored private var searchGeneration: UInt = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var selectedMessageID: String? {
        guard let selectedIndex = cursor.selectedIndex, results.indices.contains(selectedIndex) else {
            return nil
        }
        return results[selectedIndex].messageID
    }

    var canNavigate: Bool { phase == .results && !results.isEmpty }

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

    func replaceSource(messages: [ChatMessage], sessionID: String) {
        if sourceSessionID != sessionID {
            reset(for: sessionID)
        }
        documents = MacChatTranscriptSearch.documents(from: messages)
        scheduleSearch(preserving: selectedMessageID)
    }

    /// Streaming changes only the last row. Updating that projection in O(1)
    /// avoids rebuilding a long transcript on every token batch; appends,
    /// removals, compaction, and session changes still use `replaceSource`.
    func replaceLastMessage(_ message: ChatMessage?, ordinal: Int, sessionID: String) {
        guard sourceSessionID == sessionID else { return }
        let previousSelection = selectedMessageID
        let previousDocument = documents.last?.ordinal == ordinal ? documents.last : nil
        let replacement = message.flatMap { MacChatTranscriptSearch.document(from: $0, ordinal: ordinal) }
        guard previousDocument != replacement else { return }

        if previousDocument != nil { documents.removeLast() }
        if let replacement { documents.append(replacement) }
        scheduleSearch(preserving: previousSelection)
    }

    func setQuery(_ newValue: String) {
        let boundedInput = MacChatTranscriptSearch.boundedInput(newValue)
        guard query != boundedInput else { return }
        query = boundedInput
        results = []
        totalMatchCount = 0
        cursor = MacChatTranscriptSearchCursor(resultCount: 0)
        scheduleSearch(preserving: nil)
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

    func reset(for sessionID: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        sourceSessionID = sessionID
        documents = []
        query = ""
        phase = .idle
        results = []
        totalMatchCount = 0
        cursor = MacChatTranscriptSearchCursor(resultCount: 0)
    }

    private func scheduleSearch(preserving preferredMessageID: String?) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let rawQuery = query
        let currentDocuments = documents
        let bounded = MacChatTranscriptSearch.boundedQuery(rawQuery)

        guard !bounded.isEmpty else {
            phase = .idle
            results = []
            totalMatchCount = 0
            cursor = MacChatTranscriptSearchCursor(resultCount: 0)
            return
        }

        phase = .searching
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                MacChatTranscriptSearch.searchCancellable(
                    query: rawQuery,
                    documents: currentDocuments
                )
            }
            let response = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let response,
                  let self,
                  generation == self.searchGeneration
            else { return }
            self.apply(response, preserving: preferredMessageID)
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
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                "Search conversation",
                text: Binding(
                    get: { controller.query },
                    set: { controller.setQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .onSubmit { _ = controller.selectNext() }
            .accessibilityLabel("Search conversation")

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
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { searchFocused = true }
        .onChange(of: focusRequest) { _, _ in searchFocused = true }
        .onExitCommand(perform: onDismiss)
    }
}
