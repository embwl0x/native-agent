import TrustCenter
import Foundation
import NativeAgentCore

// Blueprint: | `DreamsView.swift` | `DreamsView`: checked diary reads, exact dates and Dream/REM controls |
import SwiftUI
import DreamREMCycle
import PersistenceCore

enum DreamRunAvailability: Equatable {
    case checking
    case enabled
    case disabled
    case unavailable

    static func resolve(
        hasReadAuthority: Bool,
        loadFailed: Bool,
        enabled: Bool
    ) -> Self {
        if loadFailed { return .unavailable }
        guard hasReadAuthority else { return .checking }
        return enabled ? .enabled : .disabled
    }

    var canRun: Bool { self == .enabled }
}

/// A non-nil operation error proves failure even without diagnostic text; never render it as success or an empty error strip.
enum DreamErrorBannerPresentation {
    static let maximumDetailCharacters = 280
    static let missingDetailText = "Dreams operation failed, but no diagnostic detail was returned."

    static func text(for error: String?) -> String? {
        guard let error else { return nil }
        let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return missingDetailText
        }
        let isTruncated = detail.count > maximumDetailCharacters
        let bounded = String(detail.prefix(maximumDetailCharacters))
        return isTruncated ? "\(bounded)…" : bounded
    }
}

/// Only a successful empty read proves an empty diary; failed reads leave retained entries stale or the first load unavailable.
enum DreamDiaryRefreshPresentation: Equatable {
    case current
    case retainedStale(entryCount: Int)
    case unavailable

    static func resolve(entries: [DreamEntry], didFail: Bool) -> Self {
        guard didFail else { return .current }
        return entries.isEmpty ? .unavailable : .retainedStale(entryCount: entries.count)
    }

    var banner: String? {
        switch self {
        case .current: return nil
        case .retainedStale:
            return "Couldn't refresh the diary — showing previously loaded entries."
        case .unavailable:
            return "Dream cycle availability couldn't be checked. Retry the diary refresh before running a dream pass."
        }
    }

    var unavailableEmptyState: Bool { self == .unavailable }
}

/// A successful read may omit damaged files; keep partial coverage distinct from empty and failed reads.
enum DreamDiaryListPresentation: Equatable {
    case readable
    case incomplete(unreadableEntries: Int)

    static func resolve(entryCount: Int, unreadableEntries: Int) -> Self {
        entryCount == 0 && unreadableEntries > 0
            ? .incomplete(unreadableEntries: unreadableEntries)
            : .readable
    }

    static func unreadableLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 diary file in this window couldn't be read and is not shown."
            : "\(count) diary files in this window couldn't be read and are not shown."
    }
}

/// A selected date with no fetched entry is unavailable, not an unselected diary.
enum DreamEntryDetailPresentation: Equatable {
    case loading
    case entry
    case failed(String)
    case unselected

    static let missingEntryDetail = "The selected diary entry could not be read."

    static func resolve(
        selectedDate: String?,
        hasSelectedEntry: Bool,
        isLoading: Bool,
        error: String?
    ) -> Self {
        if isLoading && !hasSelectedEntry { return .loading }
        if hasSelectedEntry { return .entry }
        guard selectedDate != nil else { return .unselected }
        return .failed(error ?? missingEntryDetail)
    }
}

struct DreamsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    @State private var selectedDate: String?
    @State private var isRunningDream = false
    @State private var isRunningRem = false
    @State private var remPolicyLoadFailed = false
    @State private var remRunFeedback: DreamsREMActionFeedback?
    @State private var refreshTask: Task<Void, Never>?

    private var diaryOwner: CognitionViewFacade { appModel.engine.cognitionView }
    private var entries: [DreamEntry] { Array((diaryOwner.diary?.entries ?? []).prefix(diaryLimit)) }
    private var selectedEntry: DreamEntry? { entries.first { $0.date == selectedDate } }
    private var diaryLoadFailed: Bool { diaryOwner.diaryError != nil }
    private var hasReadDiaryGate: Bool { diaryOwner.diaryGate != nil }
    private var dreamEnabledFromDiary: Bool { diaryOwner.diaryGate?.dreamEnabled == true }
    private var diaryTotalEntries: Int? { diaryOwner.diary?.totalEntries }
    private var diaryUnreadableEntries: Int { diaryOwner.diary?.unreadableEntries ?? 0 }

    private static let diaryPage = 60
    @State private var diaryLimit = DreamsView.diaryPage

    private var isLoadingDiary: Bool { diaryOwner.diaryLoading }

    private var entryDetailPresentation: DreamEntryDetailPresentation {
        DreamEntryDetailPresentation.resolve(
            selectedDate: selectedDate,
            hasSelectedEntry: selectedEntry != nil,
            isLoading: isLoadingDiary,
            error: diaryOwner.diaryError
        )
    }

    private var diaryListPresentation: DreamDiaryListPresentation {
        DreamDiaryListPresentation.resolve(
            entryCount: entries.count,
            unreadableEntries: diaryUnreadableEntries
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            controlBar

            if let errorText = DreamErrorBannerPresentation.text(for: appModel.dreamError) {
                Text(errorText)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Dreams error: \(errorText)")
            }

            content
        }
        .alivePageLine(headerLine, id: "dreams.line")
        .navigationTitle("Dreams")
        .task {
            acceptPaletteDestination()
            await loadREMPolicy()
            await loadDiary()
        }
        .onChange(of: appModel.pendingPaletteDestination, initial: true) { _, _ in
            acceptPaletteDestination()
        }
        .onChange(of: diaryOwner.diary) { _, _ in reconcileSelection() }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private var headerLine: String? {
        if diaryLoadFailed && entries.isEmpty { return "I couldn't read my dream diary just now." }
        guard hasReadDiaryGate else { return nil }
        let count = diaryTotalEntries ?? entries.count
        let kept = count == 0
            ? "I haven't written a dream yet"
            : "I've written \(count) \(count == 1 ? "dream" : "dreams") in my diary"
        return kept + (dreamEnabledFromDiary ? "." : "; my dream cycle is off.")
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            AliveGroupCard {
                HStack(spacing: 8) {
                    Button {
                        runDream()
                    } label: {
                        Text(isRunningDream ? "Dreaming…" : "Run a dream pass")
                    }
                    .disabled(isRunningDream || !canRunDream)
                    .help(dreamRunHelp)

                    Button {
                        runRem()
                    } label: {
                        Text(isRunningRem ? "Consolidating…" : "Run a REM pass")
                    }
                    .disabled(isRunningRem || !remRunAvailability.canRun)
                    .help(remRunHelp)

                    Spacer()

                    Button {
                        refresh()
                    } label: {
                        if isLoadingDiary {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Refresh")
                        }
                    }
                    .help("Refresh the dream diary")
                    .disabled(isLoadingDiary)
                }
            }

            if let banner = diaryRefreshPresentation.banner {
                Text(banner)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
            if let remRunFeedback {
                Text(remRunFeedback.message)
                    .font(ShellType.label)
                    .foregroundStyle(remRunFeedback.isSuccess ? NativeAgentShell.secondary : NativeAgentShell.trouble)
            }
            if let label = DreamDiaryListPresentation.unreadableLabel(diaryUnreadableEntries) {
                Text(label)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            if isLoadingDiary {
                AdvancedWaitingLine("Reading the dream diary…")
            } else if diaryRefreshPresentation.unavailableEmptyState {
                AdvancedEmptyState(
                    title: "Dream diary unavailable",
                    detail: "The diary could not be read, so this is not evidence that no dreams have been recorded.",
                    actionTitle: "Retry",
                    action: { refresh() }
                )
            } else if case .incomplete(let unreadableEntries) = diaryListPresentation {
                AdvancedEmptyState(
                    title: "Dream diary incomplete",
                    detail: """
                        \(unreadableEntries) diary file\(unreadableEntries == 1 ? "" : "s") could not be read, so this is not evidence that no dreams have \
                        been recorded.
                        """,
                    actionTitle: "Retry",
                    action: { refresh() }
                )
            } else {
                AdvancedEmptyState(
                    title: "No dreams yet",
                    detail: emptyDiaryDetail
                )
            }
        } else {
            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("My diary")
            HSplitView {
                List(selection: $selectedDate) {
                    // Use plain week rows because List pins section headers and stacks them over clear backgrounds.
                    ForEach(DreamDiaryWeeks.weeks(entries)) { week in
                        Text(week.title)
                            .font(ShellType.captionMedium)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .padding(.top, 6)
                            .selectionDisabled()
                        ForEach(week.entries, id: \.date) { entry in
                            DreamDateRow(entry: entry)
                                .tag(entry.date)
                        }
                    }
                    if let diaryTotalEntries, diaryTotalEntries > entries.count {
                        Button {
                            diaryLimit += Self.diaryPage
                            refreshTask?.cancel()
                            refreshTask = Task { await loadDiary() }
                        } label: {
                            Text(isLoadingDiary
                                 ? "Reading older dreams…"
                                 : "Show older dreams (\(diaryTotalEntries - entries.count) more)")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingDiary)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minWidth: 200, idealWidth: 240)

                detailPanel
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.vertical, 8)
            .aliveCard()
            }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if case .loading = entryDetailPresentation {
            AdvancedWaitingLine("Reading this dream…")
        } else if case .entry = entryDetailPresentation, let entry = selectedEntry {
            let reading = DreamReaderText.reading(entry.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Name the dream's date and write time separately because overnight runs write about the preceding day.
                        let night = "Night of " + DreamReaderText.friendlyDate(entry.date)
                        Text(reading.title ?? night)
                            .accessibilityIdentifier("dreams.selected-entry.\(entry.date)")
                            .font(ShellType.bodySemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        let written = entry.modifiedAt.map { "written " + shortTimestamp($0) }
                        if let caption = reading.title != nil
                            ? [night, written].compactMap { $0 }.joined(separator: " · ")
                            : written.map({ "W" + $0.dropFirst() }) {
                            Text(caption)
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    }

                    if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This entry is empty.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    } else {
                        ForEach(Array(reading.body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            dreamLine(line)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if case let .failed(entryLoadError) = entryDetailPresentation {
            AdvancedEmptyState(
                title: "Couldn't load this dream",
                detail: entryLoadError,
                actionTitle: "Retry",
                action: {
                    refresh()
                }
            )
            .padding(.horizontal, 16)
        } else {
            AdvancedEmptyState(
                title: "Select a dream",
                detail: "Pick a date on the left to read that night's entry."
            )
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func dreamLine(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 8)
        } else if trimmed.hasPrefix("# ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("## ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(3))))
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.text)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("### ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(4))))
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.secondary)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(LocalizedStringKey(raw))
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            await loadREMPolicy()
            await loadDiary()
        }
    }

    @MainActor
    private func runDream() {
        guard !isRunningDream else { return }   // synchronous guard — no double-fire
        isRunningDream = true
        Task {
            let ok = await appModel.runDreamPassForDreams().ok
            isRunningDream = false
            if ok { await loadDiary(selectLatest: true) }
        }
    }

    @MainActor
    private func runRem() {
        guard !isRunningRem, remRunAvailability.canRun else { return }
        isRunningRem = true
        remRunFeedback = nil
        Task {
            let feedback = await appModel.runRemPass()
            isRunningRem = false
            remRunFeedback = feedback
            if feedback.isSuccess { await loadDiary() }
        }
    }

    @MainActor
    private func loadDiary(selectLatest: Bool = false) async {
        appModel.dreamError = nil
        await diaryOwner.refreshDiary(limit: diaryLimit)
        guard !Task.isCancelled, !diaryLoadFailed else { return }
        reconcileSelection(selectLatest: selectLatest)
    }

    private func reconcileSelection(selectLatest: Bool = false) {
        if let latest = entries.first, selectLatest || selectedDate == nil {
            selectedDate = latest.date
        }
    }

    private func acceptPaletteDestination() {
        guard !quietOffscreenRead,
              case .dream(let date)? = appModel.pendingPaletteDestination else { return }
        selectedDate = date
        appModel.pendingPaletteDestination = nil
    }

    @MainActor
    private func loadREMPolicy() async {
        guard appModel.engine.trust.policy == nil || remPolicyLoadFailed else { return }
        do {
            _ = try await appModel.engine.trust.load()
            remPolicyLoadFailed = false
        } catch {
            remPolicyLoadFailed = true
        }
    }

    private var canRunDream: Bool {
        dreamRunAvailability.canRun
    }

    private var dreamRunHelp: String {
        switch dreamRunAvailability {
        case .checking:
            return "Checking dream-cycle availability."
        case .enabled:
            return "Run a dream reflection pass against recent sessions."
        case .disabled:
            return "Dreams at night is off. Turn it on in Settings \u{25B8} Inner life."
        case .unavailable:
            return "Dream-cycle availability could not be read. Refresh the diary and retry."
        }
    }

    private var dreamRunAvailability: DreamRunAvailability {
        DreamRunAvailability.resolve(
            hasReadAuthority: hasReadDiaryGate,
            loadFailed: diaryLoadFailed,
            enabled: dreamEnabledFromDiary
        )
    }

    private var remRunAvailability: DreamRunAvailability {
        DreamRunAvailability.resolve(
            hasReadAuthority: appModel.engine.trust.policy != nil,
            loadFailed: remPolicyLoadFailed,
            enabled: appModel.engine.trust.policy?.trainingPolicy?.rem_cycle_enabled == true
        )
    }

    private var remRunHelp: String {
        switch remRunAvailability {
        case .checking:
            return "Checking REM-cycle permission."
        case .enabled:
            return """
                I reread the last week of dreams, draft up to five growth notes from patterns that recur on two or more days, and send them to you for \
                approval. Dreams older than two weeks move to the archive.
                """
        case .disabled:
            return "Weekly dream consolidation is off. Turn it on in Settings \u{25B8} Inner life."
        case .unavailable:
            return "REM-cycle permission could not be read. Refresh and retry."
        }
    }

    private var diaryRefreshPresentation: DreamDiaryRefreshPresentation {
        DreamDiaryRefreshPresentation.resolve(entries: entries, didFail: diaryLoadFailed)
    }

    private var emptyDiaryDetail: String {
        switch dreamRunAvailability {
        case .checking:
            return "Checking whether the dream cycle is available."
        case .enabled:
            return "I haven't written an entry yet. Run a dream pass and I'll write the first one."
        case .disabled:
            return "My dream cycle is off. Turn on Dreams at night in Settings \u{25B8} Inner life and I dream each night, or when you run a pass."
        case .unavailable:
            return "The dream diary could not be read, so cycle availability is unavailable."
        }
    }

    private func shortTimestamp(_ iso: String) -> String {
        UserDisplayFormatters.shortTime(iso)
    }
}


/// Drop only the exact stored date heading: the list and caption already carry it, leaving the dream's title to lead.
enum DreamReaderText {
    static func reading(_ content: String) -> (title: String?, body: String) {
        var lines = content.components(separatedBy: "\n")[...]
        func dropBlank() {
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines = lines.dropFirst()
            }
        }
        dropBlank()
        guard let heading = lines.first?.trimmingCharacters(in: .whitespaces),
              heading.range(of: #"^# Dream — \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return (nil, content) }
        lines = lines.dropFirst()
        dropBlank()
        // Keep each dream's title when a night has several entries.
        guard DreamNight(content).dreams.count <= 1 else { return (nil, lines.joined(separator: "\n")) }
        var title: String?
        if let line = lines.first?.trimmingCharacters(in: .whitespaces),
           line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") {
            let inner = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !inner.contains("**") {
                title = inner
                lines = lines.dropFirst()
                dropBlank()
            }
        }
        return (title, lines.joined(separator: "\n"))
    }

    /// Leave non-date identifiers unchanged; include the year only outside the current year.
    static func friendlyDate(_ key: String, now: Date = Date(),
                             calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = calendar.timeZone
        guard key.count == 10, let date = parser.date(from: key) else { return key }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

private struct DreamDateRow: View {
    let entry: DreamEntry

    /// Use the latest dream's title or opening words; a byte count cannot identify a night.
    private var excerpt: String {
        TodayWords.line(entry.night.latest.map { $0.title ?? $0.firstLine } ?? "", limit: 90)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DreamReaderText.friendlyDate(entry.date))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NativeAgentShell.text)
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// A synchronous REM response has completed; report its bounded outcome rather than claiming it merely started.
enum DreamsREMActionFeedback: Equatable {
    case completed(proposals: Int, archivedEntries: Int)
    /// Finding nothing worth consolidating is a normal completed outcome, not a failure.
    case nothingToConsolidate
    case failed(String)

    static func resolve(response: [String: Any]) -> Self {
        switch REMRunReportPayload.validatedManualCompletion(response: response) {
        case .success(let completion):
            return completion.nothingToConsolidate ? .nothingToConsolidate
                : .completed(proposals: completion.proposals, archivedEntries: completion.archivedEntries)
        case .failure(let error):
            return .failed(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .completed(let proposals, let archivedEntries):
            let proposalText = proposals == 1 ? "1 proposal" : "\(proposals) proposals"
            let archiveText = archivedEntries == 1 ? "1 diary entry archived" : "\(archivedEntries) diary entries archived"
            return "REM consolidation completed — \(proposalText), \(archiveText)."
        case .nothingToConsolidate:
            return "REM consolidation completed — nothing to consolidate yet."
        case .failed(let detail):
            return detail
        }
    }

    var isSuccess: Bool {
        switch self {
        case .completed, .nothingToConsolidate: return true
        case .failed: return false
        }
    }

}
