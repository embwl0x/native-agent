import StandingBots
import SwiftUI
import AppKit
import PersistenceCore
import Desk
import EngineRuntime
import TriggerScheduler
import WorkshopExecution
import Cognition
import BackgroundLoops
import NativeAgentShared
import ApprovalInbox
import NotificationInbox
import BackgroundWork
import ApprovalTransactions
import Observation
import NativeAgentCore
import DeviceSync

// Blueprint: | `DeskBoardFolds.swift` | `DeskPageView` folds: board, finished history, schedule and bounded row reveals |

extension DeskPageView {
    // MARK: the board — everything else, folded
    enum Fold {
        static let blocked = "blocked"
        static let watching = "watching"
        static let schedule = "schedule"
        static let parked = "parked"
        static let stale = "stale"
        static let other = "other"
        static let history = "history"
    }

    var blockedItems: [DeskItem] { snapshot.rows.blocked }
    var watchItems: [DeskItem] { snapshot.rows.watches }
    private var staleItems: [DeskItem] { snapshot.rows.stale }
    private var otherItems: [DeskItem] { snapshot.rows.other }
    private var historyItems: [DeskItem] { snapshot.rows.history }
    private var historyExecutions: [WorkshopExecution.WorkshopExecutionRecord] { snapshot.rows.executions }

    var boardIsEmpty: Bool {
        blockedItems.isEmpty && watchItems.isEmpty && otherItems.isEmpty
            && snapshot.jobs.isEmpty
    }

    // MARK: finished work
    /// Show the execution's own result or state plainly that it wrote none.
    private static func resultText(_ execution: WorkshopExecution.WorkshopExecutionRecord) -> String {
        switch execution.result {
        case .string(let value) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .null:
            return "It finished without writing down a result."
        default:
            do { return try execution.result.serialize(pretty: true) }
            catch { return UserFacingError.message(error, action: "show the result") }
        }
    }

    // MARK: the rest of the board — one quiet line of counts
    private struct FoldCount: Identifiable {
        let id: String
        /// The short count on the line.
        let label: String
        /// The fold's own sentence: its header when open, and its spoken name.
        let title: String
    }

    /// Count populated folds; the timer fold stays reachable even on an empty board.
    private var foldCounts: [FoldCount] {
        var out: [FoldCount] = []
        if !otherItems.isEmpty {
            out.append(FoldCount(id: Fold.other, label: "\(otherItems.count) other items",
                                 title: "Other work and pursuits"))
        }
        let history = historyItems.count + historyExecutions.count
        if history > 0 {
            out.append(FoldCount(id: Fold.history, label: "\(history) in history", title: "Finished history"))
        }
        if !blockedItems.isEmpty {
            let count = blockedItems.count
            out.append(FoldCount(
                id: Fold.blocked,
                label: "\(count) blocked",
                title: "\(DeskPageWords.spelled(count)) \(DeskPageWords.plural(count, "thing is", "things are")) blocked"))
        }
        if !watchItems.isEmpty {
            let count = watchItems.count
            out.append(FoldCount(
                id: Fold.watching,
                label: "\(count) on watch",
                title: "I'm keeping an eye on \(DeskPageWords.spelledLower(count)) \(DeskPageWords.plural(count, "thing", "things"))"))
        }
        let jobs = snapshot.jobs
        let running = jobs.filter(\.enabled).count + timedBots.count
        var timer = running == 0 ? "nothing on a timer" : "\(running) on a timer"
        if !missedBots.isEmpty {
            timer += ", \(missedBots.count) \(DeskPageWords.plural(missedBots.count, "missed run", "missed runs"))"
        }
        out.append(FoldCount(
            id: Fold.schedule,
            label: timer,
            title: DeskPageContent.scheduleHeadline(jobs, missed: missedBots.count, bots: timedBots.count)))
        let stale = staleItems.count
        if stale > 0 {
            // An update returns stale items to watch; they need no clearing action.
            out.append(FoldCount(
                id: Fold.stale,
                label: "\(stale) quiet for a week",
                title: "\(DeskPageWords.spelled(stale)) \(DeskPageWords.plural(stale, "item hasn't", "items haven't")) moved in a week"))
        }
        return out
    }

    @ViewBuilder
    var foldsSection: some View {
        let counts = foldCounts
        VStack(alignment: .leading, spacing: 12) {
            // Separate flow items keep wrapped counts free of leading separators.
            AliveFlow(spacing: 18, lineSpacing: 6) {
                ForEach(Array(counts.enumerated()), id: \.element.id) { index, count in
                    foldCountButton(count, first: index == 0)
                }
            }
            // Each open fold opens under the line, in the line's order.
            ForEach(counts.filter { openFolds.contains($0.id) }) { count in
                openFold(count)
            }
        }
    }

    private func foldCountButton(_ count: FoldCount, first: Bool) -> some View {
        let isOpen = openFolds.contains(count.id)
        return Button { toggleFold(count.id) } label: {
            Text(first ? TodayWords.capitalizedFirst(count.label) : count.label)
                .foregroundStyle(isOpen ? NativeAgentShell.text : NativeAgentShell.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.title)
        .accessibilityValue(isOpen ? "Open" : "Folded")
        .accessibilityIdentifier(foldIdentifier(count.id))
        .font(.system(size: 13))
    }

    private func foldIdentifier(_ key: String) -> String {
        switch key {
        case Fold.stale: "desk.stale-line"
        default: "desk.fold.\(key)"
        }
    }

    func toggleFold(_ key: String) {
        withAnimation(NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)) {
            if openFolds.contains(key) { openFolds.remove(key) } else { openFolds.insert(key) }
        }
    }

    /// A fold's sentence closes it; its bounded rows appear below.
    private func openFold(_ count: FoldCount) -> some View {
        AliveGroupCard {
            Button { toggleFold(count.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(count.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Folds this away")
            .accessibilityIdentifier("desk.fold")
            foldContent(count.id)
        }
        .transition(NativeAgentMotion.arrivalFade)
    }

    @ViewBuilder
    private func foldContent(_ key: String) -> some View {
        switch key {
        case Fold.other:
            ForEach(cap(otherItems, key: key), id: \.handle) { item in itemDetailRow(item) }
            overflowLine(otherItems.count, key: key)
        case Fold.history:
            ForEach(cap(historyItems, key: key), id: \.handle) { item in itemDetailRow(item) }
            overflowLine(historyItems.count, key: key)
            ForEach(cap(historyExecutions, key: "execution-history"), id: \.id) { execution in
                let meta = execution.verification.map(DeskExecutionPresentation.verificationLabel)
                    ?? DeskExecutionPresentation.pill(for: execution.status).label
                // Opens the canonical record, which shows the whole result.
                Button {
                    overviewSelection = WorkOverviewRead.row(for: execution, now: now)
                } label: {
                    DeskPageDetailRow(title: execution.title, line: Self.resultText(execution), meta: meta)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            overflowLine(historyExecutions.count, key: "execution-history")
        case Fold.blocked:
            ForEach(cap(blockedItems, key: key), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: DeskPageContent.itemDetail(item, in: items),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
                    .contextMenu { Button("Details and actions") { inspect(item.handle) } }
            }
            overflowLine(blockedItems.count, key: key)
        case Fold.watching:
            ForEach(cap(watchItems, key: key), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: TodayWords.line(item.summary ?? item.project, limit: 96),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
                    .contextMenu { Button("Details and actions") { inspect(item.handle) } }
            }
            overflowLine(watchItems.count, key: key)
        case Fold.schedule:
            scheduleContent
        case Fold.stale:
            ForEach(cap(staleItems, key: key), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: TodayWords.line(item.summary ?? item.project, limit: 96),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
                    .contextMenu { Button("Details and actions") { inspect(item.handle) } }
            }
            overflowLine(staleItems.count, key: key)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scheduleContent: some View {
        ForEach(timedBots) { bot in
            DeskPageDetailRow(
                title: TodayWords.line(bot.name, limit: 110),
                line: bot.line,
                meta: bot.nextRun.map { DeskRelativeTimePresentation.text(for: $0, now: now) } ?? "")
        }
        ForEach(missedBots) { bot in
            DeskPageDetailRow(
                title: TodayWords.line(bot.name, limit: 110),
                line: bot.line,
                meta: BotsShelfRecord.shortDate(bot.dueAt))
        }
        ForEach(snapshot.jobs) { job in
            DeskPageDetailRow(
                title: TodayWords.line(job.name, limit: 110),
                line: DeskPageContent.scheduleLine(job),
                meta: job.nextRunAt.map {
                    DeskRelativeTimePresentation.text(forISO: $0, now: now)
                } ?? "")
        }
        Button("Open the schedule") { sheet = .schedule }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("desk.open-schedule")
    }

    // MARK: pieces
    private func cap<T>(_ rows: [T], key: String) -> [T] {
        Array(rows.prefix(revealCounts[key] ?? DeskPageMetrics.foldRowCap))
    }

    @ViewBuilder
    private func overflowLine(_ total: Int, key: String) -> some View {
        let visible = revealCounts[key] ?? DeskPageMetrics.foldRowCap
        if total > visible {
            Button("Show \(min(total - visible, DeskPageMetrics.foldRowCap)) more") {
                revealCounts[key] = visible + DeskPageMetrics.foldRowCap
            }
                .buttonStyle(.plain)
                .font(.system(size: DeskPageMetrics.metaSize))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("desk.show-more.\(key)")
        }
    }

    private func itemDetailRow(_ item: DeskItem) -> some View {
        Button { inspect(item.handle) } label: {
            DeskPageDetailRow(title: DeskPageContent.title(item),
                              line: DeskPageContent.itemDetail(item, in: items),
                              meta: "\(item.status.displayLabel) · \(item.project)")
        }
        .buttonStyle(.plain)
        .id("desk:\(item.handle)")
    }

    private var missedBots: [DeskMissedBot] { snapshot.missedBots }
    private var timedBots: [DeskTimedBot] { snapshot.timedBots }
}
