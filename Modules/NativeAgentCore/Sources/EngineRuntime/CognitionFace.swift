import AuthoredCapabilities
import Cognition
import CryptoKit
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `CognitionFace.swift` | Cognition and memory upkeep packets, held collection reads and canonical person commands |

extension NativeAgentEngine {
    @MainActor func registerCognitionPages() async {
        await pages.register(page: "cognition", part: "native-cognition", read: { try await self.cognitionPacket() })
        await pages.register(page: "memory-upkeep", part: "native-memory-upkeep", read: { try await self.memoryUpkeepPacket() })
        await pages.register(page: "cognition", item: { key, request in
            try await self.cognitionCollection(key, request: request)
        })
        await pages.register(page: "memory-upkeep", item: { key, request in
            let face = try await self.memoryUpkeepPage(refreshing: false)
            return try Self.reading(face, key: key, request: request, readAction: "native.memory-upkeep.read")
        })
        await pages.register(page: "cognition", contains: { Self.evidenceIdentity($0) != nil }, body: { key in
            try await self.evidenceBody(page: "cognition", key: key)
        })
        await pages.register(page: "memory-upkeep", contains: { Self.evidenceIdentity($0) != nil }, body: { key in
            try await self.evidenceBody(page: "memory-upkeep", key: key)
        })
        Task { [weak self] in
            guard let self else { return }
            let changes = await cognitionView.changes()
            await pages.refresh(page: "cognition")
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await pages.refresh(page: "cognition")
            }
        }
        let database = dataRoot.appendingPathComponent("memory/memory.sqlite")
        Task { [weak self] in
            guard let self else { return }
            await EventDeadlinePhysiology.refreshOnChanges(paths: [database, URL(fileURLWithPath: database.path + "-wal")]) {
                await self.pages.refresh(page: "memory-upkeep")
            }
        }
    }

    @concurrent func cognitionPacket() async throws -> PartFaces.Packet {
        await cognitionView.refreshDetail()
        return try await Self.pagePacket(cognitionPage(), readAction: "native.cognition.read")
    }

    @concurrent private func cognitionPage() async throws -> PartFace {
        if await cognition == nil {
            throw PartCallError(code: "cognition_unavailable", message: "This root has no resident mind.")
        }
        guard let detail = await cognitionView.detail else {
            return PartFace(title: "Cognition", sections: [.init(id: "waiting", style: .waiting,
                rows: [.init(id: "waiting", title: "Waiting on the resident mind's Observatory reading.")])])
        }
        let face = EngineFaceCognitionProjection.face(detail)
        if case .unavailable(let failure) = face.state { throw failure }
        let configuration = detail.configuration
        let enabled = configuration.enabled
        let blocked = enabled ? nil : "An inner life is off in Settings."
        func command(_ id: String, _ label: String, _ action: String, unavailable: String? = nil,
                     role: PartFace.Action.Role? = nil) -> PartFace.Row {
            .init(id: id, title: label, actions: [.init(id: "run", label: label, role: role,
                call: .init(action), unavailable: unavailable)])
        }
        func setting(_ id: String, _ label: String, _ value: Bool, _ setting: String) -> PartFace.Row {
            .init(id: id, title: label, detail: blocked,
                control: .toggle(value, call: .init("setting.set", ["setting": .string(setting)])))
        }
        var controls = [command("think", "Think now", "mind.think_now", unavailable: blocked),
            command("reflect", "Reflect", "mind.reflect", unavailable: blocked
                ?? (!configuration.reflectiveCallsEnabled ? "Reflection is off in Settings." : nil)
                ?? (configuration.dailyReflectionCallBudget == 0 ? "The reflection budget is zero." : nil)),
            command("clear", "Clear thinking", "mind.clear", unavailable: blocked, role: .destructive),
            command("settle", "Settle body", "mind.settle_body", unavailable: blocked
                ?? (!detail.organism.enabled ? "Body signals are off in Settings." : nil)),
            command("reset", "Reset body", "mind.reset_body", unavailable: blocked
                ?? (!detail.organism.enabled ? "Body signals are off in Settings." : nil), role: .destructive),
            setting("capsule", "Give me a thought summary", configuration.capsuleInjectionEnabled, "settings.inner_life_capsule"),
            setting("background", "Keep thinking in the background", configuration.backgroundMicrocyclesEnabled, "settings.inner_life_background")]
        controls.append(.init(id: "budget", title: "Reflections in 24 hours", detail: blocked,
            control: .init(call: .init("setting.set", ["setting": .string("settings.daily_reflection_budget")]),
                number: .init(value: Double(configuration.dailyReflectionCallBudget), min: 0, max: 8, step: 1))))
        controls.append(.init(id: "include-workspace", title: "Include workspace", detail: blocked,
            control: .toggle(detail.summary.ablations["workspace"] != false, call: .init("mind.workspace"))))
        var sections = [PartFace.Section(id: "controls", title: "Controls", rows: controls)]
        sections += face.sections.enumerated().flatMap { index, face in
            face.sections.map { section in
                var section = section
                section.id = "reading:\(index):" + section.id
                return section
            }
        }
        sections += [.init(id: "organism", title: "Body signals", rows: face.organism, folded: true),
            .init(id: "receipts", title: "Loop activity", rows: face.receipts, folded: true),
            .init(id: "capsule", title: "Thought summary", rows: face.capsule, folded: true),
            .init(id: "proposals", title: "How I have grown", rows: face.proposals, folded: true)]
        sections = try sections.map { section in
            var section = section
            section.rows = section.rows.map { Self.scoped($0, prefix: section.id + ":") }
            section.revision = try Self.collectionRevision(section.rows)
            return section
        }
        return PartFace(title: "Cognition", sections: sections)
    }

    @concurrent private func cognitionCollection(_ key: String, request: FaceReadRequest) async throws -> PartFace {
        let face = try await cognitionPage()
        return try Self.reading(face, key: key, request: request, readAction: "native.cognition.read")
    }

    @concurrent func memoryUpkeepPacket() async throws -> PartFaces.Packet {
        try await Self.pagePacket(memoryUpkeepPage(), readAction: "native.memory-upkeep.read")
    }

    @concurrent private func memoryUpkeepPage(refreshing: Bool = true) async throws -> PartFace {
        if refreshing {
            _ = await memory.refreshStatuses()
            await memory.refreshDiagnostics()
        }
        let reading = await EngineFaceMindProjection.memoryPresentation(self)
        var sections = [PartFace.Section(id: "commands", rows: [
            .init(id: "reindex", title: "Spotlight", actions: [.init(id: "run", label: "Reindex Spotlight",
                call: .init("memory.reindex"))]),
            .init(id: "refresh", title: "Memory diagnostics", actions: [.init(id: "run", label: "Check again",
                call: .init("memories.refresh"))])])]
        switch reading.state {
        case .waiting(let on):
            sections.append(.init(id: "waiting", style: .waiting, rows: [.init(id: "waiting", title: "Waiting on " + on)]))
        case .unavailable(let failure):
            sections.append(.init(id: "failure", style: .note,
                rows: [.init(id: "failure", title: failure.message, detail: failure.cause, tone: .failed)]))
        case .ready: break
        }
        sections.append(.init(id: "diagnostics", title: "Memory", style: .values, rows: reading.rows))
        if let issue = reading.embeddingIssue {
            sections.append(.init(id: "embedding", style: .note,
                rows: [.init(id: "embedding", title: issue.message, detail: issue.cause, tone: .failed)]))
        }
        if let issue = reading.cloudKitIssue {
            sections.append(.init(id: "cloudkit", style: .note,
                rows: [.init(id: "cloudkit", title: issue.message, detail: issue.cause, tone: .failed)]))
        }
        if reading.stale == true {
            sections.append(.init(id: "retained", style: .note,
                rows: [.init(id: "retained", title: "Showing retained memory diagnostics.", tone: .attention)]))
        }
        sections = try sections.map { section in
            var section = section
            section.rows = section.rows.map { Self.scoped($0, prefix: section.id + ":") }
            section.revision = try Self.collectionRevision(section.rows)
            return section
        }
        return PartFace(title: "Memory upkeep", sections: sections)
    }

    /// The native packet owns calls; the rewriteable seed receives only their names and the facts to draw.
    nonisolated private static func pagePacket(_ face: PartFace, readAction: String) throws -> PartFaces.Packet {
        var keys: [String: JSONValue] = [:]
        let levers = face.sections.filter { $0.id == "controls" || $0.id == "commands" }
        func row(_ original: PartFace.Row) throws -> JSONValue {
            let value = presented(original, readAction: readAction)
            guard case .object(var fields) = try JSONValue.fromEncodable(value) else {
                throw PartCallError(code: "bad_packet", message: "A cognition row encoded without its object.")
            }
            var key: [String: JSONValue] = [:]
            if let read = value.read {
                key["read"] = try JSONValue.fromEncodable(read)
                fields.removeValue(forKey: "read")
            }
            if let actions = value.actions, !actions.isEmpty {
                key["actions"] = try JSONValue.fromEncodable(actions)
                fields["actions"] = .array(actions.map { action in
                    var fields: [String: JSONValue] = ["id": .string(action.id), "label": .string(action.label)]
                    if let role = action.role { fields["role"] = .string(role.rawValue) }
                    if let unavailable = action.unavailable { fields["unavailable"] = .string(unavailable) }
                    return .object(fields)
                })
            }
            if let control = value.control, let call = control.call {
                key["set"] = try JSONValue.fromEncodable(call)
                if case .object(var controlFields)? = fields["control"] {
                    controlFields.removeValue(forKey: "call"); fields["control"] = .object(controlFields)
                }
            }
            if let children = value.rows { fields["rows"] = .array(try children.map(row)) }
            if !key.isEmpty { keys[value.id] = .object(key) }
            return .object(fields)
        }
        let sections = try face.sections.filter { $0.id != "controls" && $0.id != "commands" }.map { section -> JSONValue in
            guard case .object(var fields) = try JSONValue.fromEncodable(section) else {
                throw PartCallError(code: "bad_packet", message: "A cognition section encoded without its object.")
            }
            fields["rows"] = .array(try section.rows.prefix(256).map(row))
            if section.rows.count > 256 {
                var more: [String: JSONValue] = ["next": .string("256"), "total": .int(Int64(section.rows.count))]
                if let revision = section.revision { more["revision"] = .string(revision) }
                fields["more"] = .object(more)
                keys[section.id] = .object(["read": try JSONValue.fromEncodable(PartFace.Call(readAction))])
            }
            return .object(fields)
        }
        var facts: [String: JSONValue] = ["sections": .array(sections), "keys": .object(keys)]
        if let title = face.title { facts["title"] = .string(title) }
        guard let epoch = UInt64(exactly: (Date().timeIntervalSince1970 * 1_000).rounded(.down)) else {
            throw PartCallError(code: "page_epoch_invalid", message: "The system clock cannot identify this page reading.")
        }
        return PartFaces.Packet(facts: .object(facts), epoch: epoch, levers: levers)
    }

    nonisolated private static func collectionRevision(_ rows: [PartFace.Row]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(rows)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func scoped(_ row: PartFace.Row, prefix: String) -> PartFace.Row {
        var row = row
        row.id = prefix + row.id
        row.rows = row.rows?.map { scoped($0, prefix: row.id + ":") }
        return row
    }

    nonisolated private static func presented(_ row: PartFace.Row, readAction: String) -> PartFace.Row {
        var row = row
        if let detail = row.detail, detail.contains("\n") || detail.count > 160 {
            row.detail = "Open to read the complete evidence."
            row.expands = true
            row.read = .init(readAction)
        }
        row.rows = row.rows?.map { presented($0, readAction: readAction) }
        return row
    }

    nonisolated private static func reading(_ face: PartFace, key: String, request: FaceReadRequest,
                                           readAction: String) throws -> PartFace {
        if let section = face.sections.first(where: { $0.id == key }) {
            return PartFace(sections: [try collection(section, request: request, readAction: readAction)])
        }
        for section in face.sections {
            if let row = section.allRows.first(where: { $0.id == key }), let detail = row.detail {
                if let expected = request.revision, expected != section.revision {
                    throw PartCallError(code: "stale_read", message: "This evidence changed. Open its current row before reading it.")
                }
                guard let revision = section.revision else {
                    throw PartCallError(code: "evidence_revision_missing", message: "The evidence owner supplied no revision. Read the page again.")
                }
                let bodyKey = "evidence:" + revision + ":" + row.id
                let held = detail.utf8.count > PartFace.Block.inlineByteLimit
                let read: PartFace.Call? = held ? .init(readAction, ["row": .string(row.id), "revision": .string(revision)]) : nil
                return PartFace(title: row.title, line: row.value, sections: [
                    .init(id: "evidence", rows: [], block: .init(key: bodyKey, text: held ? nil : detail,
                        copy: true, read: read, revision: revision))])
            }
        }
        throw PartCallError(code: "evidence_unavailable", message: "This evidence is absent from the owner's current reading. Open the page again.")
    }

    nonisolated private static func evidenceIdentity(_ key: String) -> (revision: String, row: String)? {
        guard key.hasPrefix("evidence:") else { return nil }
        let fields = key.dropFirst("evidence:".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, let revision = fields.first, !revision.isEmpty,
              let row = fields.dropFirst().first, !row.isEmpty else { return nil }
        return (String(revision), String(row))
    }

    @concurrent private func evidenceBody(page: String, key: String) async throws -> String {
        guard let identity = Self.evidenceIdentity(key) else {
            throw PartCallError(code: "evidence_identity_invalid", message: "This document has no evidence identity. Open its row again.")
        }
        let face: PartFace
        switch page {
        case "cognition": face = try await cognitionPage()
        case "memory-upkeep": face = try await memoryUpkeepPage(refreshing: false)
        default: throw PartCallError(code: "evidence_owner_invalid", message: "This document has no cognition or memory owner.")
        }
        for section in face.sections {
            if let row = section.allRows.first(where: { $0.id == identity.row }), let detail = row.detail {
                guard section.revision == identity.revision else {
                    throw PartCallError(code: "stale_read", message: "This evidence changed. Open its current row before reading it.")
                }
                return detail
            }
        }
        throw PartCallError(code: "evidence_unavailable", message: "This evidence is absent from the owner's current reading. Open the page again.")
    }

    nonisolated private static func collection(_ section: PartFace.Section, request: FaceReadRequest,
                                              readAction: String) throws -> PartFace.Section {
        let start: Int
        if let expected = request.revision, expected != section.revision {
            throw PartCallError(code: "collection_changed", message: "This cognition collection changed. Read it again from the visible row.")
        }
        if let cursor = request.cursor {
            guard let parsed = Int(cursor), parsed >= 0, parsed <= section.rows.count else {
                throw PartCallError(code: "collection_cursor_invalid", message: "Read this collection again; its cursor is outside the current rows.")
            }
            start = parsed
        } else if let anchor = request.anchor, let index = section.rows.firstIndex(where: { $0.id == anchor }) { start = index }
        else { start = 0 }
        let remaining = section.rows.dropFirst(start)
        let rows = Array(remaining.prefix(256))
        let next = start + rows.count
        var page = section
        page.rows = rows.map { presented($0, readAction: readAction) }
        if next < section.rows.count {
            page.more = .init(next: String(next), total: section.rows.count, revision: section.revision,
                read: .init(readAction))
        }
        else { page.more = nil }
        return page
    }

    /// The typed owner keeps cognition's partial outcomes intact after the shared page admits its drawn call.
    @MainActor func cognitionPageOutcome(_ call: PartFace.Call, page: String) async throws -> FaceActOutcome? {
        guard let root = page.split(separator: "/", maxSplits: 1).first,
              root == "cognition" || root == "memory-upkeep" else { return nil }
        let act: FaceAct
        if root == "memory-upkeep" {
            switch call.action {
            case "memory.reindex": act = .reindexSpotlight
            case "memories.refresh": act = .refresh(.panel("Memories"))
            default: return nil
            }
        } else {
            guard let runtime = cognition else {
                throw PartCallError(code: "cognition_unavailable", message: "This root has no resident mind.")
            }
            let state = await runtime.subconsciousRuntimeState()
            guard state.enabled else {
                throw PartCallError(code: "cognition_disabled", message: "An inner life is off in Settings.")
            }
            let command: CognitionAct
            switch call.action {
            case "mind.think_now": command = .runMicrocycle
            case "mind.reflect": command = .runReflection
            case "mind.clear": command = .clearTransientState
            case "mind.settle_body": command = .settleContinuity
            case "mind.reset_body": command = .resetContinuity
            case "mind.workspace":
                guard case .bool(let value)? = call.args["value"] else {
                    throw PartCallError(code: "workspace_value_invalid", message: "Include workspace takes a Boolean value.")
                }
                command = .setAblation(name: "workspace", enabled: value)
            case "setting.set":
                guard case .string(let setting)? = call.args["setting"] else { return nil }
                switch setting {
                case "settings.inner_life_capsule", "settings.inner_life_background":
                    guard case .bool(let value)? = call.args["value"] else {
                        throw PartCallError(code: "cognition_value_invalid", message: "This cognition switch takes a Boolean value.")
                    }
                    command = setting == "settings.inner_life_capsule" ? .setCapsuleEnabled(value) : .setBackgroundEnabled(value)
                case "settings.daily_reflection_budget":
                    guard state.reflectionEnabled else {
                        throw PartCallError(code: "reflection_disabled", message: "Reflection is off in Settings.")
                    }
                    let number: Double
                    switch call.args["value"] {
                    case .int(let value)?: number = Double(value)
                    case .double(let value)?: number = value
                    default: throw PartCallError(code: "reflection_budget_invalid", message: "Choose a reflection budget from 0 through 8.")
                    }
                    guard let budget = Int(exactly: number), (0...8).contains(budget) else {
                        throw PartCallError(code: "reflection_budget_invalid", message: "Choose a reflection budget from 0 through 8.")
                    }
                    command = .setReflectionBudget(budget)
                default: return nil
                }
            default: return nil
            }
            act = .cognition(command)
        }
        let reply = try await faceActs.handle(act)
        switch reply {
        case .result(.object(let value)):
            guard case .string(let message)? = value["message"], case .string(let status)? = value["status"] else {
                throw WireFailure(code: "cognition_unconfirmed", message: "The cognition owner supplied no outcome words.", cause: nil, effects: .unknown)
            }
            let effects: FaceEffects
            switch status {
            case "skipped": effects = .none
            case "completed", "saved": effects = .known
            default:
                throw WireFailure(code: "cognition_unconfirmed", message: "The cognition owner returned an unrecognized outcome.",
                    cause: status, effects: .unknown)
            }
            return .init(words: message, effects: effects, accepted: true)
        case .committed(let result):
            if let failure = result.publicationFailure { return .interrupted(failure) }
            let words: String?
            if case .string(let text) = result.value { words = text } else { words = nil }
            return .init(words: words, effects: result.effects, accepted: true)
        case .acknowledged: return .init(effects: .none, accepted: true)
        case .failed(let failure), .refused(let failure): return .interrupted(failure)
        default:
            throw WireFailure(code: "cognition_unconfirmed", message: "The owner has not confirmed this page command.", cause: nil, effects: .unknown)
        }
    }
}
