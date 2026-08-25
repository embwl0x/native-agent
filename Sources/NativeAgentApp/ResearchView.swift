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
    @State private var searchServiceStatus: ResearchSearchServiceStatus = .idle

    init(showingSearchConfiguration: Bool = false) {
        _showingSearchConfiguration = State(initialValue: showingSearchConfiguration)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        if case .loading = state { return true }
        return false
    }

    private var searchConfigurationPresentation: ResearchSearchConfigurationPresentation {
        ResearchSearchConfigurationPresentation.resolve(
            baseURL: appModel.searxngBaseURL,
            status: searchServiceStatus,
            isSaving: savingSearchConfiguration
        )
    }

    private var isDetectingSearchService: Bool {
        if case .detecting = searchServiceStatus { return true }
        return false
    }

    private var searchServiceURL: Binding<String> {
        Binding(
            get: { appModel.searxngBaseURL },
            set: { value in
                appModel.searxngBaseURL = value
                searchServiceStatus = .idle
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showingSearchConfiguration) {
                HStack {
                    TextField("SearXNG URL", text: searchServiceURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("research.search-service.url")
                    Button("Find", systemImage: "magnifyingglass") {
                        findSearchService()
                    }
                    .disabled(savingSearchConfiguration || isDetectingSearchService)
                    .accessibilityIdentifier("research.search-service.find")
                    Button("Save", systemImage: "checkmark.circle") {
                        saveSearchConfiguration()
                    }
                    .disabled(!searchConfigurationPresentation.canSave)
                    .accessibilityIdentifier("research.search-service.save")
                }
                if let error = searchConfigurationPresentation.validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("research.search-service.invalid")
                } else {
                    Text(searchConfigurationPresentation.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("research.search-service.status")
                }
            } label: {
                Text("Search service")
                    .togglesDisclosure($showingSearchConfiguration)
            }
            .accessibilityIdentifier("research.search-service")

            HStack {
                TextField("Research query", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                    .accessibilityIdentifier("research.search.query")
                Button(action: runSearch) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .disabled(!ResearchSearchConfigurationPresentation.canSubmit(
                    query: query,
                    isSearching: isSearching
                ))
                .accessibilityIdentifier("research.search.submit")
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
        guard !savingSearchConfiguration else { return }
        let url: String
        do {
            url = try NativeClient.normalizedSearXNGBaseURL(appModel.searxngBaseURL)
        } catch {
            searchServiceStatus = .saveFailed(error.localizedDescription)
            return
        }
        savingSearchConfiguration = true
        Task {
            do {
                _ = try await appModel.saveSearXNGBaseURL(url)
                searchServiceStatus = .saved
            } catch {
                searchServiceStatus = .saveFailed(error.localizedDescription)
            }
            savingSearchConfiguration = false
        }
    }

    private func findSearchService() {
        guard !isDetectingSearchService, !savingSearchConfiguration else { return }
        searchServiceStatus = .detecting
        Task {
            searchServiceStatus = .autodetect(await appModel.autodetectSearXNG())
        }
    }
}

enum ResearchSearchServiceStatus: Equatable {
    case idle
    case detecting
    case autodetect(SearXNGAutodetectOutcome)
    case saved
    case saveFailed(String)
}

enum ResearchSearchServicePresentation {
    static func text(baseURL: String, status: ResearchSearchServiceStatus) -> String {
        switch status {
        case .idle:
            return baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No search service configured."
                : "Search service configured."
        case .detecting:
            return "Looking for a local SearXNG service…"
        case .autodetect(.found(let baseURL)):
            return "SearXNG found: \(baseURL)"
        case .autodetect(.notFound(let detail)):
            return "SearXNG not found: \(detail)"
        case .autodetect(.failed(let detail)):
            return "SearXNG detection failed: \(detail)"
        case .saved:
            return "Search service saved."
        case .saveFailed(let detail):
            return "Search service save failed: \(detail)"
        }
    }
}

/// Shared eligibility and explanatory state for the Research surface. The
/// actual save/search actions remain on their root-scoped NativeClient and
/// AppModel owners; this only projects whether the controls may invite them.
struct ResearchSearchConfigurationPresentation: Equatable {
    let statusText: String
    let validationError: String?
    let canSave: Bool

    static func resolve(
        baseURL: String,
        status: ResearchSearchServiceStatus,
        isSaving: Bool
    ) -> Self {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let validationError = trimmed.isEmpty
            ? nil
            : NativeClient.searxngBaseURLValidationMessage(baseURL)
        return Self(
            statusText: ResearchSearchServicePresentation.text(baseURL: baseURL, status: status),
            validationError: validationError,
            canSave: !isSaving && !trimmed.isEmpty && validationError == nil
        )
    }

    static func canSubmit(query: String, isSearching: Bool) -> Bool {
        !isSearching && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum ResearchViewState {
    case idle
    case loading
    case failed(String)
    case loaded([ResearchResult])
}
