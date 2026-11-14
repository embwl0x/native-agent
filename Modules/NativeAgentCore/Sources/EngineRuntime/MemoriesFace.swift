import AuthoredCapabilities
import ChatTurnContracts
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MemoriesFace.swift` | Owner-backed memory facts, row calls, review levers, search and refresh |

extension NativeAgentEngine {
    /// What the Memories page is drawn from: the facts `native-memories` reads, the keys its rows may carry, and the person's key levers —
    /// Forget on every memory read here and Keep / Don't keep on every waiting proposal — which no face can omit. Every read that fails is a
    /// named unavailable fact; only cancellation throws, so the levers never depend on the part.
    @concurrent func memoriesPacket(surface: String? = nil) async throws -> PartFaces.Packet {
        let now = Date()
        let epoch = UInt64(now.timeIntervalSince1970 * 1000)
        var facts: [String: JSONValue] = [:]
        var keys: [String: JSONValue] = [:]
        var memoryLevers: [String: PartFace.Row] = [:]
        var memoryOrder: [String] = []
        var proposalLevers: [PartFace.Row] = []
        // Read source state before shaping any row; kept and searched rows share the same trust read below.
        var kept: [MemoryV2.MemoryRecord]?
        do { kept = try await memory.refreshMemories().filter { permitsMemory($0, surface: surface) } }
        catch is CancellationError { throw CancellationError() }
        catch { facts["kept"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)]) }
        await memory.refreshSearch()
        try Task.checkCancellation()
        let search = await MainActor.run {
            (query: memory.searchQuery, results: memory.searchResults, error: memory.searchError,
             loading: memory.searchIsLoading, resultQuery: memory.searchResultQuery)
        }
        let query = search.query
        var found: [MemoryV2.MemoryRecord]?
        var searchFailure: String?
        if let query, query.count >= 3 {
            if let results = search.results {
                do { found = try await memory.activeMemories(ids: results.map(\.id)).filter { permitsMemory($0, surface: surface) } }
                catch is CancellationError { throw CancellationError() }
                catch { searchFailure = error.localizedDescription }
            }
        }
        try Task.checkCancellation()
        let trust = MemoryDataProvenance.reading((kept ?? []).map(\.extras) + (found ?? []).map(\.extras))
        func memories(_ records: [MemoryV2.MemoryRecord]) -> JSONValue {
            .array(records.map { record -> JSONValue in
                let id = PartFace.Value.string(record.id)
                let pin: PageKeyAction = record.pinned == true ? .calls("unpin", "memory.rewrite", ["id": id, "pinned": .bool(false)])
                    : .calls("pin", "memory.pin", ["id": id])
                keys["memory:" + record.id] = .object(["open": .string(MemoriesFaceTarget.memory(record.id).link),
                    "actions": .array([pin.json])])
                if memoryLevers[record.id] == nil {
                    memoryOrder.append(record.id)
                    let excerpt = TodayWords.line(ContextSecretContentPolicy.redactedFragment(record.text), limit: 96)
                    memoryLevers[record.id] = .init(id: "memory:" + record.id, title: excerpt.isEmpty ? "An empty note" : excerpt,
                        actions: [.init(id: "forget", label: "Forget this…", role: .destructive, call: PartFace.Call("memory.forget", ["id": id]))])
                }
                return memoriesFact(record, trust: trust, now: now)
            })
        }
        func unavailable(_ reason: String) -> JSONValue { .object(["state": .string("unavailable"), "reason": .string(reason)]) }

        if let kept { facts["kept"] = .object(["state": .string("available"), "memories": memories(kept)]) }
        do {
            let waiting = try await memory.proposals(status: "pending").filter { permitsProposal($0, surface: surface) }
            facts["waiting"] = .object(["state": .string("available"), "proposals": .array(waiting.map { proposal -> JSONValue in
                let review = { (decision: String) in PartFace.Call("memory.review", ["id": .string(proposal.id), "decision": .string(decision)]) }
                let title = ContextSecretContentPolicy.redactedFragment(proposal.content)
                proposalLevers.append(.init(id: "proposal:" + proposal.id, title: title,
                    at: ContextSecretContentPolicy.redactedFragment(proposal.createdAt), tone: .attention,
                    actions: [.init(id: "accept", label: "Keep", role: .primary, call: review("accept")),
                              .init(id: "reject", label: "Don't keep", role: .destructive, call: review("reject"))]))
                return .object(["id": .string(proposal.id), "content": .string(proposal.content), "createdAt": .string(proposal.createdAt),
                    "kind": faceText(proposal.metadata?.objectValue?["kind"]?.stringValue)])
            })])
        }
        catch is CancellationError { throw CancellationError() }
        catch { facts["waiting"] = unavailable(error.localizedDescription) }
        await memory.refreshRejectedHistory()
        let statusFailures = await memory.refreshStatuses()
        try Task.checkCancellation()

        facts["query"] = faceText(query.flatMap { $0.isEmpty ? nil : $0 })
        keys["search-field"] = .object(["set": .object(PartFace.Call("memories.search").input)])
        if let query, query.count >= 3 {
            var records: JSONValue = .null
            if let found { records = .object(["state": .string("available"), "memories": memories(found)]) }
            if let searchFailure { records = unavailable(searchFailure) }
            facts["search"] = .object(["records": records, "error": faceText(search.error), "loading": .bool(search.loading),
                "resultQuery": faceText(search.resultQuery)])
            keys["search"] = .object(["actions": .array([PageKeyAction.calls("clear", "memories.search", ["value": .string("")]).json])])
        } else { facts["search"] = .null }

        let rejected = await MainActor.run { (memory.rejectedHistoryError, memory.rejectedProposals) }
        if let error = rejected.0 { facts["rejected"] = unavailable(error) }
        else {
            facts["rejected"] = .object(["state": .string("available"), "proposals": .array(rejected.1.filter {
                permitsProposal($0, surface: surface)
            }.map { proposal -> JSONValue in
                keys["rejected:" + proposal.id] = .object(["open": .string(MemoriesFaceTarget.rejected(proposal.id).link)])
                return .object(["id": .string(proposal.id), "content": .string(proposal.content), "createdAt": .string(proposal.createdAt)])
            })])
        }
        // Corrections by lesson, this week against last, from the one owner of the miss ledger; an unreadable ledger is named, never zero.
        let weeks = (this: MemoryRecoveryReadout.isoWeek(), last: MemoryRecoveryReadout.isoWeek(ago: 1))
        do {
            let lessons = try await MemoryRecoveryReadout.misses(dataRoot: dataRoot, weeks: [weeks.this, weeks.last], surface: surface)
            facts["misses"] = .object(["state": .string("available"), "lessons": .array(lessons.map { lesson in
                .object(["lesson": .string(lesson.lesson), "thisWeek": .int(Int64(lesson.count(week: weeks.this))),
                         "lastWeek": .int(Int64(lesson.count(week: weeks.last))),
                         "latest": lesson.misses.first.map { miss in
                             JSONValue.object(["text": .string(miss.text), "at": .string(miss.at)])
                         } ?? JSONValue.null])
            })])
        }
        catch is CancellationError { throw CancellationError() }
        catch { facts["misses"] = unavailable(error.localizedDescription) }
        facts["statusFailures"] = .array(statusFailures.map { failure in
            .object(["endpoint": .string(failure.endpoint), "label": .string(failure.label), "reason": .string(failure.error.localizedDescription)])
        })
        facts["total"] = await memory.totalCount.map { JSONValue.int(Int64($0)) } ?? .null
        facts["momentSource"] = .string(MemoryMoments.sourcePrefix)
        keys["graph"] = .object(["open": .string(MemoriesFaceTarget.graph.link)])
        keys["upkeep"] = .object(["open": .string(MemoriesFaceTarget.upkeep.link)])
        keys["refresh"] = .object(["actions": .array([PageKeyAction.calls("refresh", "memories.refresh").json])])
        facts["keys"] = .object(keys)
        // Redact every published field here, including nested roots and failure reasons, before a part can flatten or clip it.
        // Character clusters come only from these safe words; raw memory text must not survive through that derived field either.
        var texts: [String] = []
        facts = facts.mapValues { value in
            value.mapStrings { text in
                let safe = ContextSecretContentPolicy.redactedFragment(text)
                texts.append(safe)
                return safe
            }
        }
        facts["clusters"] = .array(memoriesClusters(texts).map(JSONValue.string))
        let keyLevers = [PartFace.Section(id: "waiting", title: "Waiting for you", style: .list, rows: proposalLevers),
                         PartFace.Section(id: "kept", title: "What I've kept", style: .list, rows: memoryOrder.compactMap { memoryLevers[$0] })]
        return PartFaces.Packet(facts: .object(facts), epoch: epoch, keyLevers: keyLevers)
    }

    private func permitsMemory(_ record: MemoryV2.MemoryRecord, surface: String?) -> Bool {
        guard let surface else { return true }
        return MemoryRecordDisclosurePolicy.classify(record)?.permits(surface: surface, personaID: nil) == true
    }

    private func permitsProposal(_ proposal: ProposalRecord, surface: String?) -> Bool {
        guard let surface else { return true }
        return MemoryRecordDisclosurePolicy.classify(personaID: proposal.personaId, status: "active", lifecycle: nil,
            tags: nil, metadata: proposal.metadata)?.permits(surface: surface, personaID: nil) == true
    }

    /// One kept memory as measured facts: its words, pin and lifecycle, the time its row shows (and whether that time reads), the time it is
    /// ordered by and the span of the calendar it falls in, the run that wrote it, the provenance its owners derive (a later-wrong sense's warning,
    /// the named untrusted sources) and its roots.
    private func memoriesFact(_ record: MemoryV2.MemoryRecord, trust: PeerDataTaint.TrustRead, now: Date) -> JSONValue {
        let updated = record.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = updated.flatMap { $0.isEmpty ? nil : $0 } ?? record.createdAt
        let ordered = record.updatedAt.flatMap { UserDisplayFormatters.parseISOTimestamp($0) } ?? UserDisplayFormatters.parseISOTimestamp(record.createdAt)
        // Weeks are ISO weeks, as Misses counts them, so "this week" means one span on the page.
        let calendar = Calendar(identifier: .iso8601)
        return .object([
            "id": .string(record.id), "text": .string(record.text), "pinned": .bool(record.pinned == true),
            "lifecycle": .string(MemoryLifecycle.normalized(record.lifecycle)),
            "at": faceText(stamp.isEmpty ? nil : stamp), "atReadable": .bool(UserDisplayFormatters.parseISOTimestamp(stamp) != nil),
            // Seconds since 1970 at full precision, so the face orders exactly as the store's times compare.
            "orderSeconds": ordered.map { JSONValue.double($0.timeIntervalSince1970) } ?? .null,
            // The span the face groups it under, from that same time; it changes only when the day turns. Null when the time can't be read.
            "when": ordered.map { date in
                JSONValue.string(calendar.isDate(date, inSameDayAs: now) ? "today"
                    : calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) ? "week" : "earlier")
            } ?? .null,
            "source": faceText(record.sourceRunId),
            "warning": faceText(MemorySenseProvenance.warning(in: record.extras)),
            "from": .array(MemoryDataProvenance.sources(in: record.extras, trust: trust).map(JSONValue.string)),
            // One line per moment the agent came to know it, in its own words, with whether an untrusted principal steered that moment.
            "roots": MemoryDataProvenance.rootsJSON(record.extras, trust: trust),
        ])
    }


    /// Characters the face must count as one though JavaScript sees several code units (as Today's packet measures them), longest first.
    private func memoriesClusters(_ texts: [String]) -> [String] {
        var found = Set<String>()
        for text in texts {
            for version in [text, TodayWords.plain(text)] {
                for character in version where String(character).utf16.count > 1 { found.insert(String(character)) }
            }
        }
        return found.sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count > $1.utf16.count : $0 < $1 }
    }

    /// The Memories page's search (`memories.search`): three letters or more, or empty to show every memory.
    @MainActor func memoriesSearch(_ input: [String: JSONValue]) async throws -> String {
        guard case .string(let raw)? = input["value"] else {
            throw PartCallError(code: "invalid_value", message: "Search takes value: the words to search for, or empty; nothing was searched.")
        }
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.isEmpty || words.count >= 3 else {
            throw PartCallError(code: "short_query", message: "Search needs at least three letters; nothing was searched.")
        }
        await memory.search(query: words)
        return words.isEmpty ? "Memories shows every memory." : "Memories searched for \u{201C}\(words)\u{201D}."
    }

    /// The kept memories read again (`memories.refresh`); the page then reads its packet from them.
    @MainActor func memoriesRefresh() async throws -> String {
        let kept = try await memory.refreshMemories()
        return "Read \(kept.count) kept \(kept.count == 1 ? "memory" : "memories") again."
    }
}
