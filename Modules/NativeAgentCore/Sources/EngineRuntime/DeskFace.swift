import AgentConversations
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
import StandingBots
// Blueprint: | `DeskFace.swift` | Desk's board, attention, timers and reminders as one face over the retained Desk revision |

@MainActor extension NativeAgentEngine {
    @MainActor func deskFace() async throws -> (PartFace, UInt64) {
        if desk.faceDidChange == nil {
            desk.faceDidChange = { [weak self] in
                Task { @MainActor [weak self] in _ = await self?.pages.refresh(page: "desk") }
            }
        }
        let snapshot = await desk.loadPage()
        try Task.checkCancellation()
        guard let board = snapshot.board else {
            throw PartCallError(code: "desk_unavailable", message: "The Desk has not returned a board reading.")
        }
        return (deskFace(snapshot), board.revision)
    }

    @MainActor func deskFace(_ snapshot: DeskPageSnapshot) -> PartFace {
        var sections = deskItemFace(snapshot)
        let tools: [PartFace.Action] = [.init(id: "refresh", label: "Refresh"), .init(id: "find-item", label: "Find item"),
            .init(id: "new-task", label: "New task"),
            .init(id: "schedule", label: "Open the schedule"), .init(id: "research", label: "Look something up")]
        sections.append(.init(id: "desk-tools", style: .flow, rows: tools.map {
            .init(id: "desk:" + $0.id, title: $0.label, actions: [$0])
        }))
        var gaps = [snapshot.deskUnavailable, snapshot.agentJobs.unavailableReason, snapshot.nagConfigError,
                    snapshot.botScheduleError, desk.liveUpdateError, desk.jobsFeedState?.failureDetail]
            .compactMap { $0 }
        gaps += snapshot.overview?.unavailable ?? []
        if case .unavailable(let reason) = snapshot.rows.activity { gaps.append("Live activity: " + reason) }
        if !snapshot.loaded { gaps.append("The Desk has not been read.") }
        if desk.jobsFeedState == nil { gaps.append("The schedule has not returned a reading.") }
        if !gaps.isEmpty {
            sections.append(.init(id: "source-gaps", title: "Unavailable readings", style: .note,
                rows: Array(Set(gaps)).sorted().enumerated().map {
                    .init(id: "source-gap:\($0.offset)", title: $0.element, tone: .attention)
                }))
        }
        if case .rows(let activity) = snapshot.rows.activity {
            sections.append(.init(id: "live-reading", title: "Live activity", style: .timeline, rows: [
                .init(id: "live-reading", title: activity.isStale ? "This reading is stale." : "Board reading",
                    at: snapshot.generatedTs, tone: activity.isStale ? .attention : .quiet),
            ]))
        }
        let evidence = DeskMovementPresentation.evidence(snapshot.agentJobs.items)
        let items = DeskAttentionStrip.sortedDeskItems(snapshot.boardItems)
        let parked = Set(snapshot.rows.projects.filter(\.parked).map(\.id))
        func group(_ item: DeskItem) -> String {
            if item.status.isTerminal {
                guard let closed = item.closedAt.flatMap(UserDisplayFormatters.parseISOTimestamp) else { return "history" }
                return Calendar.current.isDate(closed, inSameDayAs: snapshot.now) ? "done-today" : "history"
            }
            if item.requiresOwnerInput || [.blocked, .flag].contains(item.status) { return "waiting" }
            if DeskSequencing.isDeferred(item, now: snapshot.now) || parked.contains(item.handle) { return "parked" }
            let activity = DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: snapshot.now)
            if activity == .working || item.status == .now { return "now" }
            if item.status == .watch || item.kind == .watch { return "watching" }
            return "queued"
        }
        for (id, title) in [("now", "Now"), ("waiting", "Waiting"), ("queued", "Queued"), ("watching", "Watching"),
                            ("parked", "Parked"), ("done-today", "Done today"), ("history", "Finished history")] {
            let rows = items.filter { group($0) == id }.map { item in
                let activity = DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: snapshot.now)
                let project = snapshot.rows.projects.first { $0.id == item.handle }
                var detail = [item.project, project?.line ?? DeskPageContent.itemDetail(item, in: items), activity.label]
                if let plan = snapshot.plan.byHandle[item.handle], plan.totalCount > 0 {
                    detail.append("\(plan.doneCount) of \(plan.totalCount) closed")
                }
                return PartFace.Row(id: item.handle, title: DeskPageContent.title(item), detail: detail.joined(separator: " · "),
                    value: item.status.displayLabel, at: item.updatedAt, tone: Self.deskTone(activity, item: item),
                    open: "page:desk/" + item.handle, actions: Array(Self.deskItemActions(item).prefix(3)))
            }
            if !rows.isEmpty { sections.append(.init(id: id, title: title, style: .list, rows: rows)) }
        }
        if items.isEmpty, snapshot.board?.deskState != nil, snapshot.deskUnavailable == nil {
            sections.append(.init(id: "empty-board", style: .note, rows: [.init(id: "empty", title: "No items on the board.")]))
        }
        sections += deskOverviewFace(snapshot)
        let jobs = snapshot.agentJobs.items.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        if !jobs.isEmpty {
            sections.append(.init(id: "lines", title: "Work and finished lines", style: .timeline, rows: jobs.map { job in
                let row = WorkOverviewRead.row(for: job, now: snapshot.now)
                return .init(id: row.id, title: row.title, detail: row.summary, value: row.stateLabel(at: snapshot.now), at: row.updatedAt,
                    tone: job.state.isTerminal ? .done : job.state == .needsYou ? .attention : .plain,
                    actions: [.init(id: "inspect", label: "Read details")])
            }))
        }
        sections.append(deskScheduleFace(snapshot))
        sections.append(deskRemindersFace(snapshot))
        if case .line(let text, let symbol, let at) = snapshot.wanderHour {
            // The wander hour's closing line, as the Mac's Desk showed it: no title of its own.
            sections.append(.init(id: "wander-hour", style: .timeline, rows: [.init(id: "wander-hour", title: text, at: at, symbol: symbol)]))
        }
        return PartFace(title: "Desk", line: snapshot.overview?.headline, sections: sections)
    }

    static func deskTone(_ activity: DeskActivityState, item: DeskItem? = nil) -> PartFace.Tone {
        if item?.requiresOwnerInput == true || item?.status == .flag { return .attention }
        switch activity {
        case .working: return .live
        case .blocked, .stale: return .attention
        case .finished: return .done
        case .queued: return .plain
        case .watching, .deferred, .unknown: return .quiet
        }
    }

    static func deskItemActions(_ item: DeskItem) -> [PartFace.Action] {
        guard !item.status.isTerminal else { return [] }
        var actions: [PartFace.Action] = [
            .init(id: "reply", label: item.requiresOwnerInput ? "Reply" : "Discuss"),
            .init(id: "close", label: item.requiresOwnerInput ? "Already handled" : "Close", role: .destructive),
            .init(id: "note", label: "Note"),
        ]
        if item.deferUntil != nil { actions.append(.init(id: "unpark", label: "Un-park")) }
        if DeskBoardLayout.isPursuitLaneItem(item), item.pursuit != nil {
            actions.append(.init(id: "veto", label: "Veto", role: .destructive))
        }
        return actions
    }

    private func deskOverviewFace(_ snapshot: DeskPageSnapshot) -> [PartFace.Section] {
        guard let overview = snapshot.overview else { return [] }
        let boardHandles = Set(snapshot.boardItems.map(\.handle))
        return [("work-now", "Other work now", overview.now, overview.omittedNow),
                ("attention", "Needs you", overview.needsYou, overview.omittedNeedsYou),
                ("recent-work", "Recently done", overview.recentlyDone, overview.omittedRecentlyDone)].compactMap { id, title, source, omitted in
            let rows = source.filter {
                $0.reference.kind != .execution && ($0.reference.kind != .desk || !boardHandles.contains($0.reference.id))
            }.map { row in
                let link: String? = switch row.reference.kind {
                case .approval: "approval:" + row.reference.id
                case .inbox: "card:" + row.reference.id
                case .desk: "page:desk/" + row.reference.id
                case .execution: nil
                }
                return PartFace.Row(id: row.id, title: row.title, detail: row.summary, value: row.stateLabel(at: snapshot.now),
                    at: row.updatedAt, tone: id == "attention" ? .attention : id == "recent-work" ? .done : .plain, open: link)
            }
            guard !rows.isEmpty || omitted > 0 else { return nil }
            return .init(id: id, title: title, style: .timeline,
                footer: omitted > 0 ? "\(omitted) more items remain in the board, Activity and history." : nil, rows: rows)
        }
    }

    private func deskScheduleFace(_ snapshot: DeskPageSnapshot) -> PartFace.Section {
        var rows: [PartFace.Row] = snapshot.timedBots.map {
            .init(id: "timer-bot:" + $0.id.uuidString, title: $0.name, detail: $0.line,
                at: $0.nextRun.map(NativeTimestampFormat.fractionalZulu), open: "page:bots")
        }
        rows += snapshot.missedBots.map {
            .init(id: "missed-bot:" + $0.id.uuidString, title: $0.name, detail: $0.line,
                at: NativeTimestampFormat.fractionalZulu($0.dueAt), tone: .attention, open: "page:bots")
        }
        rows += snapshot.jobs.map {
            .init(id: "timer-job:" + $0.id, title: $0.name, detail: DeskPageContent.scheduleLine($0), at: $0.nextRunAt,
                tone: $0.enabled ? .plain : .quiet)
        }
        if rows.isEmpty, snapshot.botScheduleError == nil, let feed = desk.jobsFeedState, case .current = feed {
            rows.append(.init(id: "no-timers", title: "Nothing on a timer."))
        }
        return .init(id: "schedule", title: "On a timer", style: .list, rows: rows)
    }

    private func deskRemindersFace(_ snapshot: DeskPageSnapshot) -> PartFace.Section {
        guard snapshot.nagConfigError == nil else {
            return .init(id: "reminders", title: "Reminders", style: .note,
                rows: [.init(id: "reminders-unavailable", title: "Reminder settings could not be read.", tone: .attention)])
        }
        let config = snapshot.nagConfig
        let muted = config.isMuted(now: snapshot.now)
        var rows: [PartFace.Row] = [
            .init(id: "nag:global", title: "Nag me", detail: "Off silences every project's reminders.", control: .toggle(config.enabled)),
            .init(id: "nag:mute", title: muted ? "Snoozed" : "Snooze",
                value: muted && config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel ? "Indefinitely" : nil,
                at: muted && config.mutedUntil != DeskNagConfig.indefiniteMuteSentinel
                    ? config.mutedUntil.flatMap(DeskSequencing.parseDeferStamp).map(NativeTimestampFormat.fractionalZulu) : nil,
                actions: muted ? [.init(id: "unmute", label: "Wake up")]
                    : [.init(id: "mute:indefinitely", label: "Indefinitely")]),
        ]
        if !muted {
            rows += DeskDeferPreset.allCases.map { preset in
                .init(id: "nag:mute:" + preset.rawValue, title: "Snooze until",
                    at: DeskSequencing.parseDeferStamp(preset.day(from: snapshot.now)).map(NativeTimestampFormat.fractionalZulu),
                    actions: [.init(id: "mute:" + preset.rawValue, label: "Snooze")])
            }
        }
        rows += DeskNagPanelModel.lanes(items: snapshot.boardItems, config: config).map {
            .init(id: "nag:project:" + $0.project, title: $0.project, value: "\($0.itemCount) live items", control: .toggle($0.enabled))
        }
        if let item = snapshot.boardItems.first(where: { $0.handle == desk.faceItem }) {
            let enabled = config.scopes.first { $0.kind == .item && $0.id == item.handle }?.enabled == true
            rows.append(.init(id: "nag:item:" + item.handle, title: "Just this item", detail: item.title, control: .toggle(enabled)))
        }
        return .init(id: "reminders", title: "Reminders", style: .values,
            footer: muted ? "Muted — still tracking, nothing will ping."
                : DeskNagPanelModel.summary(config, items: snapshot.boardItems, now: snapshot.now), rows: rows)
    }
}
