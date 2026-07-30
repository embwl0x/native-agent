// PATCH-2026-05-29: dreams-tab DreamsView — surfaces + controls the dream diary
// and REM consolidation cycle. Backend: Swift-native DreamREMCycle runtime.
//   GET  /v1/dream/diary?limit=N -> {entries:[DreamEntry], enabled:Bool}
//   GET  /v1/dream/<YYYY-MM-DD>  -> DreamEntry (404 if missing)
//   POST /v1/dream/run           -> run a dream pass now
//   POST /v1/rem/run             -> run a REM consolidation pass now
// Kill switches (via deep-merged /v1/trust patch):
//   personalityPolicy.dream_cycle_enabled (deep dream gate)
//   trainingPolicy.rem_cycle_enabled       (REM gate)
import SwiftUI

struct DreamsView: View {
    @Environment(AppModel.self) private var appModel

    // ── Diary state (owned by the view; the diary is fetched here, not in AppModel) ──
    @State private var entries: [DreamEntry] = []
    @State private var dreamEnabledFromDiary = false   // composite gate from /v1/dream/diary
    @State private var selectedDate: String?
    @State private var selectedEntry: DreamEntry?

    @State private var isLoadingDiary = false
    @State private var isLoadingEntry = false
    @State private var isRunningDream = false
    @State private var isRunningRem = false
    @State private var didInitialLoad = false

    // Optimistic local mirrors of the two kill switches so the toggles don't snap
    // back during the async save round-trip; reconciled from the source of truth
    // after each load. dreamCycleOn tracks the composite gate (the "Dream cycle"
    // toggle moves dream_cycle_enabled + dream_scheduler together).
    @State private var dreamCycleOn = false
    @State private var remCycleOn = true
    @State private var savingDream = false
    @State private var savingRem = false
    // Generation token so a slow earlier diary load can't clobber a newer one's
    // entries/selection/toggle reconcile (closes the toggle snap-back race).
    @State private var diaryLoadGen = 0

    // Cancellable task for diary refresh so it doesn't outlive the view.
    @State private var refreshTask: Task<Void, Never>?
    @State private var entryTask: Task<Void, Never>?

    private let diaryLimit = 60

    // REM enabled state is owned by the trust policy.
    @MainActor
    private var remEnabled: Bool {
        appModel.trustPolicy?.trainingPolicy?.rem_cycle_enabled ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()

            if let err = appModel.dreamError {
                Text(err)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(NativeAgentTheme.fail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NativeAgentSpacing.lg)
                    .padding(.vertical, NativeAgentSpacing.sm)
                    .background(NativeAgentTheme.fail.opacity(0.08))
            }

            content
        }
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name
        // ("NativeAgent") because no title was set on the body root.
        .navigationTitle("Dreams")
        .task {
            // One-shot initial load. .task is cancelled automatically on disappear.
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await loadDiary(selectLatest: true)
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            entryTask?.cancel()
            entryTask = nil
        }
    }

    // ── Controls ──────────────────────────────────────────────────────────────
    private var controlBar: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(spacing: NativeAgentSpacing.md) {
                Button {
                    runDream()
                } label: {
                    if isRunningDream {
                        Label("Dreaming…", systemImage: "hourglass")
                    } else {
                        Label("Run Dream Now", systemImage: "moon.stars")
                    }
                }
                .disabled(isRunningDream || !dreamEnabledFromDiary)
                .help(dreamEnabledFromDiary
                      ? "Run a dream reflection pass against recent sessions."
                      : "Dream cycle is disabled. Enable the dream cycle toggle and the Trust 'dream scheduler' gate.")

                Button {
                    runRem()
                } label: {
                    if isRunningRem {
                        Label("Consolidating…", systemImage: "hourglass")
                    } else {
                        Label("Run REM Now", systemImage: "sparkles")
                    }
                }
                .disabled(isRunningRem || !remEnabled)
                .help(remEnabled
                      ? "Run a REM consolidation pass over unconsumed dream entries."
                      : "REM cycle is disabled. Enable the REM cycle toggle.")

                Spacer()

                Button {
                    refresh()
                } label: {
                    if isLoadingDiary {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh the dream diary")
                .disabled(isLoadingDiary)
            }

            HStack(spacing: NativeAgentSpacing.xl) {
                Toggle("Dream cycle enabled", isOn: Binding(
                    get: { dreamCycleOn },
                    set: { newValue in
                        guard !savingDream else { return }
                        dreamCycleOn = newValue          // optimistic — no snap-back
                        savingDream = true
                        Task {
                            let ok = await appModel.setDreamCycleEnabled(newValue)
                            if ok {
                                // Both gates moved together; re-read the composite.
                                await loadDiary(selectLatest: false)
                            } else {
                                // Save failed — revert the optimistic flip and keep
                                // the error visible (don't reload, which clears it).
                                dreamCycleOn = !newValue
                            }
                            savingDream = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(savingDream)

                Toggle("REM cycle enabled", isOn: Binding(
                    get: { remCycleOn },
                    set: { newValue in
                        guard !savingRem else { return }
                        remCycleOn = newValue            // optimistic — no snap-back
                        savingRem = true
                        Task {
                            let ok = await appModel.setRemCycleEnabled(newValue)
                            // On success reconcile from the saved policy; on failure
                            // revert the optimistic flip (error stays visible).
                            remCycleOn = ok ? remEnabled : !newValue
                            savingRem = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(savingRem)

                Spacer()
            }
            .font(NativeAgentFont.label)
        }
        .padding(.horizontal, NativeAgentSpacing.lg)
        .padding(.vertical, NativeAgentSpacing.md)
    }

    // ── Content (master/detail, with empty + loading states) ────────────────────
    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            if isLoadingDiary {
                ProgressView("Loading dream diary…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeEmptyState(
                    title: "No dreams yet",
                    detail: dreamEnabledFromDiary
                        ? "The nightly dream cycle hasn't written an entry yet. Run a dream pass to create the first one."
                        : "The dream cycle is currently disabled. Enable it above, or run a dream pass manually once enabled.",
                    systemImage: "moon.zzz"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HSplitView {
                // Left: diary dates, newest first.
                List(entries, selection: Binding(
                    get: { selectedDate },
                    set: { newValue in
                        selectedDate = newValue
                        if let date = newValue { loadEntry(date: date) }
                    }
                )) { entry in
                    DreamDateRow(entry: entry)
                        .tag(entry.date)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 200, idealWidth: 240)

                // Right: selected entry, rendered readably.
                detailPanel
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if isLoadingEntry && selectedEntry == nil {
            ProgressView("Loading entry…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        Image(systemName: "moon.stars")
                            .foregroundStyle(.purple)
                        Text(entry.date)
                            .font(NativeAgentFont.title)
                        Spacer()
                        if let modified = entry.modified_at {
                            Text(shortTimestamp(modified))
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider()

                    if entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This entry is empty.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(entry.content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            dreamLine(line)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(NativeAgentSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NativeEmptyState(
                title: "Select a dream",
                detail: "Pick a date on the left to read that night's entry.",
                systemImage: "hand.tap"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Light markdown line renderer, mirroring ContentView.receiptLine().
    @ViewBuilder
    private func dreamLine(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed.hasPrefix("# ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                .font(.title3.weight(.bold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(3))))
                .font(.headline)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("### ") {
            Text(LocalizedStringKey(String(trimmed.dropFirst(4))))
                .font(.subheadline.weight(.semibold))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(LocalizedStringKey(String(trimmed.dropFirst(2))))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(LocalizedStringKey(raw))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ── Actions ─────────────────────────────────────────────────────────────────
    @MainActor
    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await loadDiary(selectLatest: false) }
    }

    @MainActor
    private func runDream() {
        guard !isRunningDream else { return }   // synchronous guard — no double-fire
        isRunningDream = true
        Task {
            let ok = await appModel.runDreamPassForDreams()
            isRunningDream = false
            // Reload ONLY on success — loadDiary clears dreamError, which would
            // otherwise erase the failure message before the user reads it.
            if ok { await loadDiary(selectLatest: true) }
        }
    }

    @MainActor
    private func runRem() {
        guard !isRunningRem else { return }
        isRunningRem = true
        Task {
            let ok = await appModel.runRemPass()
            isRunningRem = false
            if ok { await loadDiary(selectLatest: false) }
        }
    }

    // ── Loaders ───────────────────────────────────────────────────────────────
    @MainActor
    private func loadDiary(selectLatest: Bool) async {
        diaryLoadGen += 1
        let gen = diaryLoadGen
        isLoadingDiary = true
        defer { if gen == diaryLoadGen { isLoadingDiary = false } }
        guard let response = await appModel.fetchDreamDiary(limit: diaryLimit) else {
            return
        }
        // A newer loadDiary superseded this one — drop the stale result so a slow
        // earlier load can't clobber the latest entries/selection/toggle state.
        if Task.isCancelled || gen != diaryLoadGen { return }
        entries = response.entries
        dreamEnabledFromDiary = response.enabled
        // Reconcile the optimistic toggle mirrors from the source of truth (skip
        // while a save is in flight so we don't clobber the user's pending intent).
        if !savingDream { dreamCycleOn = response.enabled }
        if !savingRem { remCycleOn = remEnabled }

        // Re-derive the selection against the freshly loaded entries.
        if entries.isEmpty {
            selectedDate = nil
            selectedEntry = nil
            return
        }
        let currentStillValid = selectedDate.map { d in entries.contains { $0.date == d } } ?? false
        if selectLatest || !currentStillValid {
            // Jump to the newest entry (initial load / after a dream run / prior
            // selection no longer exists). Diary entries carry full content.
            let first = entries[0]
            selectedDate = first.date
            selectedEntry = first
        } else if let current = selectedDate, selectedEntry?.date != current {
            // Current selection still valid but its detail is stale — refresh it.
            loadEntry(date: current)
        }
    }

    @MainActor
    private func loadEntry(date: String) {
        // Cancel any in-flight fetch FIRST so a slower older fetch can't land after
        // a newer selection and overwrite it.
        entryTask?.cancel()
        // Prefer the already-fetched diary entry (it carries full content).
        if let cached = entries.first(where: { $0.date == date }),
           !cached.content.isEmpty {
            selectedEntry = cached
            return
        }
        // Switching to an uncached date — clear stale detail so the previous entry
        // isn't shown under the new selection while the fetch is in flight.
        selectedEntry = nil
        entryTask = Task {
            isLoadingEntry = true
            defer { isLoadingEntry = false }
            let fetched = await appModel.fetchDreamEntry(date: date)
            // Apply only if this is still the selected date and we weren't cancelled.
            if Task.isCancelled || selectedDate != date { return }
            if let fetched { selectedEntry = fetched }
        }
    }

    private func shortTimestamp(_ iso: String) -> String {
        UserDisplayFormatters.shortTime(iso)
    }
}

// ── Date row ───────────────────────────────────────────────────────────────────
private struct DreamDateRow: View {
    let entry: DreamEntry

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            Image(systemName: "moon.stars.fill")
                .font(.caption)
                .foregroundStyle(.purple.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date)
                    .font(NativeAgentFont.body)
                if let size = entry.size {
                    Text("\(size) bytes")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
