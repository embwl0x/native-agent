import PersistenceCore
import ApprovalInbox
import ApprovalTransactions
import ChatToolRuntime
import AuthoredCapabilities
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import Privacy
// Blueprint: | `InboxFace.swift` | Inbox's one face reads ForPerson's matters, put-away ones as folded history, the agent's own decisions of one kind under one row; each answer is its one door call, the person's tap and the agent's call alike |

extension NativeAgentEngine {
    @MainActor func inboxFaceRead() -> PartFaces.Read {
        let owner = ForPerson.at(dataRoot)
        inbox.faceChanges?.cancel()
        inbox.faceChanges = Task { @MainActor [weak pages] in
            for await _ in await owner.changes() {
                guard !Task.isCancelled, let pages else { return }
                await pages.refresh(page: "inbox")
            }
        }
        return { [weak self] in
            guard let self else { throw PartCallError(code: "inbox_closed", message: "The Inbox owner has closed.") }
            return try await inboxFace()
        }
    }

    @concurrent func inboxFace() async throws -> (PartFace, UInt64) {
        let now = Date()
        let epoch = UInt64(now.timeIntervalSince1970 * 1000)
        let matters = try await ForPerson.at(dataRoot).matters().filter(ForPerson.isRow)
        let active = matters.filter { [.unread, .read].contains(ForPerson.reading($0)) }
        let waiting = active.filter { $0.owes["decide"] != nil }
        let remaining = active.filter { $0.owes["decide"] == nil }
        let failed = remaining.filter { $0.face?.row?.tone == .failed }
        let news = remaining.filter { $0.face?.row?.tone != .failed }.sorted {
            let left = ForPerson.reading($0) == .unread, right = ForPerson.reading($1) == .unread
            return left != right ? left : ($0.at, $0.id) > ($1.at, $1.id)
        }
        let earlier = matters.filter {
            [.archived, .dismissed].contains(ForPerson.reading($0))
        }
        let history = await inboxHistoryRows(earlier)
        let since = now.addingTimeInterval(-24 * 60 * 60)
        let archived = earlier.filter { ForPerson.reading($0) == .archived }
        let recent = archived.filter { matter in
            guard let stamp = matter.outcome?.at ?? matter.updatedAt, let at = NativeTimestampFormat.parseISO8601(stamp) else { return false }
            return at >= since
        }
        let undated = archived.filter { matter in
            guard let stamp = matter.outcome?.at ?? matter.updatedAt else { return true }
            return NativeTimestampFormat.parseISO8601(stamp) == nil
        }.count
        // News is what happened for the person. What I decided on my own is a record, kept under its own fold so it never buries the news.
        let decided = news.filter { BodyDecidedRow.kind(of: $0) != nil }
        let told = news.filter { BodyDecidedRow.kind(of: $0) == nil }
        var sections: [PartFace.Section] = [
            .init(id: "waiting", title: "Waiting for you", style: .list,
                  footer: waiting.isEmpty ? "No requests in the current reading." : nil,
                  rows: waiting.map { inboxFaceRow($0, tone: .attention) }),
        ]
        if !failed.isEmpty {
            sections.append(.init(id: "went-wrong", title: "Went wrong", style: .list, rows: failed.map { inboxFaceRow($0, tone: .failed) }))
        }
        sections.append(.init(id: "news", title: "News", style: .list, footer: told.isEmpty ? "No news in the current reading." : nil,
                              rows: told.map { inboxFaceRow($0) }))
        if !decided.isEmpty {
            let unread = decided.filter { ForPerson.reading($0) == .unread }.count
            sections.append(.init(id: "decided", title: "What I decided on my own", style: .list,
                footer: "\(decided.count) \(decided.count == 1 ? "decision" : "decisions")" + (unread == 0 ? "." : ", \(unread) unread."),
                rows: inboxDecisionGroups(decided.map { (matter: $0, row: inboxFaceRow($0)) }, section: "news", together: true),
                folded: true))
        }
        // The history: every matter put away, newest first, folded under its counts.
        let counts = "\(recent.count) archived in the last day; \(earlier.count) put away in all."
            + (undated == 0 ? "" : " \(undated) archived matters have no settlement time; the day's count excludes those matters.")
        sections.append(.init(id: "earlier", title: "Earlier", style: .list, footer: counts,
                              rows: inboxDecisionGroups(zip(earlier, history).map { (matter: $0, row: $1) }, section: "earlier"),
                              folded: true))
        return (.init(title: "Inbox", line: "Requests, things that went wrong, and news.", sections: sections), epoch)
    }

    /// The agent's own decisions of one kind (`BodyDecidedRow.kind`) fold under one row: the first of them this section draws and how many more, with
    /// the unread count as its value. Each decision stays its own nested row, newest first, with its id and actions; a kind with one decision
    /// stays a plain row. Folding only draws: no decision is read, put away or left out.
    /// `together` puts the kind's answers on its one row (mark every unread one read, archive them all) and leaves its nested decisions to be
    /// read: a kind is answered as one thing, and the agent's reading lists the kind, not each decision.
    private func inboxDecisionGroups(_ entries: [(matter: Experience, row: PartFace.Row)], section: String,
                                     together: Bool = false) -> [PartFace.Row] {
        var kinds: [String: [(matter: Experience, row: PartFace.Row)]] = [:]
        for entry in entries {
            if let kind = BodyDecidedRow.kind(of: entry.matter) { kinds[kind, default: []].append(entry) }
        }
        var drawn: Set<String> = []
        return entries.compactMap { entry -> PartFace.Row? in
            guard let kind = BodyDecidedRow.kind(of: entry.matter), let group = kinds[kind], group.count > 1 else { return entry.row }
            guard drawn.insert(kind).inserted else { return nil }
            let unread = group.filter { ForPerson.reading($0.matter) == .unread }.count
            let newest = group.sorted { ($0.matter.at, $0.matter.id) > ($1.matter.at, $1.matter.id) }
            var actions: [PartFace.Action] = []
            if together {
                func ids(_ entries: [(matter: Experience, row: PartFace.Row)]) -> PartFace.Value { .array(entries.map { .string($0.matter.id) }) }
                let fresh = group.filter { ForPerson.reading($0.matter) == .unread }
                if !fresh.isEmpty {
                    actions.append(.init(id: "read", label: "Mark all read",
                        call: .init("inbox.mark_read", ["ids": ids(fresh), "reason": .string("read together from their Inbox row")])))
                }
                actions.append(.init(id: "archive", label: "Archive all", role: .destructive,
                    call: .init("inbox.archive", ["ids": ids(group), "reason": .string("put away together from their Inbox row")])))
            }
            return .init(id: section + ".decided." + kind, title: entry.row.title + ", and \(group.count - 1) more",
                         value: unread == 0 ? nil : "\(unread) unread", at: entry.row.at, symbol: entry.row.symbol, tone: entry.row.tone,
                         actions: actions.isEmpty ? nil : actions,
                         rows: together ? newest.map { var row = $0.row; row.actions = nil; return row } : newest.map { $0.row })
        }
    }

    /// Retained approval faces may predate their latest execution receipt. Read that saved owner once, only for history, without writing a copy.
    private func inboxHistoryRows(_ matters: [Experience]) async -> [PartFace.Row] {
        let ids = Set(matters.flatMap { $0.evidence.filter { $0.source == Matter.approvals }.map(\.id) })
        guard !ids.isEmpty else { return matters.map { inboxHistoryRow($0) } }
        do {
            let records = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .all)
            var faces: [String: Experience.Face] = [:]
            for record in records where ids.contains(record.id) && record.status != "pending" {
                faces[record.id] = record.decisionExperience.face
            }
            return matters.map { matter in
                guard let ref = matter.evidence.first(where: { $0.source == Matter.approvals }) else { return inboxHistoryRow(matter) }
                guard let face = faces[ref.id] else {
                    return inboxHistoryRow(matter, unavailable: "The approval owner has no saved settled result for \(ref.id).")
                }
                return inboxHistoryRow(matter, savedFace: face)
            }
        } catch {
            // This owner's read failure concerns its approval rows; interaction and note history still render.
            return matters.map { matter in
                inboxHistoryRow(matter, unavailable: matter.evidence.contains { $0.source == Matter.approvals }
                    ? "The saved approval result could not be read: \(NativeAppSecretRedactor.redactText(error.localizedDescription))" : nil)
            }
        }
    }

    /// A decided card leads with its owner's saved outcome, then the original request. Only continuation retry survives; consent never reopens.
    private func inboxHistoryRow(_ matter: Experience, savedFace: Experience.Face? = nil, unavailable: String? = nil) -> PartFace.Row {
        guard let face = savedFace ?? matter.face, let row = face.row else {
            return .init(id: matter.id, title: "This matter has no face row", detail: "The experience owner must supply the missing row.",
                         at: matter.at, tone: .attention)
        }
        var title = row.title
        var detail = [row.detail, face.words].compactMap { $0 }.filter { !$0.isEmpty }
        if detail.count == 2, detail[0] == detail[1] { detail.removeLast() }
        let card = face.from == InlineInteractionDelivery.source || matter.evidence.contains { $0.source == Matter.approvals }
        if card, matter.owes["decide"] != nil {
            let words = face.words.trimmingCharacters(in: .whitespacesAndNewlines)
            var receipt = words.components(separatedBy: "\n\n").filter { !$0.isEmpty }
            if let unavailable {
                title = "Unknown: the saved approval result is unavailable."
                detail = [unavailable, row.title]
            } else if !receipt.isEmpty {
                title = receipt.removeFirst()
                detail = [row.title] + receipt
                if let context = row.detail, context != face.words, !context.isEmpty { detail.append(context) }
            } else {
                title = "Unknown: no outcome words were recorded for this card."
                detail = [row.title]
            }
        }
        let retry = row.actions?.filter { $0.call?.action == "card.try_again" }
        return .init(id: matter.id, title: title, detail: detail.joined(separator: "\n\n"),
                     value: ForPerson.reading(matter).rawValue.capitalized, at: matter.at,
                     symbol: row.symbol ?? "bell.fill", tone: unavailable == nil ? row.tone : .attention,
                     actions: retry?.isEmpty == false ? retry : nil)
    }

    /// A waiting or new matter's row: the face its owner composed, each answer bound to its one door call. An answer whose owner composed its
    /// call keeps it; the Inbox's own verbs (read, archive, dismiss) and the inbox vocabulary a producer names by id take their `inbox.*`
    /// verb. An answer with no call is not drawn: a row's action always runs through the door, for the person's tap and the agent's call alike.
    private func inboxFaceRow(_ matter: Experience, tone: PartFace.Tone? = nil) -> PartFace.Row {
        let reading = ForPerson.reading(matter)
        guard let face = matter.face, let row = face.row else {
            return .init(id: matter.id, title: "This matter has no face row", detail: "The experience owner must supply the missing row.",
                         at: matter.at, tone: .attention)
        }
        let approval = matter.evidence.contains { $0.source == Matter.approvals }
        let declared = (row.actions ?? []).map { InboxActionRecord(id: $0.id, label: $0.label, description: nil) }
        let actions: [PartFace.Action] = InboxActionVocabulary.actions(declared: declared, approvalLinked: approval).compactMap { answer in
            guard answer.id != "read" || reading == .unread else { return nil }
            let composed = row.actions?.first { $0.id == answer.id }
            guard let call = composed?.call ?? Self.inboxCall(answer.id, matter: matter.id, approval: approval) else { return nil }
            let role: PartFace.Action.Role? = ["archive", "dismiss", "reject"].contains(answer.id) ? .destructive : composed?.role
            return .init(id: answer.id, label: approval && answer.id == "reject" ? "Deny" : answer.label, role: role, doors: composed?.doors,
                         call: call)
        }
        var detail = [row.detail, face.words].compactMap { $0 }.filter { !$0.isEmpty }
        if detail.count == 2, detail[0] == detail[1] { detail.removeLast() }
        let files = face.artifacts.filter { $0.source == Matter.files }.map(\.id)
        if !files.isEmpty { detail.append("Files: " + files.joined(separator: "\n")) }
        return .init(id: matter.id, title: row.title, detail: detail.joined(separator: "\n\n"),
                     value: [reading == .unread ? "Unread" : reading.rawValue.capitalized, row.value].compactMap { $0 }.joined(separator: " · "),
                     at: row.at, symbol: row.symbol, tone: tone ?? row.tone, open: row.open,
                     actions: actions.isEmpty ? nil : actions)
    }

    /// The inbox vocabulary's door verbs: deciding an approval is `inbox.approve` / `inbox.deny`; a request's Open on Mac, Not now and choices
    /// are `inbox.open_on_mac`, `inbox.not_now` and `inbox.act`; read, archive and dismiss put the row away with the words a tap records as
    /// its reason. Nil for an id the vocabulary does not bind.
    private static func inboxCall(_ id: String, matter: String, approval: Bool) -> PartFace.Call? {
        let row: [String: PartFace.Value] = ["id": .string(matter)]
        let putAway: [String: PartFace.Value] = ["id": .string(matter), "reason": .string("put away from its Inbox row")]
        let request = matter.hasPrefix("interaction:")
        switch id {
        case "approve" where approval: return .init("inbox.approve", row)
        case "reject" where approval: return .init("inbox.deny", row)
        case "reject" where request: return .init("inbox.not_now", row)
        case "act" where request: return .init("inbox.open_on_mac", row)
        case "act": return .init("inbox.act", row.merging(["action": .string("act")]) { $1 })
        case "open_approvals": return .init("inbox.open_approvals", row)
        case "read": return .init("inbox.mark_read", putAway)
        case "archive": return .init("inbox.archive", putAway)
        case "dismiss": return .init("inbox.dismiss", putAway)
        case _ where request && id.hasPrefix("interaction_choice_"): return .init("inbox.act", row.merging(["action": .string(id)]) { $1 })
        default: return nil
        }
    }
}
