import AuthoredCapabilities
import CryptoKit
import DreamREMCycle
import Foundation
import MemoryV2
import NativeAgentShared
import PersistenceCore
import Privacy
// Blueprint: | `NativeCollectionPackets.swift` | Dream and graph packets, revision-bound collection demands and canonical selected items |

extension NativeAgentEngine {
    @concurrent func dreamsPacket() async throws -> PartFaces.Packet {
        let face = try await dreamsPresentation("entries", request: .init(id: UUID(), key: "entries", expectedCall: nil))
        let gate = try await cognitionView.dreamGateChecked()
        let controls = PartFace.Section(id: "commands", style: .list, rows: [
            .init(id: "dream", title: "Dream pass", actions: [
                .init(id: "run", label: "Run dream pass", call: .init("mind.dream"),
                      unavailable: gate.dreamEnabled ? nil : DreamREMGatePolicy.dreamDisabledDetail)
            ]),
            .init(id: "rem", title: "REM pass", actions: [
                .init(id: "run", label: "Run REM", call: .init("mind.rem"),
                      unavailable: gate.remEnabled ? nil : DreamREMGatePolicy.remDisabledDetail)
            ])
        ])
        return try collectionPacket(face, levers: [controls])
    }

    @concurrent func graphPacket() async throws -> PartFaces.Packet {
        let face = try await graphPresentation("entities", request: .init(id: UUID(), key: "entities", expectedCall: nil))
        var rows: [PartFace.Row] = []
        do {
            let policy = try await trust.load()
            guard let enabled = policy.memoryPolicy?.knowledge_graph_enabled else {
                throw PartCallError(code: "graph_policy_unavailable", message: "The checked Memory Policy supplied no Knowledge Graph setting.")
            }
            rows.append(.init(id: "knowledge-graph-enabled", title: "Knowledge Graph", control: .toggle(enabled,
                call: .init("setting.set", ["setting": .string("memories.knowledge_graph")]))))
        } catch is CancellationError { throw CancellationError() }
        catch {
            rows.append(.init(id: "graph-policy-unavailable", title: "Knowledge Graph setting unavailable",
                detail: NativeAppSecretRedactor.redactText(error.localizedDescription), tone: .failed))
        }
        rows += [
            .init(id: "upkeep", title: "Graph upkeep", actions: [.init(id: "review", label: "Review orphaned entities",
                open: "page:knowledge/upkeep")]),
            .init(id: "refresh", title: "Knowledge Graph", actions: [.init(id: "refresh", label: "Refresh", call: .init("graph.refresh"))])
        ]
        let levers = PartFace.Section(id: "commands", style: .list, rows: rows)
        return try collectionPacket(face, levers: [levers])
    }

    nonisolated private func collectionPacket(_ face: PartFace, levers: [PartFace.Section]) throws -> PartFaces.Packet {
        var keys: [String: JSONValue] = [:]
        func object<Value: Encodable>(_ value: Value) throws -> [String: JSONValue] {
            guard case .object(let fields) = try JSONValue.fromEncodable(value) else {
                throw PartCallError(code: "collection_packet_invalid", message: "The collection's page could not be encoded.")
            }
            return fields
        }
        func drawingRow(_ row: PartFace.Row) throws -> JSONValue {
            var fields = try object(row), key: [String: JSONValue] = [:]
            if let open = row.open { key["open"] = .string(open) }
            if let read = row.read { key["read"] = .object(read.input) }
            fields.removeValue(forKey: "read")
            if let control = row.control {
                if let call = control.call { key["set"] = .object(call.input) }
                var drawing = try object(control)
                drawing.removeValue(forKey: "call")
                fields["control"] = .object(drawing)
            }
            if let actions = row.actions {
                key["actions"] = .array(actions.map { action in
                    var declared: [String: JSONValue] = ["id": .string(action.id)]
                    if let role = action.role { declared["role"] = .string(role.rawValue) }
                    if let doors = action.doors { declared["doors"] = .array(doors.map(JSONValue.string)) }
                    if let call = action.call { declared["call"] = .object(call.input) }
                    if let open = action.open { declared["open"] = .string(open) }
                    if let unavailable = action.unavailable { declared["unavailable"] = .string(unavailable) }
                    return .object(declared)
                })
                fields["actions"] = .array(try actions.map { action in
                    var drawing = try object(action)
                    for field in ["call", "open", "doors"] { drawing.removeValue(forKey: field) }
                    return .object(drawing)
                })
            }
            if !key.isEmpty { keys[row.id] = .object(key) }
            if let children = row.rows { fields["rows"] = .array(try children.map { try drawingRow($0) }) }
            return .object(fields)
        }
        var fields = try object(face)
        fields["sections"] = .array(try face.sections.map { section in
            var fields = try object(section)
            if let block = section.block {
                var drawing = try object(block)
                drawing.removeValue(forKey: "read")
                drawing.removeValue(forKey: "revision")
                fields["block"] = .object(drawing)
                fields.removeValue(forKey: "rows")
                if let read = block.read { keys[block.key] = .object(["read": .object(read.input)]) }
            } else { fields["rows"] = .array(try section.rows.map { try drawingRow($0) }) }
            if let more = section.more {
                var drawing = try object(more)
                drawing.removeValue(forKey: "read")
                fields["more"] = .object(drawing)
                if let read = more.read { keys[section.id] = .object(["read": .object(read.input)]) }
            }
            return .object(fields)
        })
        fields["keys"] = .object(keys)
        guard let epoch = UInt64(exactly: (Date().timeIntervalSince1970 * 1_000).rounded(.down)) else {
            throw PartCallError(code: "collection_epoch_unavailable", message: "The collection's publication time is outside its numeric range.")
        }
        return PartFaces.Packet(facts: .object(fields), epoch: epoch, levers: levers)
    }

    @concurrent func collectionItemFace(_ face: PartFace, part: String) async throws -> PartFace {
        let packet = try collectionPacket(face, levers: [])
        guard let file = try AbilityStore(dataRoot: dataRoot).read(id: part), file.record["status"] == .string("active"),
              let version = file.record["codeFingerprint"]?.stringValue else {
            throw PartCallError(code: "collection_part_unavailable", message: "The collection's part has no active selected projection.")
        }
        switch await tools.face(id: part, input: packet.facts, version: version) {
        case .failure(let error): throw error
        case .success(let projected):
            var bound = try projected.bound(to: PartFace.Keys(packet: packet.facts), levers: [])
            let blocks = face.sections.compactMap(\.block)
            bound.sections = bound.sections.map { section in
                guard var block = section.block, let owner = blocks.first(where: { $0.key == block.key }) else { return section }
                block.revision = owner.revision
                var section = section
                section.block = block
                return section
            }
            return bound
        }
    }

    @concurrent func dreamsPresentation(_ item: String, request: FaceReadRequest) async throws -> PartFace {
        if item != "entries" {
            let entry = try await cognitionView.dreamEntry(date: item)
            guard let content = entry.content else {
                throw PartCallError(code: "dream_entry_unavailable", message: "The diary owner supplied no text for this entry.")
            }
            let text = NativeAppSecretRedactor.redactText(content)
            return PartFace(title: item, sections: [.init(id: "entry", rows: [], block: .init(key: "entry:" + item,
                text: text.utf8.count <= PartFace.Block.inlineByteLimit ? text : nil, copy: true,
                read: .init("dream.entry", ["date": .string(item)]), revision: try collectionRevision(text)))])
        }
        let diary = try await cognitionView.dreamDiary(limit: Int.max)
        let revision = try collectionRevision(diary.entries.map { [$0.date, $0.modifiedAt] })
        let cursor = try collectionCursor(request, revision: revision, ids: diary.entries.map(\.date))
        let entries = Array(diary.entries.dropFirst(cursor).prefix(256))
        let next = cursor + entries.count
        let rows = entries.map { entry in
            PartFace.Row(id: entry.date, title: entry.date, at: entry.modifiedAt,
                         open: "page:dreams/" + entry.date)
        }
        var sections = [PartFace.Section(id: "entries", title: "Dream diary", style: .list,
            footer: diary.totalEntries.map { "Showing \(next) of \($0) entries" }, rows: rows,
            more: next < diary.entries.count ? .init(next: String(next), total: diary.totalEntries, revision: revision,
                read: .init("dream.diary")) : nil, filter: "Filter dreams…", revision: revision)]
        if let unreadable = diary.unreadableEntries, unreadable > 0 {
            sections.insert(.init(id: "gaps", style: .note, rows: [.init(id: "unreadable", title: "\(unreadable) diary entries could not be read.",
                tone: .attention)]), at: 0)
        }
        if diary.entries.isEmpty {
            sections = sections.map { section in
                guard section.id == "entries" else { return section }
                var section = section
                section.rows = [.init(id: "empty", title: diary.totalEntries == 0 && diary.unreadableEntries == 0
                    ? "No diary entries recorded." : "No readable entries supplied.", tone: .quiet)]
                return section
            }
        }
        return PartFace(title: "Dreams", sections: sections, detail: .init(of: "entries"))
    }

    @concurrent func collectionDocument(page: String, item: String) async throws -> String {
        if page == "dreams", item.hasPrefix("entry:") {
            let entry = try await cognitionView.dreamEntry(date: String(item.dropFirst("entry:".count)))
            guard let text = entry.content else {
                throw PartCallError(code: "dream_entry_unavailable", message: "The diary owner supplied no text for this entry.")
            }
            return text
        }
        if page == "knowledge", item.hasPrefix("summary:") {
            let id = String(item.dropFirst("summary:".count))
            await memory.loadGraph()
            let reading = await (memory.graphSnapshot, memory.graphLoadError, memory.graphObservationError)
            if let error = reading.1 ?? reading.2 { throw PartCallError(code: "graph_unavailable", message: error) }
            guard let entity = reading.0?.canvasEntities.first(where: { $0.id == id }), let summary = entity.summary else {
                throw PartCallError(code: "graph_summary_unavailable", message: "The checked graph supplied no summary for this entity.")
            }
            return summary
        }
        throw PartCallError(code: "collection_document_invalid", message: "Choose a diary entry or an entity summary first.")
    }

    @concurrent func graphPresentation(_ item: String, request: FaceReadRequest) async throws -> PartFace {
        if item == "upkeep" || item == "upkeep-candidates" { return try await graphUpkeep.review(request: request) }
        await memory.loadGraph()
        let reading = await (memory.graphSnapshot, memory.graphLoadError, memory.graphObservationError)
        if let issue = reading.1 ?? reading.2 { throw PartCallError(code: "graph_unavailable", message: issue) }
        guard let snapshot = reading.0 else {
            throw PartCallError(code: "graph_unavailable", message: "The graph owner supplied no checked reading.")
        }
        let entities = snapshot.canvasEntities.map { entity in
            FaceGraphEntity(id: entity.id, name: NativeAppSecretRedactor.redactText(entity.name), kind: entity.type,
                detail: entity.summary.map(NativeAppSecretRedactor.redactText), weight: nil, lastSeen: entity.lastSeenDate)
        }
        let allEdges = snapshot.canvasEdges.map {
            FaceGraphEdge(from: $0.from, to: $0.to, kind: NativeAppSecretRedactor.redactText($0.kind), weight: $0.weight)
        }
        await face.post(KnowledgeGraphFace(entities: entities, edges: allEdges, totalEntities: entities.count,
            totalEdges: allEdges.count, state: .ready), at: .knowledgeGraph)
        if item == "entities" {
            let revision = try collectionRevision([JSONValue.fromEncodable(entities), JSONValue.fromEncodable(allEdges)])
            let cursor = try collectionCursor(request, revision: revision, ids: entities.map(\.id))
            var face = try GraphCollectionFace.list(entities: entities, total: entities.count, cursor: cursor, revision: revision,
                itemPrefix: "entity:")
            face.sections = face.sections.map { section in
                var section = section
                section.more?.read = .init("graph.list")
                return section
            }
            return face
        }
        let entityID: String
        if item.hasPrefix("relationships:") { entityID = String(item.dropFirst("relationships:".count)) }
        else if item.hasPrefix("entity:") { entityID = String(item.dropFirst("entity:".count)) }
        else { throw PartCallError(code: "graph_item_invalid", message: "Choose an entity or an upkeep review from the graph page.") }
        guard let entity = entities.first(where: { $0.id == entityID }) else {
            throw PartCallError(code: "graph_entity_missing", message: "That entity is absent from the checked graph.")
        }
        let edges = snapshot.canvasEdges.filter { $0.from == entityID || $0.to == entityID }.map {
            FaceGraphEdge(from: $0.from, to: $0.to, kind: NativeAppSecretRedactor.redactText($0.kind), weight: $0.weight)
        }
        let revision = try collectionRevision(edges)
        let cursor = try collectionCursor(request, revision: revision, ids: edges.indices.map { "edge:\($0)" })
        var face = try GraphCollectionFace.detail(entity: entity, entities: entities, edges: edges, state: .ready,
            relationshipCursor: cursor, revision: revision, itemPrefix: "entity:")
        face.sections = try face.sections.map { section in
            var section = section
            if section.id == "summary" {
                section.block?.read = .init("graph.summary", ["entity": .string(entityID)])
                if let summary = entity.detail { section.block?.revision = try collectionRevision(summary) }
            }
            section.more?.read = .init("graph.relationships", ["entity": .string(entityID)])
            return section
        }
        if let source = snapshot.canvasEntities.first(where: { $0.id == entityID }) {
            var rows: [PartFace.Row] = []
            if let count = source.mentionCount { rows.append(.init(id: "mentions", title: "Mentions", value: String(count))) }
            if let first = source.firstSeen { rows.append(.init(id: "first-seen", title: "First seen", value: first)) }
            if let aliases = source.aliases, !aliases.isEmpty {
                rows.append(.init(id: "aliases", title: "Aliases", value: NativeAppSecretRedactor.redactText(aliases.joined(separator: ", "))))
            }
            face.sections = face.sections.map { section in
                guard section.id == "entity" else { return section }
                var section = section
                section.rows += rows
                return section
            }
        }
        return face
    }

    nonisolated private func collectionRevision<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func collectionCursor(_ request: FaceReadRequest, revision: String, ids: [String]) throws -> Int {
        guard let raw = request.cursor else {
            if let anchor = request.anchor, let index = ids.firstIndex(of: anchor) { return index }
            return 0
        }
        if let read = request.revision, read != revision {
            throw PartCallError(code: "collection_changed", message: "The collection changed; read it again from the selected row.")
        }
        guard let cursor = Int(raw), cursor >= 0, cursor <= ids.count else {
            throw PartCallError(code: "invalid_cursor", message: "The collection cursor is outside this reading.")
        }
        return cursor
    }
}
