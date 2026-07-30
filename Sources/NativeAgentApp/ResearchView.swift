import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

struct ResearchView: View {
    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var state: ResearchViewState = .idle
    @State private var showingSearchConfiguration = false
    @State private var savingSearchConfiguration = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        if case .loading = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Search service", isExpanded: $showingSearchConfiguration) {
                HStack {
                    TextField("SearXNG URL", text: Bindable(appModel).searxngBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Find", systemImage: "magnifyingglass") {
                        Task { await appModel.autodetectSearXNG() }
                    }
                    .disabled(savingSearchConfiguration)
                    Button("Save", systemImage: "checkmark.circle") {
                        saveSearchConfiguration()
                    }
                    .disabled(
                        savingSearchConfiguration
                            || appModel.searxngBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                Text(appModel.searxngBaseURL.isEmpty ? "No search service configured." : appModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                TextField("Research query", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                Button(action: runSearch) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .disabled(trimmedQuery.isEmpty || isSearching)
            }

            switch state {
            case .idle:
                NativeEmptyState(
                    title: "Research results",
                    detail: "No search has run in this view.",
                    systemImage: "doc.text.magnifyingglass"
                )
            case .loading:
                ProgressView("Searching")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                NativeEmptyState(
                    title: "Search failed",
                    detail: message,
                    systemImage: "exclamationmark.triangle"
                )
            case .loaded(let results) where results.isEmpty:
                NativeEmptyState(
                    title: "No results",
                    detail: "No matches found for \"\(trimmedQuery)\".",
                    systemImage: "magnifyingglass"
                )
            case .loaded(let results):
                List(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.headline)
                        Text(result.url).font(.caption).foregroundStyle(.secondary)
                        Text(result.snippet).lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .navigationTitle("Research")
    }

    private func runSearch() {
        guard !trimmedQuery.isEmpty, !isSearching else { return }
        state = .loading
        Task {
            switch await appModel.search(query) {
            case .success(let results):
                state = .loaded(results)
            case .failure(let failure):
                state = .failed(failure.message)
            }
        }
    }

    private func saveSearchConfiguration() {
        let url = appModel.searxngBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !savingSearchConfiguration else { return }
        savingSearchConfiguration = true
        Task {
            do {
                try await appModel.configureSearXNG(baseURL: url)
                appModel.statusText = "Search service saved"
            } catch {
                appModel.statusText = "Search service save failed: \(error.localizedDescription)"
            }
            savingSearchConfiguration = false
        }
    }
}

private enum ResearchViewState {
    case idle
    case loading
    case failed(String)
    case loaded([ResearchResult])
}
