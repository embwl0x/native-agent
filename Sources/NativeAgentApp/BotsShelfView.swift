import SwiftUI
import StandingBots

/// Local design controls only; no resident store access or acknowledgements.
struct BotsShelfView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State var records: [BotsShelfRecord]
    @State var selectedID: UUID?
    @State private var allRuns = false
    @State private var editing = false
    @State private var brief = ""
    @State private var notice: String?

    var body: some View {
        ShellRailPage(title: "Bots", wide: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Design preview · fictional shelf · local controls only")
                    .font(.caption).foregroundStyle(NativeAgentShell.secondary)
                if let index = records.firstIndex(where: { $0.id == selectedID }) {
                    Button { selectedID = nil; allRuns = false } label: {
                        Label("All bots", systemImage: "chevron.left")
                    }.buttonStyle(.plain).foregroundStyle(NativeAgentShell.needsYou)
                    scrolling { detail(index) }
                } else {
                    scrolling { shelfList }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .tint(NativeAgentShell.needsYou)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit brief").font(.title2)
                TextEditor(text: $brief).frame(width: 460, height: 140)
                HStack {
                    Button("Cancel") { editing = false }
                    Spacer()
                    Button("Save preview") {
                        if let index = records.firstIndex(where: { $0.id == selectedID }) {
                            records[index].definition.brief = brief
                        }
                        editing = false
                    }.disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24)
        }
    }

    @ViewBuilder private func scrolling<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth: .infinity, alignment: .leading) }
    }

    private var shelfList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(records) { record in
                Button { selectedID = record.id; notice = nil; allRuns = false } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(record.definition.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                            if record.unread > 0 {
                                Text("\(record.unread) unread").font(.caption.weight(.medium))
                                    .foregroundStyle(NativeAgentShell.needsYou).fixedSize()
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(NativeAgentShell.needsYou)
                        }
                        Text(record.definition.brief)
                        if let latest = record.sortedEntries.first,
                           latest.runHealth == .partial || latest.runHealth == .failed || !latest.uncertainties.isEmpty {
                            Label(latest.uncertainties.first ?? BotsShelfRecord.health(latest.runHealth), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(NativeAgentShell.trouble)
                        }
                        Text(record.definition.paused ? "Paused" : record.cadence)
                            .font(.caption).foregroundStyle(NativeAgentShell.secondary)
                        Text("Last complete check: \(record.lastGood.map { BotsShelfRecord.date($0.runAt) } ?? "None yet")")
                            .font(.caption).foregroundStyle(NativeAgentShell.secondary)
                            .help(record.lastGood.map { BotsShelfRecord.exactDate($0.runAt) } ?? "No complete check recorded")
                    }
                    .font(.callout).foregroundStyle(NativeAgentShell.text)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Open results and run history")
                Divider()
            }
            if records.isEmpty { Text("No preview bots available.").padding(20) }
        }.background(NativeAgentShell.room.opacity(0.94))
    }

    private func detail(_ index: Int) -> some View {
        let record = records[index]
        return VStack(alignment: .leading, spacing: 14) {
            Text(record.definition.name).font(.title2.weight(.semibold))
            Text(record.definition.brief).font(.callout)
            Text(record.definition.paused ? "Paused" : record.nextRun.map { "Next scheduled run: \(BotsShelfRecord.date($0))" } ?? "Next scheduled run unavailable")
                .font(.caption).foregroundStyle(NativeAgentShell.secondary)
                .help(record.nextRun.map(BotsShelfRecord.exactDate) ?? "No next run recorded")
            HStack(spacing: 12) {
                Button("Edit brief") { brief = record.definition.brief; editing = true }
                Button(record.definition.paused ? "Resume" : "Pause") { records[index].definition.paused.toggle() }
                Button("Run once") { notice = "Preview only. No run was started." }
            }.buttonStyle(.bordered)
            if let notice { Text(notice).font(.caption) }
            HStack(spacing: 8) {
                Text("Results")
                HStack(spacing: 0) {
                    resultSegment("Catch up (\(record.unread) unread)", all: false)
                    resultSegment("All runs (\(record.entries.count))", all: true)
                }
                .background(NativeAgentShell.softFill, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain).accessibilityLabel("Results")
            }.font(.body)
            VStack(alignment: .leading, spacing: 20) {
                let entries = allRuns ? record.sortedEntries : record.catchUp
                if entries.isEmpty { Text("All caught up. Previous results are in All runs.") }
                ForEach(entries.filter { $0.runHealth != .nothingNew || !$0.uncertainties.isEmpty }) { entry in
                    entryView(entry, record: record)
                }
                let unchanged = entries.filter { $0.runHealth == .nothingNew && $0.uncertainties.isEmpty }
                if !unchanged.isEmpty {
                    let unread = unchanged.filter { record.unreadIDs.contains($0.id) }.count
                    DisclosureGroup("\(unchanged.count) no-change runs · \(unread) unread") {
                        Text("Only each run’s recorded coverage was checked. Gaps between runs are not covered.")
                            .font(.caption).foregroundStyle(NativeAgentShell.secondary).padding(.vertical, 8)
                        ForEach(unchanged) { entry in entryView(entry, record: record) }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(NativeAgentShell.room.opacity(0.96))
        }.foregroundStyle(NativeAgentShell.text).padding(.bottom, 20)
    }

    private func entryView(_ entry: ShelfEntry, record: BotsShelfRecord) -> some View {
        BotsShelfEntryView(entry: entry, unread: record.unreadIDs.contains(entry.id), budget: record.definition.budget)
    }

    private var selectedResultInk: Color { colorScheme == .dark ? .black : .white }

    // Native segmented pickers override label ink for custom tints. Keep the
    // same two segments while owning ink explicitly under the shell's lamp.
    private func resultSegment(_ title: String, all: Bool) -> some View {
        let selected = allRuns == all
        return Button { allRuns = all } label: {
            Text(title)
                .foregroundStyle(selected ? selectedResultInk : NativeAgentShell.text)
                .padding(.horizontal, 10).frame(minWidth: 142, minHeight: 24)
                .background(selected ? NativeAgentShell.needsYou : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct BotsShelfEntryView: View {
    let entry: ShelfEntry
    let unread: Bool
    let budget: BotBudget
    private var incomplete: Bool { entry.runHealth == .partial || entry.runHealth == .failed }
    private var budgetExhausted: Bool {
        incomplete && (entry.spend.tokens >= budget.tokens || entry.spend.seconds >= budget.seconds)
    }
    private var coverageNotice: String {
        if !entry.uncertainties.isEmpty { return entry.uncertainties.joined(separator: " ") }
        if budgetExhausted { return "Coverage is incomplete because the run reached its limit." }
        return BotsShelfRecord.health(entry.runHealth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(BotsShelfRecord.date(entry.runAt)).help(BotsShelfRecord.exactDate(entry.runAt))
                Text(unread ? "Unread" : "Read").foregroundStyle(unread ? NativeAgentShell.needsYou : NativeAgentShell.secondary)
            }.font(.caption).foregroundStyle(NativeAgentShell.secondary)
            Label(coverageNotice, systemImage: incomplete || !entry.uncertainties.isEmpty ? "exclamationmark.triangle" : "checkmark")
                .font(.callout.weight(.medium))
                .foregroundStyle(incomplete || !entry.uncertainties.isEmpty ? NativeAgentShell.trouble : NativeAgentShell.secondary)
            Text("Recorded coverage: \(BotsShelfRecord.date(entry.coverageStart)) – \(BotsShelfRecord.date(entry.coverageEnd))")
                .font(.caption).foregroundStyle(NativeAgentShell.secondary)
                .help("\(BotsShelfRecord.exactDate(entry.coverageStart)) – \(BotsShelfRecord.exactDate(entry.coverageEnd))")
            // Bot-defined prose, not mandatory report sections.
            if entry.runHealth != .nothingNew {
                Text(entry.headline).font(.headline)
                Text(entry.findings).textSelection(.enabled)
            } else if !entry.findings.isEmpty {
                Text(entry.findings).textSelection(.enabled)
            }
            if !entry.changedSinceLastGood.isEmpty && entry.changedSinceLastGood != entry.findings {
                Text(entry.changedSinceLastGood).textSelection(.enabled)
            }
            ForEach(Array(entry.sourceLinks.enumerated()), id: \.offset) { _, source in
                if let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link("Evidence · \(url.host ?? source.url)", destination: url)
                        .help("\(source.url) · \(BotsShelfRecord.exactDate(source.datedAt))")
                        .foregroundStyle(NativeAgentShell.needsYou)
                }
            }
            DisclosureGroup("Run budget") {
                if budgetExhausted {
                    Text("Run budget exhausted").foregroundStyle(NativeAgentShell.trouble)
                }
                Text("\(entry.spend.tokens) / \(budget.tokens) tokens · \(Int(entry.spend.seconds)) / \(Int(budget.seconds)) seconds")
                    .font(.caption).foregroundStyle(NativeAgentShell.secondary)
            }.font(.caption)
            Divider()
        }.font(.callout)
    }
}

struct BotsShelfPreviewPage: View {
    @AppStorage(BotsShelfPreference.key) private var enabled = false
    var body: some View {
        if enabled {
            #if DEBUG
            BotsShelfView(records: BotsShelfSample.records)
            #else
            ShellRailPage(title: "Bots") { Text("Design preview is available in a Debug build.") }
            #endif
        } else {
            ShellRailPage(title: "Bots") { Text("Bots preview is turned off.") }
        }
    }
}
