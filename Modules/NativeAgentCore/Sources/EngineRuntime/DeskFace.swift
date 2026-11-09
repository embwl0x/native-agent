import AgentConversations
import AuthoredCapabilities
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
import StandingBots
import TriggerScheduler
// Blueprint: | `DeskFace.swift` | The Desk packet `native-desk` draws: the Desk revision's facts, its rows' keys, the Reminders levers and Veto key levers |

extension NativeAgentEngine {
    @concurrent func deskPacket() async throws -> PartFaces.Packet {
        let snapshot = await desk.loadPage()
        let state = await MainActor.run {
            var scheduleCurrent = false
            if case .some(.current) = desk.timesFeedState { scheduleCurrent = true }
            return (selected: desk.faceItem, liveError: desk.liveUpdateError, scheduleError: desk.timesFeedState?.failureDetail,
                    scheduleRead: desk.timesFeedState != nil, scheduleCurrent: scheduleCurrent)
        }
        try Task.checkCancellation()
        guard let board = snapshot.board else {
            throw PartCallError(code: "desk_unavailable", message: "The Desk has not returned a board reading.")
        }
        var facts = deskFacts(snapshot, liveError: state.liveError, scheduleError: state.scheduleError,
                              scheduleRead: state.scheduleRead, scheduleCurrent: state.scheduleCurrent)
        facts["night"] = .object(await nextNightReading())
        facts["selected"] = deskSelectedFacts(snapshot, selected: state.selected)
        facts["keys"] = deskKeys(snapshot, selected: state.selected)
        // The board revision orders reads; a selection or a clock edge changes the facts at one revision, and the face is drawn again.
        let levers = deskLevers(snapshot, selected: state.selected)
        return PartFaces.Packet(facts: .object(facts), epoch: board.revision, levers: levers.page, keyLevers: levers.keyed)
    }

    /// What a Desk item's row may do, in the order the Desk offers it, and what each does; `veto` is the person's lever, drawn by the stem.
    static func deskItemActions(_ item: DeskItem) -> [PageKeyAction] {
        guard !item.status.isTerminal else { return [] }
        let handle = PartFace.Value.string(item.handle)
        var actions: [PageKeyAction] = [
            .mac("reply", opens: DeskMacPlace.reply(item.handle).link),
            .calls("close", role: .destructive, "desk.close", ["handle": handle, "reason": .string(DeskQuickAction.deskCloseOutcome),
                "expected_updated_at": .string(item.updatedAt)]),
            .mac("note", opens: DeskMacPlace.note(item.handle).link),
        ]
        if item.deferUntil != nil { actions.append(.calls("unpark", "desk.defer", ["handle": handle, "until": .string("")])) }
        if DeskBoardLayout.isPursuitLaneItem(item), item.pursuit != nil {
            actions.append(.calls("veto", role: .destructive, "desk.veto", ["handle": handle]))
        }
        return actions
    }

    /// The person's say over the agent on the Desk: the Reminders section (page levers, drawn first) and Veto on each pursuit the
    /// Desk offers it on (key levers on the pursuit's row and on the selected item's Veto row).
    func deskLevers(_ snapshot: DeskPageSnapshot, selected: String?) -> (page: [PartFace.Section], keyed: [PartFace.Section]) {
        func veto(_ item: DeskItem) -> PartFace.Action? {
            Self.deskItemActions(item).first { $0.id == "veto" }.map { PartFace.Action(id: "veto", label: "Veto", role: .destructive, call: $0.call) }
        }
        var rows: [PartFace.Row] = snapshot.boardItems.compactMap { item in
            veto(item).map { PartFace.Row(id: item.handle, title: item.title, actions: [$0]) }
        }
        if let handle = selected, let item = snapshot.boardItems.first(where: { $0.handle == handle }), let action = veto(item) {
            rows.append(.init(id: "item-action:veto", title: "Veto", actions: [action]))
        }
        return ([deskReminders(snapshot, selected: selected)], rows.isEmpty ? [] : [.init(id: "veto", title: "Pursuits", rows: rows)])
    }

    private func deskReminders(_ snapshot: DeskPageSnapshot, selected: String?) -> PartFace.Section {
        guard snapshot.nagConfigError == nil else {
            return .init(id: "reminders", title: "Reminders", style: .note,
                rows: [.init(id: "reminders-unavailable", title: "Reminder settings could not be read.", tone: .attention)])
        }
        let config = snapshot.nagConfig
        let muted = config.isMuted(now: snapshot.now)
        // Each switch calls desk.remind with its scope (its new value arrives as value); snoozing and waking call desk.nag.
        func remind(_ kind: String, _ id: String? = nil) -> PartFace.Call {
            var args: [String: PartFace.Value] = ["scope_kind": .string(kind)]
            if let id { args["scope_id"] = .string(id) }
            return .init("desk.remind", args)
        }
        func nag(_ action: String, until: String? = nil) -> PartFace.Call {
            var args: [String: PartFace.Value] = ["action": .string(action)]
            if let until { args["until"] = .string(until) }
            return .init("desk.nag", args)
        }
        var rows: [PartFace.Row] = [
            .init(id: "nag:global", title: "Nag me", detail: "Off silences every project's reminders.",
                control: .toggle(config.enabled, call: remind("global"))),
            .init(id: "nag:mute", title: muted ? "Snoozed" : "Snooze",
                value: muted && config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel ? "Indefinitely" : nil,
                at: muted && config.mutedUntil != DeskNagConfig.indefiniteMuteSentinel
                    ? config.mutedUntil.flatMap(DeskSequencing.parseDeferStamp).map(NativeTimestampFormat.fractionalZulu) : nil,
                actions: muted ? [.init(id: "unmute", label: "Wake up", call: nag("unmute"))]
                    : [.init(id: "mute:indefinitely", label: "Indefinitely", call: nag("mute"))]),
        ]
        if !muted {
            rows += DeskDeferPreset.allCases.map { preset -> PartFace.Row in
                let day = preset.day(from: snapshot.now)
                return PartFace.Row(id: "nag:mute:" + preset.rawValue, title: "Snooze until",
                    at: DeskSequencing.parseDeferStamp(day).map(NativeTimestampFormat.fractionalZulu),
                    actions: [.init(id: "mute:" + preset.rawValue, label: "Snooze", call: nag("mute", until: day))])
            }
        }
        let lanes = DeskNagPanelModel.lanes(items: snapshot.boardItems, config: config)
        rows += lanes.map {
            .init(id: "nag:project:" + $0.project, title: $0.project, value: "\($0.itemCount) live items",
                control: .toggle($0.enabled, call: remind("project", $0.project)))
        }
        if let item = snapshot.boardItems.first(where: { $0.handle == selected }) {
            let enabled = config.scopes.first { $0.kind == .item && $0.id == item.handle }?.enabled == true
            rows.append(.init(id: "nag:item:" + item.handle, title: "Just this item", detail: item.title,
                control: .toggle(enabled, call: remind("item", item.handle))))
        }
        // Folded, the section's one row says the state its rows hold: off, snoozed (until when), or on with the projects kept quiet.
        var state = ["Reminders"]
        if !config.enabled { state.append("off") }
        else if muted {
            let until = config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel ? nil
                : config.mutedUntil.flatMap(DeskSequencing.parseDeferStamp)
            state.append(until.map { "snoozed until " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "snoozed indefinitely")
        } else {
            state.append("on")
            let quiet = lanes.filter { !$0.enabled }.count
            if quiet > 0 { state.append("\(quiet) \(quiet == 1 ? "project" : "projects") quiet") }
        }
        return .init(id: "reminders", title: state.joined(separator: " · "), style: .values,
            footer: muted ? "Muted — still tracking, nothing will ping."
                : DeskNagPanelModel.summary(config, items: snapshot.boardItems, now: snapshot.now), rows: rows, folded: true)
    }

    /// Every key a Desk row may carry: where it leads, what it may do and what each action does (a door call, or a place only the Mac's
    /// Desk view opens). The face draws a row's link and actions from its key.
    func deskKeys(_ snapshot: DeskPageSnapshot, selected: String?) -> JSONValue {
        var keys: [String: JSONValue] = [:]
        func key(_ id: String, open: String? = nil, _ actions: [PageKeyAction] = []) {
            var entry: [String: JSONValue] = [:]
            if let open, PartFace.isLink(open) { entry["open"] = .string(open) }
            if !actions.isEmpty { entry["actions"] = .array(actions.map(\.json)) }
            if !entry.isEmpty { keys[id] = .object(entry) }
        }
        key("desk:refresh", [.calls("refresh", "desk.refresh")])
        key("desk:find-item", [.mac("find-item", opens: DeskMacPlace.findItem.link)])
        key("desk:new-task", [.mac("new-task", opens: DeskMacPlace.newTask.link)])
        key("desk:research", [.mac("research", opens: DeskMacPlace.research.link)])
        for item in snapshot.boardItems {
            key(item.handle, open: "page:desk/" + item.handle, Array(Self.deskItemActions(item).filter { $0.id != "veto" }.prefix(3)))
        }
        if let overview = snapshot.overview {
            for row in overview.now + overview.needsYou + overview.recentlyDone {
                switch row.reference.kind {
                case .approval: key(row.id, open: "approval:" + row.reference.id)
                case .inbox: key(row.id, open: "card:" + row.reference.id)
                case .desk: key(row.id, open: "page:desk/" + row.reference.id)
                case .execution: break
                }
            }
        }
        for job in snapshot.agentJobs.items {
            let row = WorkOverviewRead.row(for: job, now: snapshot.now).id
            key(row, [.mac("inspect", opens: DeskMacPlace.inspect(row).link)])
        }
        for bot in snapshot.timedBots { key("timer-bot:" + bot.id.uuidString, open: "page:bots") }
        for bot in snapshot.missedBots { key("missed-bot:" + bot.id.uuidString, open: "page:bots") }
        guard let handle = selected else { return .object(keys) }
        key("desk-selection", [.mac("board", opens: DeskMacPlace.board.link)])
        guard !handle.hasPrefix("execution:"), let item = snapshot.items.first(where: { $0.handle == handle }) else { return .object(keys) }
        for blocker in snapshot.plan.byHandle[item.handle]?.effectiveBlockers ?? [] where snapshot.items.contains(where: { $0.handle == blocker }) {
            key("blocker:" + blocker, open: "page:desk/" + blocker)
        }
        for ref in item.refs {
            switch DeskRefAffordance.action(for: ref) {
            case .open(let url, _) where PartFace.isLink("url:" + url): key("ref:" + ref.refId, open: "url:" + url)
            case .open, .copy: key("ref:" + ref.refId, [.mac("copy-reference", opens: DeskMacPlace.copy(ref.refId).link)])
            }
        }
        guard snapshot.boardItems.contains(where: { $0.handle == handle }) else { return .object(keys) }
        for action in Self.deskItemActions(item) where action.id != "veto" { key("item-action:" + action.id, [action]) }
        if !item.status.isTerminal {
            for preset in DeskDeferPreset.allCases {
                key("item-action:defer:" + preset.rawValue, [.calls("defer:" + preset.rawValue, "desk.defer",
                    ["handle": .string(item.handle), "until": .string(preset.day(from: snapshot.now))])])
            }
        }
        return .object(keys)
    }

    /// The Desk's measured facts: the board's items with what groups them, live activity, the overview, work lines, timers and named gaps.
    private func deskFacts(_ snapshot: DeskPageSnapshot, liveError: String?, scheduleError: String?,
                           scheduleRead: Bool, scheduleCurrent: Bool) -> [String: JSONValue] {
        let now = snapshot.now
        let evidence = DeskMovementPresentation.evidence(snapshot.agentJobs.items)
        let items: [JSONValue] = snapshot.boardItems.map { item -> JSONValue in
            let closed = item.closedAt.flatMap(UserDisplayFormatters.parseISOTimestamp)
            var plan = JSONValue.null
            if let sequenced = snapshot.plan.byHandle[item.handle] {
                plan = .object(["done": .int(Int64(sequenced.doneCount)), "total": .int(Int64(sequenced.totalCount)),
                                "blockers": .array(sequenced.effectiveBlockers.map(JSONValue.string)), "cycle": .bool(sequenced.blockedByCycle),
                                "deferred": .bool(sequenced.isDeferred), "ready": .bool(sequenced.isReady)])
            }
            return .object([
                "handle": .string(item.handle), "alias": .string(item.alias), "kind": .string(item.kind.rawValue),
                "status": .string(item.status.rawValue), "project": .string(item.project), "title": .string(item.title),
                "summary": faceText(item.summary), "origin": .string(item.origin.rawValue), "parent": faceText(item.parent),
                "laneOf": faceText(item.laneOf), "updatedAt": .string(item.updatedAt), "openedAt": .string(item.openedAt),
                "closedToday": .bool(closed.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false),
                "requiresOwnerInput": .bool(item.requiresOwnerInput), "deferred": .bool(DeskSequencing.isDeferred(item, now: now)),
                "activity": .string(DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now).rawValue),
                "waitingOn": faceText(item.waitingOn), "blockedReason": faceText(item.blockedReason),
                "blockedOn": .array(item.blockedOn.map(JSONValue.string)), "lastNote": faceText(item.notes.last?.text),
                "parked": .bool(snapshot.rows.parked.contains(item.handle)), "plan": plan,
            ])
        }
        let activity: JSONValue = switch snapshot.rows.activity {
        case .rows(let content): .object(["state": .string("rows"), "stale": .bool(content.isStale), "reason": .null])
        case .quiet: .object(["state": .string("quiet"), "stale": .null, "reason": .null])
        case .unavailable(let reason): .object(["state": .string("unavailable"), "stale": .null, "reason": .string(reason)])
        }
        func overviewRows(_ rows: [WorkOverviewRow], omitted: Int) -> JSONValue {
            .object(["omitted": .int(Int64(omitted)), "rows": .array(rows.map { row -> JSONValue in
                .object(["id": .string(row.id), "kind": .string(row.reference.kind.rawValue), "ref": .string(row.reference.id),
                         "title": .string(row.title), "summary": .string(row.summary), "state": .string(row.stateLabel(at: now)),
                         "at": .string(row.updatedAt)])
            })])
        }
        let overview: JSONValue = snapshot.overview.map { reading -> JSONValue in
            .object(["now": overviewRows(reading.now, omitted: reading.omittedNow),
                     "needsYou": overviewRows(reading.needsYou, omitted: reading.omittedNeedsYou),
                     "recentlyDone": overviewRows(reading.recentlyDone, omitted: reading.omittedRecentlyDone)])
        } ?? .null
        let jobs: [JSONValue] = snapshot.agentJobs.items.map { job -> JSONValue in
            let row = WorkOverviewRead.row(for: job, now: now)
            return .object(["id": .string(row.id), "title": .string(row.title), "summary": .string(row.summary),
                            "state": .string(row.stateLabel(at: now)), "at": .string(row.updatedAt),
                            "terminal": .bool(job.state.isTerminal), "needsYou": .bool(job.state == .needsYou)])
        }
        let wander: JSONValue = switch snapshot.wanderHour {
        case .absent: .null
        case .line(let text, let symbol, let at): .object(["text": .string(text), "symbol": .string(symbol), "at": faceText(at)])
        }
        let timed: [JSONValue] = snapshot.timedBots.map { bot -> JSONValue in
            .object(["id": .string(bot.id.uuidString), "name": .string(bot.name), "line": .string(bot.line),
                     "at": faceText(bot.nextRun.map(NativeTimestampFormat.fractionalZulu))])
        }
        let missed: [JSONValue] = snapshot.missedBots.map { bot -> JSONValue in
            .object(["id": .string(bot.id.uuidString), "name": .string(bot.name), "line": .string(bot.line),
                     "at": .string(NativeTimestampFormat.fractionalZulu(bot.dueAt))])
        }
        let timers: [JSONValue] = snapshot.times.map { time -> JSONValue in
            let interval = time.rhythm.flatMap(SchedulerJobNormalizer.rhythmInterval).map { JSONValue.int(Int64($0)) } ?? .null
            let once = time.rhythm == nil ? "Once at \(time.next.formatted(date: .abbreviated, time: .shortened))." : nil
            return .object(["id": .string(time.id), "name": .string(Self.timerName(time)), "at": .string(NativeTimestampFormat.fractionalZulu(time.next)),
                            "enabled": .bool(true), "once": faceText(once), "intervalSeconds": interval])
        }
        let presets: [JSONValue] = DeskDeferPreset.allCases.map { preset -> JSONValue in
            .object(["id": .string(preset.rawValue),
                     "at": faceText(DeskSequencing.parseDeferStamp(preset.day(from: now)).map(NativeTimestampFormat.fractionalZulu))])
        }
        return [
            "day": .string(DeskClock.dayStamp(now)),
            "headline": faceText(snapshot.overview?.headline),
            "loaded": .bool(snapshot.loaded),
            "boardRead": .bool(snapshot.board?.deskState != nil),
            "generatedAt": faceText(snapshot.generatedTs),
            "unavailable": .object([
                "desk": faceText(snapshot.deskUnavailable), "jobs": faceText(snapshot.agentJobs.unavailableReason),
                "reminders": faceText(snapshot.nagConfigError), "helpers": faceText(snapshot.botScheduleError),
                "liveUpdates": faceText(liveError), "schedule": faceText(scheduleError),
                "overview": .array((snapshot.overview?.unavailable ?? []).map(JSONValue.string)),
            ]),
            "scheduleRead": .bool(scheduleRead),
            "scheduleCurrent": .bool(scheduleCurrent),
            "activity": activity,
            "items": .array(items),
            "overview": overview,
            "jobs": .array(jobs),
            "timedHelpers": .array(timed),
            "missedHelpers": .array(missed),
            "timers": .array(timers),
            "deferPresets": .array(presets),
            "wanderHour": wander,
        ]
    }

    /// A clock time's name on the Desk's timer: what its owner calls it.
    static func timerName(_ time: OneClock.Time) -> String {
        let payload = time.payload?.objectValue ?? [:]
        switch time.owner {
        case "sleep": return "The night: today's dream"
        case "rem": return "Weekly REM"
        case "part": return "\(payload["part"]?.stringValue ?? time.id) wakes on \(payload["signal"]?.stringValue ?? "its schedule")"
        case SwiftNativeTriggerScheduler.clockOwner: return "Inbox trigger \(payload["name"]?.stringValue ?? time.id)"
        default: return payload["name"]?.stringValue ?? time.id
        }
    }
}

func faceText(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
