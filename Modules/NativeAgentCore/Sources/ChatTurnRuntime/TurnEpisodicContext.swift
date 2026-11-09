import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import Transcripts
import TrustCenter
import TurnTrace
// Blueprint: | `TurnEpisodicContext.swift` | Turn-bound person continuity; recent acts from records and receipts, private choices from scratch |

extension SwiftNativeTurnEngine {
    /// The record supplies outcomes; authored call wording supplies the intention, never evidence of success.
    func episodicContext(sessionID: String?, crossSessionRecall: Bool, now: Date,
                         turn: Turn) async throws -> (life: String, working: String, acts: Set<String>) {
        guard let root = remPinsDataRoot, let sessionID else {
            return ("My recent life has no conversation boundary on this turn; no private choice was read.", "", [])
        }
        guard NativeAgentChatSessionID.isSafePathComponent(sessionID) else { throw CocoaError(.fileReadInvalidFileName) }
        let working: String, heldCharacters: Int?
        do {
            let held = try await ChatSessionScratch.workingMemory(dataRoot: root, sessionID: sessionID)
            heldCharacters = held?.count ?? 0
            working = held.map { "My private working memory for this conversation (not spoken):\n" + $0 } ?? ""
            RepairOwed.settle(root, operation: "context.working_memory:" + sessionID,
                evidence: .init(source: "chat/sessions/\(sessionID)/scratch.json", id: sessionID))
        } catch {
            if error is CancellationError { throw error }
            heldCharacters = nil
            working = Self.lifeUnavailable(error, root: root, owner: "chat/sessions/\(sessionID)/scratch.json",
                operation: "context.working_memory:" + sessionID)
                + " My held choice is unknown; this does not establish that I made no choice."
        }
        do {
            let life = try await recentLifeContext(root: root, sessionID: sessionID,
                crossSessionRecall: crossSessionRecall, now: now, heldCharacters: heldCharacters, turn: turn)
            RepairOwed.settle(root, operation: "context.episodic:" + sessionID,
                evidence: .init(source: "experiences/experiences.sqlite", id: turn.id))
            return (life.text, working, life.acts)
        } catch {
            if error is CancellationError { throw error }
            let life = Self.lifeUnavailable(error, root: root, owner: "experiences/experiences.sqlite",
                operation: "context.episodic:" + sessionID) + " This says nothing about what I did."
            TurnTraceBus.fireFromContext(kind: "context.episodic", sessionId: sessionID,
                payload: .object(["status": .string("unavailable"), "cause": .string(error.localizedDescription)]), turn: turn)
            return (life, working, [])
        }
    }

    private static func lifeUnavailable(_ error: Error, root: URL, owner: String, operation: String) -> String {
        let words = "My reading of \(owner) is unavailable: \(error.localizedDescription). Repair that source before treating it as read."
        RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: operation, owner: owner, words: words)
        return words
    }

    /// Only the person's local arrival, or the agent's unsteered work in the person's local conversation, may carry private life across rooms.
    static func personContinuityAllowed(root: URL, sessionID: String, turn: Turn) throws -> Bool {
        guard !peerContinuityTurn(turn), let envelope = turn.envelope else { return false }
        switch turn.originPrincipal {
        case "person":
            if let origin = turn.origin {
                guard origin.authored != .agent, origin.agent == nil, ["chat", "ios"].contains(origin.surface) else { return false }
            }
            return envelope.agent == nil && ["chat", "ios"].contains(envelope.surface)
        case "self":
            guard let row = try SessionConversation.checkedRow(sessionID, dataRoot: root),
                  SessionConversation(rows: [row]).kind(sessionID)?.isPersonConversation == true,
                  let source = row["source"]?.stringValue else { return false }
            return ["app", "ios"].contains(source)
        default: return false
        }
    }

    /// Peers retain their redacted awareness; a stranger's person-shaped remote arrival grants no person's continuity.
    static func peerContinuityTurn(_ turn: Turn) -> Bool {
        turn.originPrincipal.hasPrefix("agent:")
            || [turn.origin?.agent, turn.envelope?.agent].compactMap({ $0 }).contains(where: { $0 != "self" })
            || turn.origin?.surface.hasSuffix("-bridge") == true || turn.envelope?.surface.hasSuffix("-bridge") == true
            || turn.peerSteering?.checkpointSources.isEmpty == false
            || turn.origin?.peerSources?.isEmpty == false || turn.origin?.elevatedPeerSources?.isEmpty == false
    }

    /// Enough acts to fill four lines after privacy leaves some out, without reading a busy hour's receipts.
    private var lifeCandidates: Int { 24 }

    private func recentLifeContext(root: URL, sessionID: String,
                                   crossSessionRecall: Bool, now: Date, heldCharacters: Int?, turn: Turn) async throws
        -> (text: String, acts: Set<String>) {
        let across = try crossSessionRecall && Self.personContinuityAllowed(root: root, sessionID: sessionID, turn: turn)
        let ownMind = sessionID == Attention.stream && turn.originPrincipal == "self" && !Self.peerContinuityTurn(turn)
        let store = ExperienceStore.at(root)
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsedMs() -> Int64 { Int64((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }
        let since = try await store.lastSpoken(in: sessionID, through: now)
        let sinceMs = elapsedMs()
        let recent = try await store.recentLife(after: since, through: now, limit: 96)
        let recentMs = elapsedMs()
        // A routine pass that changed nothing is not something she did: background abilities fill the bounded read with them.
        let acted = recent.filter { experience in
            guard let outcome = experience.outcome else { return false }
            return !(outcome.status == "ok" && outcome.effects == .some(.none))
        }
        // Dispatch rows carry whole results, and this runs ahead of every first word: read only the turns that did what may be shown.
        let subjects = Array(Set(acted.prefix(lifeCandidates).flatMap(\.cause)))
        let trace = subjects.isEmpty ? nil : try await TurnTracePersistLane(dataRootOverride: root).events(
            .init(subjects: subjects, kinds: ["tool.dispatch"], from: since, through: now, limit: 192, newestFirst: true))
        var receipts: [String: TurnTraceEvent] = [:]
        for event in trace?.events ?? [] {
            guard case .object(let payload) = event.payload, payload["phase"] == .string("end"),
                  case .object(let receipt)? = payload["receipt"], let id = receipt["id"]?.stringValue else { continue }
            receipts[id] = event
        }
        var lines: [String] = [], ids: [String] = [], gaps: [String] = []
        for experience in acted.prefix(lifeCandidates) {
            try Task.checkCancellation()
            guard let outcome = experience.outcome else { continue }
            let event = receipts[experience.id]
            do {
                guard try await Self.lifeBelongs(experience, event: event, sessionID: sessionID,
                    includePersonActs: across, includeMindActs: ownMind, store: store) else { continue }
                let reading = Self.lifeWords(experience, event: event)
                gaps += reading.gaps.map { experience.id + ": " + $0 }
                guard let words = reading.words else { continue }
                let effects = outcome.effects.map { "; effects \($0.rawValue)" } ?? "; effects unrecorded"
                let stamp = experience.updatedAt ?? experience.at
                lines.append("- \(stamp): \(words) — recorded \(outcome.status)\(effects).")
                ids.append(experience.id)
                if lines.count == 4 { break }
            } catch {
                if error is CancellationError { throw error }
                gaps.append(experience.id + ": " + error.localizedDescription)
            }
        }
        let heading = since.map { "Since my last reply (\(NativeTimestampFormat.fractionalZulu($0))), newest first:" }
            ?? "My newest recorded acts (no earlier delivered reply is established here):"
        var parts = lines.isEmpty ? [] : [heading] + lines
        if recent.count == 96 {
            parts.append("This is the newest bounded slice of the record; earlier acts may remain outside it.")
        }
        if let unreadable = trace?.unreadable, unreadable > 0 { gaps.append("\(unreadable) receipt details could not be read") }
        if !gaps.isEmpty { parts.append("Some life evidence is unavailable: " + gaps.prefix(2).joined(separator: "; ")) }
        TurnTraceBus.fireFromContext(kind: "context.episodic", sessionId: sessionID, payload: .object([
            "since": since.map { .string(NativeTimestampFormat.fractionalZulu($0)) } ?? .null,
            "experience_ids": .array(ids.map(JSONValue.string)), "cross_conversation": .bool(across),
            "unavailable_count": .int(Int64(gaps.count)), "working_memory_characters": heldCharacters.map { .int(Int64($0)) } ?? .null,
            "since_ms": .int(sinceMs), "recent_ms": .int(recentMs), "total_ms": .int(elapsedMs())
        ]), turn: turn)
        return (parts.joined(separator: "\n"), Set(ids))
    }

    /// A closing receipt attests the act's conversation, including native work with no heard record. Other causal reads retain their privacy boundary.
    private static func lifeBelongs(_ experience: Experience, event: TurnTraceEvent?, sessionID: String,
                                    includePersonActs: Bool, includeMindActs: Bool, store: ExperienceStore) async throws -> Bool {
        var conversations: Set<String> = []
        if let source = event?.sessionId {
            if includePersonActs || includeMindActs && source == sessionID { return true }
            guard source == sessionID else { return false }
            conversations.insert(source)
        }
        var forPerson = false
        enum Step { case enter(Experience), leave(String) }
        var pending: [Step] = [.enter(experience)], visiting: Set<String> = [], read: Set<String> = []
        while let step = pending.popLast() {
            try Task.checkCancellation()
            switch step {
            case .leave(let id):
                visiting.remove(id)
                read.insert(id)
            case .enter(let current):
                guard !visiting.contains(current.id) else {
                    throw ToolFailureError("A circular cause prevents reading experience \(experience.id).", effects: .none)
                }
                guard !read.contains(current.id) else { continue }
                visiting.insert(current.id)
                pending.append(.leave(current.id))
                forPerson = forPerson || current.addressedTo.contains(ForPerson.person)
                for destination in current.addressedTo where destination.hasPrefix("conversation:") {
                    conversations.insert(String(destination.dropFirst("conversation:".count)))
                }
                for ref in current.evidence {
                    if ref.source.hasPrefix("chat/messages/") {
                        let name = String(ref.source.dropFirst("chat/messages/".count))
                        conversations.insert(name.hasSuffix(".jsonl") ? String(name.dropLast(".jsonl".count)) : name)
                    } else if ref.source == "conversation" { conversations.insert(ref.id) }
                }
                guard includePersonActs || conversations.allSatisfy({ $0 == sessionID }) else { return false }
                for cause in current.cause {
                    guard let parent = try await store.experience(cause) else {
                        throw ToolFailureError("The life record has not recorded cause \(cause).", effects: .none)
                    }
                    pending.append(.enter(parent))
                }
            }
        }
        return conversations.contains(sessionID) || includePersonActs && (forPerson || !conversations.isEmpty)
    }

    private static func lifeWords(_ experience: Experience, event: TurnTraceEvent?) -> (words: String?, gaps: [String]) {
        guard let outcome = experience.outcome else { return (nil, []) }
        guard outcome.domain != "chat.working_memory" else { return (nil, []) }
        let payload = event?.payload.objectValue
        let receipt = payload?["receipt"]?.objectValue
        if experience.kind == .act {
            if payload?["parentId"] != nil || receipt?["preview"] == .bool(true)
                || receipt?["resultClass"] == .string("preview") { return (nil, []) }
            let result = receipt?["resultReceipt"]?.objectValue
            let readOnly = AppActionBinding.declaredBinding(outcome.domain)?.read == true || result?["read_only"] == .bool(true)
            if readOnly, receipt?["resultClass"] == .string("succeeded") { return (nil, []) }
        }
        var words = "My " + lifeLine(outcome.domain) + " record"
        var gaps: [String] = []
        if let authored = experience.face?.words, !authored.isEmpty { words += ": " + lifeLine(authored) }
        if experience.kind == .act {
            if payload == nil || receipt == nil { gaps.append("closing dispatch evidence is unavailable in this read; inspect its recorded receipt") }
            if let raw = payload?["args"]?.stringValue {
                do {
                    let value = try JSONValue.parse(Data(raw.utf8))
                    guard let input = value.objectValue else { throw CocoaError(.fileReadCorruptFile) }
                    let args = input["args"]?.objectValue ?? input
                    if let purpose = ["reason", "summary", "title", "note"].compactMap({ args[$0]?.stringValue }).first,
                       !purpose.isEmpty { words += "; my intention was “" + lifeLine(purpose) + "”" }
                } catch { gaps.append("invocation wording is unreadable or shortened: " + lifeLine(error.localizedDescription)) }
            }
            if let raw = payload?["result"]?.stringValue {
                do {
                    let recorded = try JSONValue.parse(Data(raw.utf8))
                    if recorded.objectValue?["provider_projection"] == .string("bounded_tool_result") {
                        gaps.append("the dispatch retains a bounded result reference, not the outcome wording; inspect the original receipt")
                    } else {
                        words += "; my receipt recorded " + (try lifeFacts(recorded))
                    }
                } catch { gaps.append("receipt wording is unreadable: " + lifeLine(error.localizedDescription)) }
            } else { gaps.append("dispatch result wording is unavailable; inspect the original receipt") }
        } else if experience.face?.words.isEmpty != false {
            gaps.append("authored experience wording is unavailable; inspect its evidence")
        }
        if !gaps.isEmpty { words += "; evidence incomplete: " + gaps.joined(separator: "; ") }
        return (words, gaps)
    }

    /// Receipt fields belong to their action; a fixed vocabulary cannot stand in for what it actually recorded.
    private static func lifeFacts(_ receipt: JSONValue) throws -> String {
        var pending: [(path: String, value: JSONValue)] = [("", receipt)]
        var facts: [String] = [], omitted = 0
        // Eight short facts per act keep the four-line packet compact; omitted facts remain explicitly counted.
        while let field = pending.popLast() {
            switch field.value {
            case .object(let object) where !object.isEmpty:
                let fields = object.sorted { lhs, rhs in
                    let leftNested = lifeNested(lhs.value), rightNested = lifeNested(rhs.value)
                    return leftNested == rightNested ? lhs.key < rhs.key : !leftNested
                }
                for (key, value) in fields.reversed() {
                    pending.append((field.path.isEmpty ? key : field.path + "." + key, value))
                }
            case .array(let array) where !array.isEmpty:
                for (index, value) in array.enumerated().reversed() { pending.append((field.path + "[\(index)]", value)) }
            default:
                if facts.count < 8 {
                    let name = field.path.isEmpty ? "result" : lifeExcerpt(field.path, limit: 80)
                    facts.append(name + "=" + lifeExcerpt(try field.value.serialize(pretty: false), limit: 80))
                } else { omitted += 1 }
            }
        }
        if omitted > 0 { facts.append("\(omitted) more receipt facts omitted") }
        return facts.joined(separator: "; ")
    }

    private static func lifeNested(_ value: JSONValue) -> Bool {
        switch value {
        case .object, .array: true
        default: false
        }
    }

    private static func lifeLine(_ text: String) -> String {
        lifeExcerpt(text, limit: 220)
    }

    private static func lifeExcerpt(_ text: String, limit: Int) -> String {
        let line = TurnTraceRedactor.redactText(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(line.prefix(limit)) + (line.count > limit ? "…[shortened]" : "")
    }
}
