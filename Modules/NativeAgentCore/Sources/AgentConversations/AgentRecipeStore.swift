import Foundation
import Experiences
import NativeAgentCore
import os
import PersistenceCore
// Blueprint: | `AgentRecipeStore.swift` | `AgentRecipeStore` enum: one recipe per agent host under agents/recipes/, seeded from the host tables and bundled `Resources/grok-routine.json` through the existing authored-field-preserving merge, read by `AgentHostDirectory.rows`, and one per A2A contact under its id (`AgentHostRow.A2A`, `recipe(for:)` seeds a missing one on the spot); every consumer checks the current catalog under the store/file locks, reusing the last read only while every recipe file keeps its stat identity; `load`, `recipe`, `launch` (Trust's reader), `read`/`write` (the door's, one shape check, under the file lock; write can create a new host.id without overwriting existing bytes), `learn` (a dry run's findings, source "learned"), `dryRun` |

/// HOW THIS APP REACHES EACH AGENT, as files she can read and fix.
///
/// One recipe per agent host under agents/recipes/<host-id>.json: the row
/// every connect, send and health check reads (`AgentHostDirectory.rows`),
/// with its launch line, search paths and window labels; and one per A2A
/// contact under its id, its card. Host tables and bundled JSON are seeds. A
/// missing file is seeded at version 1; later seeds update only fields still
/// owned by the seed. Authored fields survive every update. A host no table
/// knows loads from its file alone.
public enum AgentRecipeStore {
    public struct Recipe: Codable, Sendable, Equatable {
        /// 1 as seeded; each `write` bumps it. A hand edit bumps nothing.
        public var recipeVersion: Int
        /// The app build whose table this recipe was seeded from.
        public var seededFrom: String
        public var updatedAt: String
        /// What wrote this version: "seeded", "re-seeded", "written" or "learned".
        public var source: String
        /// `host`'s digest as this app last wrote it; a hand edit leaves it behind.
        public var digest: String
        public var host: AgentHostRow
        /// The last seed and fields authors took over, retained in this same recipe.
        public var seedHost: AgentHostRow? = nil
        public var authoredFields: [String]? = nil

        /// What a round trip's proof records, so any later change reads as one.
        public var hostDigest: String { get throws { try JSONValue.fromEncodable(host).digest } }
    }

    private struct Loaded: Sendable {
        var root: URL
        var recipes: [Recipe]
        /// Files that did not read as a recipe, by host id: what is wrong and how to fix it.
        var problems: [String: String]
    }

    /// The bound data root and the last catalog read from it, kept with the
    /// stat identity of every file it read. Reused only while every one of
    /// them is unchanged, so each read is still a checked current read.
    private struct Catalog: Sendable {
        var root: URL?
        var stamps: [String: SnapshotTailOpLog.FileStamp] = [:]
        var read: Loaded?
    }

    private static let catalog = OSAllocatedUnfairLock<Catalog>(initialState: Catalog())

    /// Bound from `agent_message`'s `dry_run` input: the contact runs its recipe
    /// dry. An ACP send stops after its handshake, a desktop chat finds its
    /// controls without typing, a command line checks its executable and args, an
    /// A2A send stops after its card, auth and one task listing; nothing she
    /// wrote goes out and no other route runs.
    @TaskLocal package static var dryRun = false

    /// Every host's recipe from a checked current read of the bound data root.
    public static var recipes: [Recipe] { withLoaded { $0.recipes } }

    public static var rows: [AgentHostRow] { recipes.map(\.host) }

    /// Effectful callers must not launch a retained stale catalog generation.
    public static func requireAvailable() throws {
        try withLoaded { state -> Result<Void, ToolFailureError> in
            guard let failure = state.problems["catalog"] else { return .success(()) }
            return .failure(ToolFailureError(failure, effects: .none, owner: folder(state.root).path,
                nextCall: ToolFailureError.call("app", ["action": .string("agent.recipe")]),
                code: "agent_recipe_catalog_unavailable",
                instruction: "Repair the named source, then read the recipe catalog again."))
        }.get()
    }

    public static func recipe(_ id: String) -> Recipe? { withLoaded { $0.recipes.first { $0.host.id == id } } }

    /// Setup uses the same checked current catalog as routing and display.
    public static func grokRoutine(dataRoot: URL) throws -> AgentHostRow.GrokRoutine {
        try withLoaded(dataRoot: dataRoot) { state -> Result<AgentHostRow.GrokRoutine, ShapeError> in
            guard state.root.standardizedFileURL == dataRoot.standardizedFileURL else {
                return .failure(ShapeError(description: "The loaded agent recipes belong to a different data root"))
            }
            if let failure = state.problems["catalog"] ?? state.problems["grok-bot"] { return .failure(ShapeError(description: failure)) }
            guard let routine = state.recipes.first(where: { $0.host.id == "grok-bot" })?.host.grokRoutine else {
                return .failure(ShapeError(description: "host.grokRoutine is missing from agents/recipes/grok-bot.json"))
            }
            return .success(routine)
        }.get()
    }

    /// An A2A contact's recipe. A missing file is seeded now
    /// (`AgentHostDirectory.seed`); one that is there and does not read as a
    /// recipe throws, saying what does not read.
    public static func recipe(for peer: AgentPeerContact) throws -> Recipe {
        try withLoaded { state -> Result<Recipe, ShapeError> in
            if let failure = state.problems["catalog"] { return .failure(ShapeError(description: failure)) }
            let file = folder(state.root).appendingPathComponent(peer.id + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                if let known = state.recipes.first(where: { $0.host.id == peer.id }) { return .success(known) }
            } else {
                let build = NativeAgentBuildIdentity.current
                seed(AgentHostDirectory.seed(peer), in: folder(state.root), from: "\(build.version) (\(build.build))")
                guard FileManager.default.fileExists(atPath: file.path) else {
                    return .failure(ShapeError(description: "agents/recipes/\(peer.id).json is missing and could not be written"))
                }
            }
            do {
                let recipe = try validated(file: file)
                guard recipe.host.id == peer.id else { throw ShapeError(description: "host.id is not \(peer.id)") }
                state.recipes.removeAll { $0.host.id == peer.id }
                state.recipes.append(recipe)
                state.problems[peer.id] = nil
                return .success(recipe)
            } catch { return .failure(ShapeError(description: "agents/recipes/\(peer.id).json doesn't read as a recipe: \(error)")) }
        }.get()
    }

    /// What a host's validated recipe launches, for the Trust boundary (`AgentHostLaunches`).
    public static func launch(_ id: String, dataRoot: URL) throws -> AgentHostLaunches.Launch {
        guard validID(id) else { throw ShapeError(description: "Invalid host recipe identity.") }
        let file = folder(dataRoot).appendingPathComponent(id + ".json")
        return try CredentialFileLock.withLock(file) {
            let recipe: Recipe
            do { recipe = try validated(file: file) }
            catch { throw ShapeError(description: "\(file.path) could not be read as the addressed host recipe: \(error.localizedDescription)") }
            guard recipe.host.id == id else { throw ShapeError(description: "host.id is not \(id) in \(file.path)") }
            return (recipe.host.acp, recipe.host.commandLine)
        }
    }

    /// At launch: seed what is missing (or still an older seed), then read every recipe.
    public static func load(dataRoot: URL) {
        // Listed outside the lock: reading contacts reads host recipes.
        do {
            let peers = try AgentPeerStore(dataRoot: dataRoot).list().filter { $0.transport == .a2a }
            catalog.withLock { catalog in
                catalog = Catalog(root: dataRoot)
                _ = scan(dataRoot, a2a: peers)
            }
        } catch {
            let words = "Agent recipes could not read their saved contacts: " + error.localizedDescription
                + ". Repair agents/peers.json, then reload the recipe catalog."
            catalog.withLock { $0 = Catalog(root: dataRoot) }
            owe(dataRoot, id: "catalog", file: dataRoot.appendingPathComponent("agents/peers.json"), words: words, recipe: nil)
        }
    }

    /// `agent.recipe`: one host's recipe with the version a write replaced, or every host's.
    public static func read(host: String?) -> JSONValue {
        withLoaded { state in
            let folder = folder(state.root)
            if let failure = state.problems["catalog"] {
                return .object(["status": .string("unavailable"), "detail": .string(failure),
                    "stale": .bool(!state.recipes.isEmpty), "folder": .string(folder.path),
                    "problems": .object(state.problems.mapValues(JSONValue.string))])
            }
            guard let host else {
                return .object(["status": .string("ok"), "recipes": .array(state.recipes.map { recipe in .object([
                    "host": .string(recipe.host.id), "name": .string(recipe.host.displayName), "route": .string(recipe.host.route.rawValue),
                    "recipe_version": .int(Int64(recipe.recipeVersion)), "source": .string(recipe.source)]) }),
                    "problems": .object(state.problems.mapValues(JSONValue.string)), "folder": .string(folder.path)])
            }
            guard let recipe = AgentHostDirectory.named(host, in: state.recipes, \.host) else { return unknown(host, state) }
            var result: [String: JSONValue] = ["status": .string("ok"), "host": .string(recipe.host.id),
                "path": .string(folder.appendingPathComponent(recipe.host.id + ".json").path),
                "recipe": (try? JSONValue.fromEncodable(recipe)) ?? .null]
            if let previous = try? JSONValue.parse(Data(contentsOf: folder.appendingPathComponent(recipe.host.id + ".previous.json"))) {
                result["previous"] = previous
            }
            return .object(result)
        }
    }

    /// `agent.recipe_write`: one host's whole recipe, created or replaced. The document is
    /// the recipe as read, edited: every field the shape has and none it
    /// lacks, at the version it was read. The write bumps that version and
    /// keeps the replaced file as <id>.previous.json; writing that back, at
    /// whatever version it carries, undoes it.
    public static func write(host: String, document: JSONValue, undoing receipt: JSONValue? = nil) -> JSONValue {
        let given: Recipe
        do { given = try validated(document) }
        catch { return refused("invalid_recipe", "recipe doesn't match a recipe's shape: \(error). Start from agent.recipe's recipe and change only what you mean to.") }
        return withLoaded { state in
            let id = AgentHostDirectory.named(host, in: state.recipes, \.host)?.host.id ?? host
            guard let index = state.recipes.firstIndex(where: { $0.host.id == id }) else {
                guard receipt == nil, validID(id), given.host.id == id else { return unknown(host, state) }
                let file = folder(state.root).appendingPathComponent(id + ".json")
                do { return try CredentialFileLock.withLock(file) {
                    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else {
                        return refused("existing_recipe", "\(file.path) is a symbolic link. Replace it with a regular file before writing its recipe.")
                    }
                    // One that did not load is kept beside it, never written over unseen.
                    if FileManager.default.fileExists(atPath: file.path) {
                        let previous = folder(state.root).appendingPathComponent(id + ".previous.json")
                        try? FileManager.default.removeItem(at: previous)
                        try FileManager.default.moveItem(at: file, to: previous)
                    }
                    var saved = given
                    saved.recipeVersion = 1
                    saved.source = "written"
                    saved.updatedAt = ISO8601DateFormatter().string(from: Date())
                    saved.digest = try saved.hostDigest
                    try write(saved, to: file)
                    state.recipes.append(saved)
                    state.problems[id] = nil
                    return .object(["status": .string("written"), "changed": .bool(true), "host": .string(id),
                        "recipe_version": .int(1), "host_digest": .string(try saved.hostDigest), "path": .string(file.path),
                        "undo_unavailable": .string("This new recipe has no previous version; its file is \(file.path).")])
                } } catch { return writeFailed(file: file, previous: nil, error: error) }
            }
            let file = folder(state.root).appendingPathComponent(id + ".json")
            let previous = folder(state.root).appendingPathComponent(id + ".previous.json")
            do {
                // Read, compare, keep the previous and write under the file's lock.
                return try CredentialFileLock.withLock(file) {
                    // A hand edit since this app read the file is never written over unseen;
                    // a valid one is what the next read shows.
                    let onDisk = try validated(file: file)
                    guard onDisk == state.recipes[index] else {
                        if onDisk.host.id == id { state.recipes[index] = onDisk }
                        return refused("stale_recipe", "\(file.path) changed since this app read it; read it again.")
                    }
                    var saved = state.recipes[index]
                    let currentHostDigest = try saved.hostDigest
                    if case .object(let receipt) = receipt,
                       receipt["host"] != .string(id) || receipt["recipe_version"] != .int(Int64(saved.recipeVersion))
                        || receipt["host_digest"] != .string(currentHostDigest) {
                        return refused("stale_recipe", "The recipe changed after that receipt. Read it again with agent.recipe.")
                    }
                    guard given.host.id == saved.host.id else { return refused("invalid_recipe", "host.id stays \(saved.host.id).") }
                    // Undo: the version a write replaced goes back whatever version it carries.
                    let restored = (try? validated(file: previous)).flatMap { $0.host == given.host ? $0.recipeVersion : nil }
                    guard restored != nil || given.recipeVersion == saved.recipeVersion else {
                        return refused("stale_recipe", "That recipe was read at version \(given.recipeVersion); it is at \(saved.recipeVersion) now. Read it again with agent.recipe.")
                    }
                    let changed = JSONValue.differences((try? JSONValue.fromEncodable(saved.host)) ?? .null, (try? JSONValue.fromEncodable(given.host)) ?? .null)
                    guard !changed.isEmpty else {
                        return .object(["status": .string("unchanged"), "changed": .bool(false), "host": .string(id),
                                        "recipe_version": .int(Int64(saved.recipeVersion)), "detail": .string("That is the recipe as it is. Nothing was written.")])
                    }
                    try commit(&saved, host: given.host, source: "written", file: file, previous: previous)
                    state.recipes[index] = saved
                    var receipt: [String: JSONValue] = ["status": .string("written"), "changed": .bool(true), "host": .string(id),
                        "recipe_version": .int(Int64(saved.recipeVersion)), "host_digest": .string(try saved.hostDigest),
                        "fields_changed": .array(changed.map(JSONValue.string)),
                        "path": .string(file.path), "previous": .string(previous.path),
                        "detail": .string((restored.map { "Restored \(saved.host.displayName)'s recipe version \($0) as version \(saved.recipeVersion). " }
                            ?? "\(saved.host.displayName)'s recipe is version \(saved.recipeVersion) now. ")
                            + "One call undoes it: app {action: undo}. A contact reached by it reads Unverified since the recipe changed until its next message proves it.")]
                    if let restored { receipt["restored_version"] = .int(Int64(restored)) }
                    return .object(receipt)
                }
            } catch { return writeFailed(file: file, previous: previous, error: error) }
        }
    }

    /// What a dry run learned (`AgentContactHealth.repair`), written as `write`
    /// writes (version bumped, the replaced one kept for undo) under source
    /// "learned". Only over the recipe the run started from: it throws, saying
    /// why, when that changed since (her write wins) or could not be written.
    public static func learn(_ started: Recipe, host: AgentHostRow) throws -> Recipe {
        try withLoaded { state -> Result<Recipe, ShapeError> in
            let file = folder(state.root).appendingPathComponent(started.host.id + ".json")
            let previous = folder(state.root).appendingPathComponent(started.host.id + ".previous.json")
            let moved = ShapeError(description: "\(file.path) changed since the dry run read it; read it again with agent.recipe")
            guard let index = state.recipes.firstIndex(of: started) else { return .failure(moved) }
            do {
                return try CredentialFileLock.withLock(file) {
                    guard try validated(file: file) == started else { return .failure(moved) }
                    var saved = started
                    try commit(&saved, host: host, source: "learned", file: file, previous: previous)
                    state.recipes[index] = saved
                    return .success(saved)
                }
            } catch { return .failure(ShapeError(description: "Recipe save failed: \(error.localizedDescription). \(file.path) or \(previous.path) may have changed; inspect both files on disk before another write.")) }
        }.get()
    }

    /// The next version: the file it replaces kept as <id>.previous.json.
    private static func commit(_ saved: inout Recipe, host: AgentHostRow, source: String, file: URL, previous: URL) throws {
        let next = saved.recipeVersion.addingReportingOverflow(1)
        guard saved.recipeVersion > 0, !next.overflow else {
            throw ShapeError(description: "Recipe version cannot be incremented; preserve and repair \(file.path) before writing")
        }
        if source != "re-seeded" {
            saved.authoredFields = Array(Set(saved.authoredFields ?? []).union(JSONValue.differences(
                try JSONValue.fromEncodable(saved.host), try JSONValue.fromEncodable(host)))).sorted()
        }
        saved.host = host
        saved.recipeVersion = next.partialValue
        saved.updatedAt = ISO8601DateFormatter().string(from: Date())
        saved.source = source
        saved.digest = try saved.hostDigest
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(contentsOf: file), to: previous)
        try write(saved, to: file)
    }

    private static func refused(_ reason: String, _ detail: String) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string(reason), "changed": .bool(false), "detail": .string(detail + " Nothing was written.")])
    }

    private static func writeFailed(file: URL, previous: URL?, error: Error) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string("write_failed"), "changed": .null,
            "effects": .string("unknown"), "path": .string(file.path), "previous": previous.map { .string($0.path) } ?? .null,
            "detail": .string("Recipe save failed: \(error.localizedDescription). The recipe\(previous == nil ? "" : " or its previous-version backup") may have changed."),
            "remedy": Repair.reconcile(instruction: "Inspect the recipe and any previous-version file on disk before another write; ask the person to resolve the reported storage failure, preserving every version.",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("files.read"),
                    "args": .object(["path": .string(file.path)])])]))])
    }

    private static func unknown(_ host: String, _ state: Loaded) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string("unknown_host"), "changed": .bool(false),
                 "detail": .string(state.problems[AgentHostDirectory.normalize(host)] ?? "No recipe for \(host). agent.recipe with no host lists them.")])
    }

    /// The one shape check, for a file read and a write alike.
    private static func validated(_ document: JSONValue) throws -> Recipe {
        try document.validate(schema: writeArgumentSchema)
        let recipe = try document.decodedExactly(as: Recipe.self)
        guard recipe.recipeVersion > 0, recipe.recipeVersion < Int.max else {
            throw ShapeError(description: "recipeVersion must be positive and leave room for the next version; existing bytes were preserved")
        }
        if AgentHostDirectory.seed.contains(where: { $0.id == recipe.host.id }),
           recipe.seedHost == nil || recipe.authoredFields == nil {
            throw ShapeError(description: "Seeded hosts require explicit seedHost and authoredFields; preserve and repair missing provenance from retained evidence")
        }
        _ = try recipe.hostDigest
        return recipe
    }

    private typealias ShapeError = JSONValue.ShapeError

    /// A recipe file, through the one shape check.
    private static func validated(file: URL) throws -> Recipe {
        let document = try JSONValue.parse(Data(contentsOf: file))
        return try validated(document)
    }

    private static func withLoaded<T: Sendable>(dataRoot: URL? = nil, _ body: @Sendable (inout Loaded) -> T) -> T {
        catalog.withLock { catalog in
            // A synchronous read and every write share this lock; each consumer
            // receives its own copy. The retained read serves only while every
            // recipe file still has the identity it was read at.
            let root = catalog.root ?? dataRoot ?? PersistenceCore.defaultDataRoot()
            let before = stamps(folder(root))
            var current: Loaded
            if let read = catalog.read, read.root == root, let before, before == catalog.stamps {
                current = read
            } else {
                current = scan(root, seedMissing: catalog.root == nil)
                // A file that moved during the scan leaves nothing retained.
                let after = stamps(folder(root))
                catalog = Catalog(root: current.root, stamps: after ?? [:], read: after != nil && after == before ? current : nil)
            }
            catalog.root = current.root
            return body(&current)
        }
    }

    /// The stat identity of the recipe folder and every recipe file in it;
    /// nil when any of them cannot be inspected.
    private static func stamps(_ folder: URL) -> [String: SnapshotTailOpLog.FileStamp]? {
        guard let own = SnapshotTailOpLog.fileStamp(folder) else { return nil }
        var stamps = ["": own]
        guard case .present = own else { return stamps }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let stamp = SnapshotTailOpLog.fileStamp(folder.appendingPathComponent(name)) else { return nil }
            stamps[name] = stamp
        }
        return stamps
    }

    private static func folder(_ root: URL) -> URL { root.appendingPathComponent("agents/recipes", isDirectory: true) }

    private static func scan(_ root: URL, a2a peers: [AgentPeerContact] = [], seedMissing: Bool = true) -> Loaded {
        let folder = folder(root)
        let order = AgentHostDirectory.seed.map(\.id)
        let build = NativeAgentBuildIdentity.current
        var hosts = AgentHostDirectory.seed + peers.map(AgentHostDirectory.seed)
        var seedProblems: [String: String] = [:]
        do {
            guard let file = Bundle.module.url(forResource: "grok-routine", withExtension: "json") else {
                throw ShapeError(description: "The bundled grok-routine.json seed is missing; tell the person this copy of NativeAgent is missing its Grok navigation seed")
            }
            let routine = try JSONValue.parse(Data(contentsOf: file)).decodedExactly(as: AgentHostRow.GrokRoutine.self)
            if let index = hosts.firstIndex(where: { $0.id == "grok-bot" }) { hosts[index].grokRoutine = routine }
        } catch {
            seedProblems["grok-bot"] = "Grok Bot's navigation seed could not be read: \(error.localizedDescription)"
            // Do not seed a missing/invalid shipped recipe over her saved one.
            hosts.removeAll { $0.id == "grok-bot" }
        }
        if seedMissing {
            for host in hosts { seed(host, in: folder, from: "\(build.version) (\(build.build))") }
        }
        var recipes: [Recipe] = [], problems = seedProblems
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) }
        catch {
            let words = "Agent recipe catalog could not be enumerated at \(folder.path): \(error.localizedDescription). Repair access and reload the catalog."
            problems["catalog"] = words
            owe(root, id: "catalog", file: folder, words: words, recipe: nil)
            return Loaded(root: root, recipes: [], problems: problems)
        }
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            // <id>.previous.json is the version a write replaced, kept for undo.
            guard validID(id) else { continue }
            let why: String
            do {
                let path = folder.appendingPathComponent(name)
                let recipe = try CredentialFileLock.withLock(path) { try validated(file: path) }
                if recipe.host.id == id { recipes.append(recipe); continue }
                why = "host.id is not \(id)"
            } catch { why = "\(error)" }
            problems[id] = "agents/recipes/\(name) doesn't read as a recipe: \(why). Write its whole recipe with "
                + "agent.recipe_write, which keeps this file as \(id).previous.json; until then this app doesn't know \(id)."
            owe(root, id: id, file: folder.appendingPathComponent(name), words: problems[id]!,
                recipe: hosts.first { $0.id == id })
        }
        // The table's order first, as `AgentHostDirectory.row(named:)` always matched.
        recipes.sort { (order.firstIndex(of: $0.host.id) ?? order.count, $0.host.id) < (order.firstIndex(of: $1.host.id) ?? order.count, $1.host.id) }
        return Loaded(root: root, recipes: recipes, problems: problems)
    }

    private static func seed(_ host: AgentHostRow, in folder: URL, from build: String) {
        let file = folder.appendingPathComponent(host.id + ".json")
        var fresh = Recipe(recipeVersion: 1, seededFrom: build, updatedAt: ISO8601DateFormatter().string(from: Date()),
                           source: "seeded", digest: "", host: host, seedHost: host, authoredFields: [])
        do {
            fresh.digest = try fresh.hostDigest
            try CredentialFileLock.withLock(file) {
                if FileManager.default.fileExists(atPath: file.path) {
                    var saved = try validated(file: file)
                    let previous = folder.appendingPathComponent(host.id + ".previous.json")
                    guard let baseline = saved.seedHost, let authoredFields = saved.authoredFields else {
                        throw ShapeError(description: "Seed provenance (seedHost and authoredFields) is missing; preserve this authored recipe and repair its provenance from retained evidence before seed merging")
                    }
                    let before = try JSONValue.fromEncodable(saved.host)
                    let authored = Set(authoredFields).union(JSONValue.differences(try JSONValue.fromEncodable(baseline), before))
                    let merged = try merging(before, seed: JSONValue.fromEncodable(host), authored: authored).decodedExactly(as: AgentHostRow.self)
                    guard saved.seedHost != host || saved.authoredFields != authored.sorted() || saved.host != merged else { return }
                    saved.seedHost = host
                    saved.seededFrom = build
                    saved.authoredFields = authored.sorted()
                    if saved.host != merged {
                        try commit(&saved, host: merged, source: "re-seeded", file: file, previous: previous)
                    } else { try write(saved, to: file) }
                    return
                }
                try write(fresh, to: file)
            }
        } catch {
            owe(folder.deletingLastPathComponent().deletingLastPathComponent(), id: host.id, file: file,
                words: "\(file.path) could not be seeded: \(error.localizedDescription)", recipe: host)
        }
    }

    /// Objects merge by field; an authored value (including an array or deletion) stays whole.
    private static func merging(_ current: JSONValue, seed: JSONValue, authored: Set<String>, path: String = "") -> JSONValue {
        if authored.contains(path) { return current }
        guard case .object(let before) = current, case .object(let after) = seed else {
            return authored.contains(where: { $0.hasPrefix(path + ".") }) ? current : seed
        }
        return .object(Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).compactMap { key in
            let value = merging(before[key] ?? .null, seed: after[key] ?? .null, authored: authored,
                path: path.isEmpty ? key : path + "." + key)
            return value == .null ? nil : (key, value)
        }))
    }

    /// A recipe file that stays wrong until it is written: owed until a write of
    /// that host's recipe works. A seeded host's call carries its seed; any other
    /// recipe is read first, corrected, and written whole.
    private static func owe(_ root: URL, id: String, file: URL, words: String, recipe host: AgentHostRow?) {
        var call = ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(file.path)])])
        if let host {
            var seeded = Recipe(recipeVersion: 1, seededFrom: "seed", updatedAt: "", source: "seeded", digest: "", host: host, seedHost: host, authoredFields: [])
            do {
                seeded.digest = try seeded.hostDigest
                call = ToolFailureError.call("app", ["action": .string("agent.recipe_write"),
                    "args": .object(["host": .string(id), "recipe": try JSONValue.fromEncodable(seeded)])])
            } catch { nativeLog("AgentRecipeStore: %@ has no valid repair seed identity: %@", id, error.localizedDescription) }
        }
        RepairOwed.owe(root, id: "agent-recipe:" + UUID().uuidString.lowercased(), kind: .act,
            operation: "agent.recipe:" + id, owner: file.path,
            words: words + (host == nil ? " Read it, then pass the whole corrected recipe to agent.recipe_write {host: \"\(id)\", recipe}." : ""),
            lever: "agent.recipe_write", nextCall: call)
    }

    private static func write(_ recipe: Recipe, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(recipe), to: file)
        RepairOwed.settle(file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            operation: "agent.recipe:" + recipe.host.id, evidence: .init(source: file.path, id: recipe.digest))
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}
