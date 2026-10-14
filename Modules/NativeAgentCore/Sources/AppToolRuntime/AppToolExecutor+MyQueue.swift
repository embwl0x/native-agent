import ApprovalInbox
import ChatOrchestration
import Desk
import Foundation
import NativeAgentCore
import PersistenceCore
import Skills
import TrustCenter

extension AppToolExecutor {
    @MainActor
    func runHouseFile(input: [String: JSONValue], surface: String) async -> JSONValue {
        guard let title = Self.inputString(input["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let summary = Self.inputString(input["summary"])?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
              let owner = ["me": HarnessFinding.Owner.agent, "builder": .builder, "user": .owner][Self.inputString(input["owner"]) ?? ""] else {
            return Self.doorRefusal("invalid_input", "Nothing was filed.", remedy: "fix_args",
                                    "Pass title, summary and owner: me, builder or user.")
        }
        let refs: [DeskRef]
        if let value = input["refs"] {
            guard case .array(let values) = value else {
                return Self.doorRefusal("invalid_input", "Nothing was filed.", remedy: "fix_args", "refs takes an array of Desk refs.")
            }
            // A plain string is a note; an object names its kind.
            refs = values.compactMap { value -> DeskRef? in
                if case .string(let text) = value { return DeskRef(kind: .note(text: text)) }
                return DeskRef.fromJSON(value)
            }
            guard refs.count == values.count else {
                return Self.doorRefusal("invalid_input", "Nothing was filed.", remedy: "fix_args",
                    "Each ref is a string (a note) or {kind: file|url|note|commit|gh_issue|gh_pr|agent|approval|trace, …}.")
            }
        } else { refs = [] }
        do {
            let key = "agent:" + title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                              peerID: ChatToolSessionContext.envelope?.verifiedUserId)
            let carried = DeskRef(kind: .step(DeskStep(words: summary, when: "own_turn",
                peers: steer.sources, elevated: steer.elevated, session: ChatToolSessionContext.verifiedSessionId,
                origin: ChatPersistenceContext.originPrincipal, replyRoute: TurnEnvelope.current(surface: surface).persistedMetadata())))
            let item = try await HarnessQueue.file(HarnessFinding(key: key, title: title,
                summary: summary, owner: owner,
                // Only what she owns is carried; builder and User items wait on them.
                refs: refs.filter { $0.kind.token != "step" } + (owner == .agent ? [carried] : []), source: .agent),
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            let filedOwner = ["agent": "me", "builder": "builder", "owner": "user"][item.assignee ?? ""] ?? item.assignee
            let ownership = item.assignee == owner.rawValue ? "" : " Owner unchanged: \(filedOwner ?? "unassigned")."
            return .object(["status": .string("ok"), "id": .string("desk." + item.alias),
                            "owner": filedOwner.map(JSONValue.string) ?? .null,
                            "confirmation": .string("Filed: " + item.title + ownership)])
        } catch { return Self.failure("house_file_failed", error.localizedDescription) }
    }

    /// MY QUEUE's actions (Wave 2 #7): queue a step, or mark one done or
    /// dropped. Each answers with a receipt naming the item. A step queued on
    /// a peer-steered turn keeps that steer (`PeerDataTaint.carried`).
    @MainActor
    func runMyQueue(verb: String, input: [String: JSONValue], surface: String) async -> JSONValue {
        let store = SwiftNativeDeskStore(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        func text(_ key: String) -> String? {
            Self.inputString(input[key]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func receipt(_ entry: MyQueue.Entry, _ change: String) -> JSONValue {
            .object(["status": .string("ok"), "id": .string(entry.name), "queue": .string(change), "owner": .string("hers"),
                     "when": .string(entry.step.when + (entry.step.card.map { " " + $0 } ?? "")),
                     "confirmation": .string("\(entry.name) \(change): \"\(entry.step.words)\"")])
        }
        do {
            if verb == "add" {
                guard let words = text("text") else {
                    return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args", "Pass text: the step in your own words.")
                }
                guard let when = MyQueue.When(text("when")) else {
                    return Self.doorRefusal("invalid_input", "Nothing was queued.", remedy: "fix_args",
                        "when is next_turn, own_turn, when_user_messages with an optional door, after_card <approval id>, or at <ISO time>.")
                }
                if let card = when.card {
                    do { _ = try await SwiftNativeApprovalInbox(root: store.dataRoot).get(card) } catch {
                        return Self.doorRefusal("not_found", "No card \(card); nothing was queued.", remedy: "fix_args",
                            "after_card takes the approvalId a carded call returned.")
                    }
                }
                let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                  peerID: ChatToolSessionContext.envelope?.verifiedUserId)
                let queued = try await MyQueue.add(DeskStep(words: words, when: when.stored, card: when.card, action: text("action"),
                                                            peers: steer.sources, elevated: steer.elevated,
                                                            session: ChatToolSessionContext.verifiedSessionId,
                                                            origin: ChatPersistenceContext.originPrincipal,
                                                            replyRoute: TurnEnvelope.current(surface: surface).persistedMetadata()), store: store)
                return receipt(queued.entry, queued.change.rawValue)
            }
            guard let id = text("id") else {
                return Self.doorRefusal("invalid_input", "Nothing changed.", remedy: "fix_args", "Pass id: the step's desk.N from home.")
            }
            let alias = id.lowercased().hasPrefix("desk.") ? String(id.dropFirst(5)) : id
            guard let entry = MyQueue.entries(try await store.liveState())
                .first(where: { $0.item.alias == alias || $0.item.handle == id }) else {
                return Self.doorRefusal("not_found", "\(id) is not an open MY QUEUE step; nothing changed.", remedy: "fix_args",
                                        "Home's MY QUEUE lists the open steps by desk.N.")
            }
            if let session = ChatToolSessionContext.verifiedSessionId,
               let by = (try? await store.hold(entry.item.handle, session: session)) ?? nil {
                return Self.doorRefusal("held_by", "\(entry.name) is held by \(by), which is working it; nothing changed.",
                                        remedy: "none", "Leave it to that one, or pick it up there.", extra: ["held_by": .string(by)])
            }
            let dropped = verb == "drop"
            try await MyQueue.finish(entry, dropped: dropped, why: text("reason") ?? (dropped ? "dropped" : "done"), store: store)
            // A repeated-work line: dropped stays quiet until 3 more turns; done is covered.
            SkillPatterns.closed(item: entry.item.handle, dropped: dropped, root: store.dataRoot)
            // A stopped skill run's step, closed: the run is closed too, and lets go of what it held.
            if let run = MyQueue.skillRun(in: entry.step.words) {
                try? FileManager.default.removeItem(at: SkillRunStore.file(run, root: store.dataRoot))
            }
            return receipt(entry, dropped ? "dropped" : "done")
        } catch {
            return Self.failure("queue_failed", error.localizedDescription + " Home's MY QUEUE shows what is there now.")
        }
    }
}
