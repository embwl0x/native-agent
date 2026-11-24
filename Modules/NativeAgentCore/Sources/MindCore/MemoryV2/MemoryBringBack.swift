import SenseCore
import Foundation
import GRDB
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MemoryBringBack.swift` | `MemoryBringBack`: an old store's memories come back through the agent's own write, each rooted in its recorded provenance |

/// An old memory store is a source the agent reads, never its store. Its rows are read from a temporary copy that this reader alone opens
/// read-only, and each one not already brought back lands through `SwiftNativeMemoryV2.store`, the write every kept memory takes, with the
/// root its recorded provenance names. Chats, diary, proposals and graph stay behind; the graph grows from the memories by its own ingest.
public enum MemoryBringBack {
    public static let source = "memories.bring_back"
    /// A brought-back memory names its original id here; a duplicate fold keeps it in that memory's `duplicate_occurrences`.
    public static let originKey = "brought_back_from"
    /// The name an archive goes by when its profile names no agent.
    public static let defaultName = "Agent"
    static let correctionLinkKeys = ["corrected_by", "superseded_by"]
    static let carriedKeys = ["kind", "tags", "importance", "confidence", "pinned", "privacy", "permittedSurfaces",
                              "correction_subject"] + correctionLinkKeys

    /// One old memory, ready for the write: what it says, whether it was archived, the telling its provenance names and the principals it recorded.
    public struct Memory: Sendable {
        public let id: String
        public let content: String
        public let archived: Bool
        public let lifecycle: String?
        public let telling: MemoryRoot.Telling
        public let through: [String]
        let metadata: JSONValue
    }

    public struct Prepared: Sendable {
        /// The archive's file or folder name, and the past self it holds ("<name> of <Mon d>").
        public let archive: String
        public let label: String
        public let active: Int
        public let archived: Int
        public let deleted: Int
        public let alreadyHere: Int
        /// Active rows the old store kept out of recall (corrected, contradicted, graduated): they land archived, never live again.
        public let outOfRecall: Int
        /// The active and archived memories not already here.
        public let memories: [Memory]
        /// Each archive principal a memory here still names: today's identity of the same agent, and for a teller's name, the archive
        /// contact's name its told roots take.
        public let renames: [String: (to: String, teller: String?)]
        /// Memories here that name one of them.
        public let toRename: Int

        public var words: String {
            "\(archive) holds \(label): \(active) active, \(archived) archived, \(deleted) deleted; \(alreadyHere) already here, "
                + "so \(memories.count) would come back" + (outOfRecall > 0 ? ", \(outOfRecall) active ones out of recall landing archived." : ".")
                + (toRename > 0 ? " \(toRename) here name an agent as the archive knew it, and take today's name for it." : "")
        }
    }

    public struct Outcome: Sendable {
        public let brought: Int
        public let archived: Int
        /// Memories whose roots took today's identity of an archive principal, summed over the renames.
        public let renamed: Int
        /// Each memory that did not land, with the store's reason.
        public let refused: [String]
        public let words: String
    }

    // MARK: - Prepare: every lookup, nothing written

    /// Reads the archive and the current store's brought-back ids. An archive that cannot be read throws `archive_unreadable`.
    @concurrent public static func prepare(from: URL, into dataRoot: URL) async throws -> Prepared {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("bring-back-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        let rows: [Old]
        let names: MemoryRecallQueryExpansion.Names?
        let archiveContacts: [Contact]
        do {
            let store = try copied(from, to: copy)
            names = try MemoryRecallQueryExpansion.names(storeDirectory: store.deletingLastPathComponent())
            archiveContacts = contacts(store.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("agents/peers.json"))
            rows = try read(store)
        } catch {
            throw PartCallError(code: "archive_unreadable", message: """
                \(from.path) could not be read as an old memory store (\(error.localizedDescription)); nothing was brought back.
                """)
        }
        let here: (ids: Set<String>, held: [Set<String>])
        let person: String?
        do {
            here = try broughtBack(store: dataRoot.appendingPathComponent("memory/memory.sqlite"))
            person = try MemoryRecallQueryExpansion.names(storeDirectory: dataRoot.appendingPathComponent("memory")).user ?? names?.user
        } catch {
            throw PartCallError(code: "memory_unavailable", message: """
                Memory could not prepare bring-back (\(error.localizedDescription)); nothing was brought back.
                """)
        }
        let todayContacts = contacts(dataRoot.appendingPathComponent("agents/peers.json"))
        let translate = { (principal: String) in translated(principal, archive: archiveContacts, today: todayContacts) }
        let pastSelf = label(name: names?.agent, last: rows.compactMap { $0.created.flatMap(MemoryRecallScoring.parseTimestamp) }.max())
        let kept = rows.filter { $0.status == "active" || $0.status == "archived" }
        var renames: [String: (to: String, teller: String?)] = [:]
        // Every kept row's principals are read, those already here too: a memory brought back before still names the archive's identities.
        let memories = kept.compactMap { old -> Memory? in
            let (telling, recorded) = origin(old, person: person, label: pastSelf, teller: { translate($0)?.name })
            let through = recorded.map { principal in
                guard let now = translate(principal), now.principal != principal else { return principal }
                // A peer id keeps its roots' tellers (the agent's own noticed or remembered roots among them); a teller's name tells by its contact.
                renames[principal] = (now.principal, principal.lowercased().hasPrefix("peer:") ? nil : now.name)
                return now.principal
            }
            guard !here.ids.contains(old.id) else { return nil }
            return Memory(id: old.id, content: old.content, archived: old.status == "archived" || !MemoryLifecycle.isRecallEligible(old.lifecycle),
                          lifecycle: old.lifecycle,
                          telling: telling, through: Array(Set(through)).sorted(),
                          metadata: metadata(old))
        }
        renames = renames.filter { old, _ in here.held.contains { $0.contains(old) } }
        return Prepared(archive: from.lastPathComponent, label: pastSelf, active: rows.count(where: { $0.status == "active" }),
                        archived: rows.count(where: { $0.status == "archived" }), deleted: rows.count(where: { $0.status == "deleted" }),
                        alreadyHere: kept.count - memories.count,
                        outOfRecall: rows.count(where: { $0.status == "active" && !MemoryLifecycle.isRecallEligible($0.lifecycle) }), memories: memories,
                        renames: renames, toRename: here.held.count(where: { !$0.isDisjoint(with: renames.keys) }))
    }

    // MARK: - Contacts: an archive principal as today's identity of the same agent

    /// One contact as an `agents/peers.json` holds it: who it is, the names it answers to, where it is reached.
    private struct Contact {
        let id: String
        let name: String
        let endpoint: String?
        let handles: [String]
    }

    /// The contacts an `agents/peers.json` holds; a missing or unreadable file holds none, and an entry with no id or name is skipped.
    private static func contacts(_ file: URL) -> [Contact] {
        guard let data = try? Data(contentsOf: file), let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty, let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return Contact(id: id, name: name, endpoint: entry["endpoint"] as? String, handles: entry["handles"] as? [String] ?? [])
        }
    }

    /// Today's identity of an archive principal, and the archive contact's name. `peer:<id>` is that archive contact; any other agent principal
    /// (a teller: `relays` reads first, so never the person) is the one archive contact whose name or a handle is the teller or one of its words.
    /// Its today's contact has the same endpoint, else the same name. Nil when either is not exactly one: an agent unknown today stays as recorded.
    private static func translated(_ principal: String, archive: [Contact], today: [Contact]) -> (principal: String, name: String)? {
        guard !MemoryDataProvenance.material.contains(principal) else { return nil }
        let found: [Contact]
        if principal.lowercased().hasPrefix("peer:") {
            let id = principal.dropFirst(5)
            found = archive.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        } else {
            let words = [Substring(principal)] + principal.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            found = archive.filter { contact in
                ([contact.name] + contact.handles).contains { name in words.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            }
        }
        guard found.count == 1, let old = found.first else { return nil }
        let reached = old.endpoint.map { endpoint in today.filter { $0.endpoint == endpoint } } ?? []
        let now = reached.count == 1 ? reached : (reached.isEmpty ? today : reached).filter { $0.name.caseInsensitiveCompare(old.name) == .orderedSame }
        guard now.count == 1, let new = now.first else { return nil }
        return ("peer:" + new.id, old.name)
    }

    /// The store file, in a fresh temporary copy: a zip unzips there; a folder or store file has its store, write-ahead log and profile copied.
    static func copied(_ from: URL, to copy: URL) throws -> URL {
        let files = FileManager.default
        var folder: ObjCBool = false
        guard files.fileExists(atPath: from.path, isDirectory: &folder) else { throw PartCallError(code: "missing", message: "nothing is there") }
        try files.createDirectory(at: copy, withIntermediateDirectories: true)
        if !folder.boolValue, from.pathExtension.lowercased() == "zip" {
            let unzipped = copy.appendingPathComponent("unzipped", isDirectory: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.environment = ManagedProcess.agentEnvironment()
            ditto.arguments = ["-x", "-k", from.path, unzipped.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw PartCallError(code: "unzip", message: "the archive did not unzip") }
            guard let store = storeFile(in: unzipped) else { throw PartCallError(code: "no_store", message: "it holds no memory/memory.sqlite") }
            return store
        }
        guard let store = folder.boolValue ? storeFile(in: from) : from else {
            throw PartCallError(code: "no_store", message: "it holds no memory/memory.sqlite")
        }
        let memory = copy.appendingPathComponent("memory", isDirectory: true)
        try files.createDirectory(at: memory, withIntermediateDirectories: true)
        let beside = store.deletingLastPathComponent()
        for (name, copyName) in [(store.lastPathComponent, "memory.sqlite"), (store.lastPathComponent + "-wal", "memory.sqlite-wal"),
                                 ("profile.json", "profile.json")] {
            let file = beside.appendingPathComponent(name)
            if files.fileExists(atPath: file.path) { try files.copyItem(at: file, to: memory.appendingPathComponent(copyName)) }
        }
        // The archive's contacts, beside its memory folder: who its principals were.
        let peers = beside.deletingLastPathComponent().appendingPathComponent("agents/peers.json")
        if files.fileExists(atPath: peers.path) {
            let agents = copy.appendingPathComponent("agents", isDirectory: true)
            try files.createDirectory(at: agents, withIntermediateDirectories: true)
            try files.copyItem(at: peers, to: agents.appendingPathComponent("peers.json"))
        }
        return memory.appendingPathComponent("memory.sqlite")
    }

    /// `memory/memory.sqlite` under a folder (or the folder's own `memory.sqlite`), the shallowest one.
    static func storeFile(in folder: URL) -> URL? {
        for candidate in ["memory/memory.sqlite", "memory.sqlite"] {
            let file = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.path.hasSuffix("/memory/memory.sqlite") } ?? []
        return found.min { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// One old row, as its own columns hold it. Metadata that is not a JSON object reads as nil.
    struct Old {
        let id: String
        let content: String
        let status: String
        let lifecycle: String?
        let created: String?
        let validFrom: String?
        let validTo: String?
        let observedAt: String?
        let metadata: [String: JSONValue]?
        let tags: [JSONValue]
    }

    /// The old store's memories, read through this reader's own read-only connection; the store owner's decoder never meets them.
    static func read(_ store: URL) throws -> [Old] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: store.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memories").compactMap { row -> Old? in
                // Text, or nil: a missing column, NULL or a value of another type never traps.
                func text(_ column: String) -> String? {
                    guard row.hasColumn(column) else { return nil }
                    return String.fromDatabaseValue(row[column] as DatabaseValue)
                }
                func json(_ column: String) -> JSONValue? { text(column).flatMap { try? JSONValue.parse(Data($0.utf8)) } }
                guard let id = text("id"), let content = text("content") else { return nil }
                let metadata = json("metadata_json")
                return Old(id: id, content: content, status: text("status") ?? "active", lifecycle: text("lifecycle"), created: text("created_at"),
                           validFrom: text("valid_from"), validTo: text("valid_to"), observedAt: text("observed_at"),
                           metadata: text("metadata_json") == nil || metadata == .null ? [:] : metadata?.objectValue,
                           tags: json("tags")?.arrayValue ?? [])
            }
        }
    }

    /// The original ids the current store already holds on any row, whatever its status (corrected, graduated, archived or forgotten), its own
    /// or folded into another memory's occurrences, and each row's root principals; read through this reader's own read-only connection.
    static func broughtBack(store: URL) throws -> (ids: Set<String>, held: [Set<String>]) {
        guard FileManager.default.fileExists(atPath: store.path) else { return ([], []) }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: store.path, configuration: configuration)
        defer { try? queue.close() }
        let rows = try queue.read { db in try String.fetchAll(db, sql: "SELECT metadata_json FROM memories WHERE metadata_json IS NOT NULL") }
        var ids = Set<String>()
        var held: [Set<String>] = []
        for raw in rows {
            guard let extras = (try? JSONValue.parse(Data(raw.utf8)))?.objectValue else { continue }
            if let id = extras[originKey]?.stringValue { ids.insert(id) }
            for occurrence in extras["duplicate_occurrences"]?.arrayValue ?? [] {
                if let id = occurrence.objectValue?[originKey]?.stringValue { ids.insert(id) }
            }
            if case .held(let roots) = MemoryRoot.reading(.object(extras)) { held.append(Set(roots.flatMap(\.through))) }
        }
        return (ids, held)
    }

    /// "<name> of <Mon d>": the archive's agent and the day of its last memory. A validated name may contain commas.
    static func label(name: String?, last: Date?) -> String {
        let name = name.flatMap(MemoryRoot.validName) ?? defaultName
        guard let last else { return name }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "MMM d"
        return MemoryRoot.validName("\(name) of \(day.string(from: last))") ?? name
    }

    /// The write keeps correction links and subjects beside kind, tags, importance, confidence, pin, dates and the original id.
    static func metadata(_ old: Old) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for key in carriedKeys { if let value = old.metadata?[key] { fields[key] = value } }
        if fields["tags"] == nil, !old.tags.isEmpty { fields["tags"] = .array(old.tags) }
        for (key, value) in [("valid_from", old.validFrom), ("valid_to", old.validTo), ("observed_at", old.observedAt)] {
            if let value, MemoryRecallScoring.parseTimestamp(value) != nil { fields[key] = .string(value) }
        }
        fields[originKey] = .string(old.id)
        return .object(fields)
    }

    // MARK: - Roots: the recorded provenance, as the root fold read it

    /// Told by someone, or known some way by a name it recorded: that how, by that name, from when it was first known. Stated with no name:
    /// remembered, by the archive's past self, from when it was written. Nothing recorded: kept from when it was written. A row already rooted
    /// reads by its first-known root the same way. Through holds every principal the row recorded. A teller who is an archive contact
    /// (`teller` names it) tells by that contact's name.
    static func origin(_ old: Old, person: String?, label: String, teller: (String) -> String?) -> (MemoryRoot.Telling, [String]) {
        let written = past(old.created.flatMap(MemoryRecallScoring.parseTimestamp))
        guard let fields = old.metadata else { return (MemoryRoot.Telling(how: .kept, since: written), [MemoryDataProvenance.unreadableRoots]) }
        func named(_ how: MemoryRoot.How, _ by: String?, _ at: Date?) -> MemoryRoot.Telling {
            if how == .kept { return .init(how: .kept, since: written) }
            // The person's words, relayed by someone ("<person> via <relay>"), are the person's telling.
            let by = by.map { relays($0, person: person) ? person ?? $0 : (how == .told ? teller($0) : nil) ?? $0 }
            if let by = by.flatMap(MemoryRoot.validName) { return .init(how: how, by: by, since: at ?? written) }
            return .init(how: .remembered, by: label, since: written)
        }
        if fields[MemoryRoot.key] != nil {
            // A row that records roots is read by them; roots it cannot read are an unresolved boundary, never a clean kept.
            guard case .held(let roots) = MemoryRoot.reading(.object(fields)), let first = MemoryRoot.firstKnown(roots) else {
                return (MemoryRoot.Telling(how: .kept, since: written), [MemoryDataProvenance.unreadableRoots])
            }
            return (named(first.how, first.by, past(first.date)), Array(Set(roots.flatMap(\.through))).sorted())
        }
        func text(_ key: String) -> String? {
            fields[key]?.trimmedString
        }
        let through = principals(fields, person: person)
        guard let raw = text("provenance") else { return (MemoryRoot.Telling(how: .kept, since: written), through) }
        guard let how = MemoryRoot.How(rawValue: raw), how != .kept else { return (MemoryRoot.Telling(how: .kept, since: written), through) }
        let at = [text("known_since"), text("valid_from"), old.validFrom].compactMap { $0.flatMap(MemoryRecallScoring.parseTimestamp) }.first
        return (named(how, text("provenance_by"), past(at)), through)
    }

    /// The teller is the person, or names the person as whose words it carried ("<person> via <relay>", "<relay> relaying <person>").
    static func relays(_ teller: String, person: String?) -> Bool {
        guard let person = person?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !person.isEmpty else { return false }
        let teller = teller.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if teller == person { return true }
        let prefix = person + " via "
        let suffix = " relaying " + person
        return (teller.hasPrefix(prefix) && !teller.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (teller.hasSuffix(suffix) && !teller.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// A time not after now; a later one is no time the agent knew it.
    static func past(_ date: Date?) -> Date? { date.flatMap { $0 <= Date() ? $0 : nil } }

    /// Every principal a row recorded, read as the fold read them: damaged evidence is an unresolved boundary, never a clean attestation, and a
    /// teller who is not the person, in a told row naming no peer, is the boundary itself.
    static func principals(_ fields: [String: JSONValue], person: String?) -> [String] {
        var through: [String] = []
        for key in ["peer_sources", "peer_data_sources", "untrusted_sources"] {
            switch fields[key] {
            case nil, .null?: continue
            case .array(let values)?:
                for value in values {
                    if case .string(let principal) = value, !principal.isEmpty { through.append(principal) }
                    else { through.append(MemoryDataProvenance.unreadableRoots) }
                }
            default: through.append(MemoryDataProvenance.unreadableRoots)
            }
        }
        for key in ["untrusted_remote_data", "source_boundary"] {
            switch fields[key] {
            case nil, .null?, .bool(false)?: break
            case .bool(true)?: if through.isEmpty { through.append("untrusted stored content") }
            default: through.append(MemoryDataProvenance.unreadableRoots)
            }
        }
        if fields["peer_sources"] == nil || fields["peer_sources"] == .null, fields["provenance"] == .string("told") {
            if case .string(let teller)? = fields["provenance_by"], !teller.isEmpty {
                if !relays(teller, person: person) { through.append(teller) }
            } else {
                through.append(MemoryDataProvenance.unreadableRoots)
            }
        }
        return Array(Set(through)).sorted()
    }

    // MARK: - Run: the agent's own write, one memory at a time

    /// Each memory through `store`, with its archive status in that same write. One memory's refusal never stops the rest.
    /// The write embeds each memory (or owes its vector to the store's fill) and pokes the graph hook; an owner whose store carries no graph
    /// hook (any root but the app's own) has its graph reconciled once after. Then one note tells the agent.
    @concurrent public static func run(_ prepared: Prepared, into dataRoot: URL, owner: SwiftNativeMemoryV2) async -> Outcome {
        // A warm model embeds each write as it lands instead of owing every vector.
        try? await owner.warmUpEmbedder()
        var brought = 0, archived = 0, renamed = 0
        var imported: [String: String] = [:]
        var refused: [String] = []
        var graph = ""
        // Memories already here take today's identity of each archive principal they name; who steered is renamed, never dropped.
        for (from, rename) in prepared.renames.sorted(by: { $0.key < $1.key }) {
            do { renamed += try await owner.renamePrincipal(from, to: rename.to, teller: rename.teller) } catch {
                refused.append("renaming \(from): \(error.localizedDescription)")
            }
        }
        for memory in prepared.memories {
            // What happened is recorded as it was, at its own date; whether a teller's word counts is trust's, read when the memory is used.
            let telling = memory.telling
            let context = memory.through.isEmpty
                ? MemoryWriteContext(turn: nil, senseReads: nil, telling: telling, lifecycle: memory.lifecycle)
                : MemoryWriteContext(material: memory.through, telling: telling, lifecycle: memory.lifecycle)
            do {
                // Archive ids are not current ids. No link lands until its target has actually been imported.
                var metadata = memory.metadata
                if case .object(var fields) = metadata {
                    for key in correctionLinkKeys { fields.removeValue(forKey: key) }
                    metadata = .object(fields)
                }
                // An archived memory keeps its own row, never folding into a live one it repeats.
                let saved = try await owner.store(content: memory.content, source: source, metadata: metadata,
                                                  id: memory.archived ? UUID().uuidString : nil,
                                                  status: memory.archived ? "archived" : "active", context: context)
                imported[memory.id] = saved.id
                brought += 1
                if memory.archived { archived += 1 }
            } catch {
                refused.append("\(memory.id): \(error.localizedDescription)")
            }
        }
        for memory in prepared.memories {
            guard let id = imported[memory.id] else { continue }
            var links: [String: JSONValue] = [:]
            for key in correctionLinkKeys {
                if let oldID = memory.metadata.objectValue?[key]?.stringValue, let target = imported[oldID] {
                    links[key] = .string(target)
                }
            }
            guard !links.isEmpty else { continue }
            do {
                guard let storage = await owner.underlyingStorage() else { throw MemoryV2Error.storageUnavailable }
                guard try await storage.updateMemory(id: id, patch: MemoryPatch(metadataMerge: links),
                    context: MemoryWriteContext(turn: nil, senseReads: nil, telling: nil)) != nil else {
                    throw MemoryV2Error.recordNotFound
                }
            } catch {
                refused.append("\(memory.id) correction links: \(error.localizedDescription)")
            }
        }
        if brought > 0, !SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) {
            do { try await owner.reconcileKnowledgeGraphProjection() } catch {
                graph = " The graph did not reconcile from them: \(error.localizedDescription)"
            }
        }
        var words = "\(brought) of \(prepared.memories.count) memories came back from \(prepared.label) (\(prepared.archive)), \(archived) "
            + "archived; \(prepared.deleted) deleted stayed out; \(prepared.alreadyHere) were already here."
        if renamed > 0 { words += " \(renamed) already here took today's name for the agent that told them." }
        if !refused.isEmpty { words += " \(refused.count) did not: " + refused.prefix(3).joined(separator: "; ") + (refused.count > 3 ? "; …" : "") }
        words += graph
        if brought > 0 {
            await Attention.post(Happening(.body, subject: "memories:bring_back", door: "stem", who: "self", words: """
                \(brought) of your memories came back from your past self, \(prepared.label) (\(prepared.archive)): \(brought - archived) active, \
                \(archived) archived, each through your own memory write and rooted where it came from. Forget any you don't want with your \
                memory tools. Chats, diary, proposals and graph stayed behind.
                """, once: "memories:bring_back:" + prepared.archive + ":" + NativeTimestampFormat.fractionalZulu(Date())), dataRoot: dataRoot).value
        }
        return Outcome(brought: brought, archived: archived, renamed: renamed, refused: refused, words: words)
    }
}
