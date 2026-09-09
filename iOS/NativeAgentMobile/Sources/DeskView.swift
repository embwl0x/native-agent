import SwiftUI
import NativeAgentShared

struct MobileDeskTasksLabel: View {
    var body: some View { Label("Desk tasks", systemImage: "checklist") }
}

struct MobileLoadedRecordsDisclosure: View {
    let title: String
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) (\(remaining) remaining)")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The only Desk kinds the mobile creation sheet may send across the iCloud
/// action boundary. Keeping the picker state typed prevents a UI edit from
/// emitting an arbitrary wire value the canonical Desk store would reject.
enum MobileDeskItemKind: String, CaseIterable, Hashable {
    case plan
    case project
    case watch
    case gh
    case standing
}

/// iOS may submit only the statuses accepted by the Mac action router. A
/// blocked item keeps its current label visible so it can be moved elsewhere,
/// but the phone never offers a reasonless transition into `blocked`.
enum MobileDeskStatusPickerPresentation {
    private static let routerAcceptedStatuses = [
        "watch", "flag", "now", "next", "todo", "done", "canceled",
    ]

    static func allowedStatuses(for current: String) -> [String] {
        current == "blocked" ? ["blocked"] + routerAcceptedStatuses : routerAcceptedStatuses
    }
}

enum MobileDeskEmptyStatePresentation: Equatable {
    case loading
    case unavailable(String)
    case empty

    static func state(
        hasAttemptedLoad: Bool,
        isRefreshing: Bool,
        loadError: String?
    ) -> MobileDeskEmptyStatePresentation {
        if !hasAttemptedLoad || isRefreshing { return .loading }
        if let loadError = loadError?.trimmingCharacters(in: .whitespacesAndNewlines), !loadError.isEmpty {
            return .unavailable(loadError)
        }
        return .empty
    }
}

/// iPhone projection of the Mac-owned, event-sourced Desk. All writes travel
/// through the existing signed action channel; iOS never owns a second Desk.
struct MobileDeskView: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @State private var selectedItem: MobileDeskItem?
    @State private var showingNewItem = false
    @State private var errorMessage: String?
    @State private var isRefreshingDesk = false
    @State private var hasAttemptedDeskLoad = false
    @State private var deskLoadError: String?
    @State private var historyLimit = 40

    private var waitingOnYou: [MobileDeskItem] {
        MobileDesignSamples.rows(sync.deskItems).filter { MobileDeskSectionPresentation.section(for: $0) == .waitingOnYou }
    }

    private var active: [MobileDeskItem] {
        MobileDesignSamples.rows(sync.deskItems).filter { MobileDeskSectionPresentation.section(for: $0) == .active }
    }

    private var history: [MobileDeskItem] {
        MobileDesignSamples.rows(sync.deskItems).filter { MobileDeskSectionPresentation.section(for: $0) == .history }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WorkshopView(embedInNavigationStack: false)
                } label: {
                    MobileDeskTasksLabel()
                }
                .accessibilityHint("Opens directed tasks and task history")
            }
            if !waitingOnYou.isEmpty {
                Section("Waiting on You") {
                    ForEach(waitingOnYou) { item in deskRow(item) }
                }
            }
            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { item in deskRow(item) }
                }
            }
            if !history.isEmpty {
                Section("History") {
                    ForEach(history.prefix(historyLimit)) { item in deskRow(item) }
                    if history.count > historyLimit {
                        MobileLoadedRecordsDisclosure(title: "Show more history", remaining: history.count - historyLimit) {
                            historyLimit += 40
                        }
                    }
                }
            }
            if MobileDesignSamples.rows(sync.deskItems).isEmpty {
                switch MobileDeskEmptyStatePresentation.state(
                    hasAttemptedLoad: hasAttemptedDeskLoad,
                    isRefreshing: isRefreshingDesk,
                    loadError: deskLoadError
                ) {
                case .loading:
                    ProgressView("Loading Desk…")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                case .unavailable(let error):
                    MobileReadingEmptyState(
                        title: "Desk is unavailable",
                        systemImage: "icloud.slash",
                        kind: .unavailable,
                        description: error,
                        action: (
                            title: "Try Again",
                            systemImage: "arrow.clockwise",
                            handler: {
                                Task { await refreshDesk() }
                            }
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                case .empty:
                    MobileReadingEmptyState(
                        title: "Your Desk is clear",
                        systemImage: "rectangle.3.group",
                        kind: .empty,
                        description: "Items tracked on the Mac will appear here. You can also add one from your iPhone."
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .mobileReadingScreen()
        .navigationTitle("Desk")
        .macSyncErrorBanner()
        .safeAreaInset(edge: .top, spacing: 0) { MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16) }
        .toolbar {

            ToolbarItem(placement: .primaryAction) {
                Button { showingNewItem = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Desk item")
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if let syncAt = sync.lastSyncAt { SyncBadge(date: syncAt) }
            }
        }
        .refreshable { await refreshDesk() }
        .task { await refreshDesk() }
        .onChange(of: sync.deskItems) { _, items in
            guard !items.isEmpty else { return }
            hasAttemptedDeskLoad = true
            deskLoadError = nil
        }
        .sheet(item: $selectedItem) { item in
            MobileDeskItemDetail(item: item, errorMessage: $errorMessage)
        }
        .sheet(isPresented: $showingNewItem) {
            NewMobileDeskItemSheet(errorMessage: $errorMessage)
        }
        .alert("Desk", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refreshDesk() async {
        guard !isRefreshingDesk else { return }
        isRefreshingDesk = true
        defer { isRefreshingDesk = false }
        let loaded = await sync.refreshDeskSnapshot()
        hasAttemptedDeskLoad = true
        deskLoadError = loaded ? nil : "Desk is still syncing from the Mac. Try again in a moment."
    }

    @ViewBuilder
    private func deskRow(_ item: MobileDeskItem) -> some View {
        Button { selectedItem = item } label: {
            MobileAdaptiveRow(alignment: .top, spacing: 12) {
                Image(systemName: Self.icon(for: item.status))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.body).foregroundStyle(.primary)
                    MobileAdaptiveRow(spacing: 6) {
                        Text(item.alias).font(.system(.caption, design: .monospaced))
                        Text(item.project).fixedSize(horizontal: false, vertical: true)
                        Text(item.status.uppercased())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let reason = item.blockedReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    fileprivate static func icon(for status: String) -> String {
        switch status {
        case "done": "checkmark.circle.fill"
        case "canceled": "xmark.circle"
        case "blocked": "exclamationmark.octagon.fill"
        case "now": "bolt.circle.fill"
        case "next": "arrow.right.circle.fill"
        case "flag": "flag.fill"
        default: "circle"
        }
    }

    fileprivate static func color(for status: String) -> Color {
        switch status {
        case "done": .green
        case "canceled": .secondary
        case "blocked": .red
        case "now": NativeAgentPalette.agentAccent
        case "next": .blue
        case "flag": .orange
        default: .secondary
        }
    }
}

/// The Mac stamps `closedAt` for every terminal Desk transition and includes
/// that stamp in the mobile snapshot. It is therefore the cross-version
/// terminal proof; matching raw status names here would leave a newly added
/// terminal Mac status in Active until the iOS app shipped again.
enum MobileDeskSectionPresentation {
    enum Section: Equatable {
        case waitingOnYou
        case active
        case history
    }

    static func section(for item: MobileDeskItem) -> Section {
        section(requiresOwnerInput: item.requiresOwnerInput, closedAt: item.closedAt)
    }

    static func section(requiresOwnerInput: Bool, closedAt: String?) -> Section {
        if let closedAt, !closedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .history
        }
        return requiresOwnerInput ? .waitingOnYou : .active
    }
}

/// The mobile form validates the same note shape that the Mac action accepts,
/// so an iPhone user learns about a local input issue before an iCloud round
/// trip can return the router's otherwise generic rejection.
enum MobileDeskNotePresentation {
    static let maximumCharacterCount = 2_000
    static let maximumCharacterCountLabel = "2,000"

    static func submissionText(for draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumCharacterCount else { return nil }
        return text
    }

    static func validationMessage(for draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Enter a note before adding it." }
        if text.count > maximumCharacterCount {
            return "Desk notes can be at most \(maximumCharacterCountLabel) characters."
        }
        return nil
    }
}

private struct MobileDeskItemDetail: View {
    let item: MobileDeskItem
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Project", value: item.project)
                    LabeledContent("Kind", value: item.kind.capitalized)
                    LabeledContent("Status", value: item.status.capitalized)
                    if let summary = item.summary, !summary.isEmpty { Text(summary) }
                    if let reason = item.blockedReason, !reason.isEmpty {
                        LabeledContent("Blocked", value: reason)
                    }
                    if let waiting = item.waitingOn, !waiting.isEmpty {
                        LabeledContent("Waiting on", value: waiting)
                    }
                }
                Section("Move") {
                    Picker("Status", selection: Binding(
                        get: { item.status },
                        set: { status in Task { await changeStatus(status) } }
                    )) {
                        ForEach(MobileDeskStatusPickerPresentation.allowedStatuses(for: item.status), id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    .disabled(isWorking)
                }
                if !item.recentNotes.isEmpty {
                    Section("Recent Notes") {
                        ForEach(Array(item.recentNotes.enumerated()), id: \.offset) { _, note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.text)
                                Text(note.timestamp).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Add Note") {
                    TextField("What changed?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                    Text("\(note.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(MobileDeskNotePresentation.maximumCharacterCountLabel)")
                        .font(.caption)
                        .foregroundStyle(note.trimmingCharacters(in: .whitespacesAndNewlines).count > MobileDeskNotePresentation.maximumCharacterCount ? .red : .secondary)
                    Button("Add Note") { Task { await addNote() } }
                        .disabled(isWorking || MobileDeskNotePresentation.submissionText(for: note) == nil)
                }
            }
            .mobileReadingScreen()
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func changeStatus(_ status: String) async {
        guard status != item.status else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await iCloudSyncEngine.shared.setDeskItemStatus(handle: item.handle, status: status)
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func addNote() async {
        guard let clean = MobileDeskNotePresentation.submissionText(for: note) else {
            errorMessage = MobileDeskNotePresentation.validationMessage(for: note)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await iCloudSyncEngine.shared.appendDeskItemNote(handle: item.handle, text: clean)
            note = ""
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewMobileDeskItemSheet: View {
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = "General"
    @State private var summary = ""
    @State private var kind: MobileDeskItemKind = .plan
    @State private var isSaving = false
    @State private var submission: InboxAction?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Project", text: $project)
                Picker("Kind", selection: $kind) {
                    ForEach(MobileDeskItemKind.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                TextField("Summary (optional)", text: $summary, axis: .vertical).lineLimit(2...6)
            }
            .disabled(submission != nil)
            .mobileReadingScreen()
            .navigationTitle("New Desk Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Text("Add")
                        }
                    }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(isSaving ? "Adding Desk item" : "Add Desk item")
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // 2026-09-06: each new sheet creates a request; uncertain saves retain it for retry.
        let intentionalNewRequest = submission == nil
        if submission == nil {
            var payload = [
                "kind": kind.rawValue,
                "project": project.trimmingCharacters(in: .whitespacesAndNewlines),
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSummary.isEmpty { payload["summary"] = cleanSummary }
            submission = .make(action: "createDeskItem", payload: payload)
        }
        do {
            _ = try await iCloudSyncEngine.shared.createDeskItem(
                kind: kind.rawValue,
                project: project.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                submission: submission, intentionalNewRequest: intentionalNewRequest,
                onReplacement: { submission = $0 }
            )
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
