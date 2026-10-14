import Foundation
import NativeAgentCore
import os
import PersistenceCore

/// HOW THIS APP REACHES EACH AGENT, as files she can read and fix.
///
/// One recipe per agent host under agents/recipes/<host-id>.json: the row
/// every connect, send and health check reads (`AgentHostDirectory.rows`),
/// with its launch line, search paths and window labels; and one per A2A
/// contact under its id, its card. The Swift tables are only the seed. A
/// missing file is seeded at version 1; a present one is never overwritten
/// by a seed, so her edits win; one still exactly as a seed wrote it at
/// version 1 takes this build's table when that changed, so our own fixes
/// still land. A host no table knows loads from its file alone.
public enum AgentRecipeStore {
    public struct Recipe: Codable, Sendable, Equatable {
        /// 1 as seeded; each `write` bumps it. A hand edit bumps nothing.
        public var recipeVersion: Int
        /// The app build whose table this recipe was seeded from.
        public var seededFrom: String
        public var updatedAt: String
        /// What wrote this version: "seeded", "re-seeded" (the table changed
        /// while the file was still its seed), "written" (`write`) or
        /// "learned" (`learn`, a dry run).
        public var source: String
        /// `host`'s digest as this app last wrote it; a hand edit leaves it behind.
        public var digest: String
        public var host: AgentHostRow

        /// What a round trip's proof records, so any later change reads as one.
        public var hostDigest: String { ((try? JSONValue.fromEncodable(host)) ?? .null).digest }
    }

    private struct Loaded: Sendable {
        var root: URL
        var recipes: [Recipe]
        /// Files that did not read as a recipe, by host id: what is wrong and how to fix it.
        var problems: [String: String]
    }

    private static let loaded = OSAllocatedUnfairLock<Loaded?>(initialState: nil)

    /// Bound from `agent_message`'s `dry_run` input: the contact runs its recipe
    /// dry. An ACP send stops after its handshake, a desktop chat finds its
    /// controls without typing, a command line checks its executable and args, an
    /// A2A send stops after its card, auth and one task listing; nothing she
    /// wrote goes out and no other route runs.
    @TaskLocal package static var dryRun = false

    /// Every host's recipe, the process data root's loaded on first use.
    public static var recipes: [Recipe] { withLoaded { $0.recipes } }

    public static var rows: [AgentHostRow] { recipes.map(\.host) }

    public static func recipe(_ id: String) -> Recipe? { withLoaded { $0.recipes.first { $0.host.id == id } } }

    /// An A2A contact's recipe. A missing file is seeded now
    /// (`AgentHostDirectory.seed`); one that is there and does not read as a
    /// recipe throws, saying what does not read.
    public static func recipe(for peer: AgentPeerContact) throws -> Recipe {
        try withLoaded { state -> Result<Recipe, ShapeError> in
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
    public static func launch(_ id: String) -> AgentHostLaunches.Launch {
        recipe(id).map { ($0.host.acp, $0.host.commandLine) } ?? (nil, nil)
    }

    /// At launch: seed what is missing (or still an older seed), then read every recipe.
    public static func load(dataRoot: URL) {
        // Listed outside the lock: reading contacts reads host recipes.
        let peers = ((try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []).filter { $0.transport == .a2a }
        loaded.withLock { $0 = scan(dataRoot, a2a: peers) }
    }

    /// `agent.recipe`: one host's recipe with the version a write replaced, or every host's.
    public static func read(host: String?) -> JSONValue {
        withLoaded { state in
            let folder = folder(state.root)
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

    /// `agent.recipe_write`: one host's whole recipe, replaced. The document is
    /// the recipe as read, edited: every field the shape has and none it
    /// lacks, at the version it was read. The write bumps that version and
    /// keeps the replaced file as <id>.previous.json; writing that back, at
    /// whatever version it carries, undoes it.
    public static func write(host: String, document: JSONValue, undoing receipt: JSONValue? = nil) -> JSONValue {
        let given: Recipe
        do { given = try validated(document) }
        catch { return refused("invalid_recipe", "recipe doesn't match a recipe's shape: \(error). Start from agent.recipe's recipe and change only what you mean to.") }
        return withLoaded { state in
            guard let id = AgentHostDirectory.named(host, in: state.recipes, \.host)?.host.id,
                  let index = state.recipes.firstIndex(where: { $0.host.id == id }) else { return unknown(host, state) }
            let file = folder(state.root).appendingPathComponent(id + ".json")
            let previous = folder(state.root).appendingPathComponent(id + ".previous.json")
            do {
                // Read, compare, keep the previous and write under the file's lock.
                return try CredentialFileLock.withLock(file) {
                    // A hand edit since this app read the file is never written over unseen;
                    // a valid one is what the next read shows.
                    let onDisk = try? validated(file: file)
                    guard onDisk == state.recipes[index] else {
                        if let onDisk, onDisk.host.id == id { state.recipes[index] = onDisk }
                        return refused("stale_recipe", "\(file.path) changed since this app read it; relaunch or read it again.")
                    }
                    var saved = state.recipes[index]
                    if case .object(let receipt) = receipt,
                       receipt["host"] != .string(id) || receipt["recipe_version"] != .int(Int64(saved.recipeVersion))
                        || receipt["host_digest"] != .string(saved.hostDigest) {
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
                        "recipe_version": .int(Int64(saved.recipeVersion)), "host_digest": .string(saved.hostDigest),
                        "fields_changed": .array(changed.map(JSONValue.string)),
                        "path": .string(file.path), "previous": .string(previous.path),
                        "detail": .string((restored.map { "Restored \(saved.host.displayName)'s recipe version \($0) as version \(saved.recipeVersion). " }
                            ?? "\(saved.host.displayName)'s recipe is version \(saved.recipeVersion) now. ")
                            + "One call undoes it: app {action: undo}. A contact reached by it reads Unverified since the recipe changed until its next message proves it.")]
                    if let restored { receipt["restored_version"] = .int(Int64(restored)) }
                    return .object(receipt)
                }
            } catch { return refused("write_failed", "\(file.path) could not be written: \(error.localizedDescription).") }
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
                    guard (try? validated(file: file)) == started else { return .failure(moved) }
                    var saved = started
                    try commit(&saved, host: host, source: "learned", file: file, previous: previous)
                    state.recipes[index] = saved
                    return .success(saved)
                }
            } catch { return .failure(ShapeError(description: "\(file.path) could not be written: \(error.localizedDescription)")) }
        }.get()
    }

    /// The next version: the file it replaces kept as <id>.previous.json.
    private static func commit(_ saved: inout Recipe, host: AgentHostRow, source: String, file: URL, previous: URL) throws {
        saved.host = host
        saved.recipeVersion += 1
        saved.updatedAt = ISO8601DateFormatter().string(from: Date())
        saved.source = source
        saved.digest = saved.hostDigest
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(contentsOf: file), to: previous)
        try write(saved, to: file)
    }

    private static func refused(_ reason: String, _ detail: String) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string(reason), "changed": .bool(false), "detail": .string(detail + " Nothing was written.")])
    }

    private static func unknown(_ host: String, _ state: Loaded) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string("unknown_host"), "changed": .bool(false),
                 "detail": .string(state.problems[AgentHostDirectory.normalize(host)] ?? "No recipe for \(host). agent.recipe with no host lists them.")])
    }

    /// The one shape check, for a file read and a write alike.
    private static func validated(_ document: JSONValue) throws -> Recipe { try document.decodedExactly(as: Recipe.self) }

    private typealias ShapeError = JSONValue.ShapeError

    /// A recipe file, through the one shape check.
    private static func validated(file: URL) throws -> Recipe {
        let document: JSONValue
        do { document = try JSONValue.parse(Data(contentsOf: file)) } catch { throw ShapeError(description: "not JSON") }
        return try validated(document)
    }

    private static func withLoaded<T: Sendable>(_ body: @Sendable (inout Loaded) -> T) -> T {
        loaded.withLock { state in
            var current = state ?? scan(PersistenceCore.defaultDataRoot())
            defer { state = current }
            return body(&current)
        }
    }

    private static func folder(_ root: URL) -> URL { root.appendingPathComponent("agents/recipes", isDirectory: true) }

    private static func scan(_ root: URL, a2a peers: [AgentPeerContact] = []) -> Loaded {
        let folder = folder(root)
        let order = AgentHostDirectory.seed.map(\.id)
        let build = NativeAgentBuildIdentity.current
        for host in AgentHostDirectory.seed + peers.map(AgentHostDirectory.seed) {
            seed(host, in: folder, from: "\(build.version) (\(build.build))")
        }
        var recipes: [Recipe] = [], problems: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            // <id>.previous.json is the version a write replaced, kept for undo.
            guard validID(id) else { continue }
            let why: String
            do {
                let recipe = try validated(file: folder.appendingPathComponent(name))
                if recipe.host.id == id { recipes.append(recipe); continue }
                why = "host.id is not \(id)"
            } catch { why = "\(error)" }
            problems[id] = "agents/recipes/\(name) doesn't read as a recipe: \(why). Fix the file, or delete it and "
                + "relaunch to seed it again; until then this app doesn't know \(id)."
            nativeLog("AgentRecipeStore: %@", problems[id] ?? "")
        }
        // The table's order first, as `AgentHostDirectory.row(named:)` always matched.
        recipes.sort { (order.firstIndex(of: $0.host.id) ?? order.count, $0.host.id) < (order.firstIndex(of: $1.host.id) ?? order.count, $1.host.id) }
        return Loaded(root: root, recipes: recipes, problems: problems)
    }

    private static func seed(_ host: AgentHostRow, in folder: URL, from build: String) {
        let file = folder.appendingPathComponent(host.id + ".json")
        var fresh = Recipe(recipeVersion: 1, seededFrom: build, updatedAt: ISO8601DateFormatter().string(from: Date()),
                           source: "seeded", digest: "", host: host)
        fresh.digest = fresh.hostDigest
        do {
            try CredentialFileLock.withLock(file) {
                if FileManager.default.fileExists(atPath: file.path) {
                    guard let data = try? Data(contentsOf: file), case .object(let saved)? = try? JSONValue.parse(data),
                          saved["recipeVersion"] == .int(1), let written = saved["host"],
                          saved["digest"] == .string(written.digest), written.digest != fresh.digest else { return }
                    fresh.source = "re-seeded"
                }
                try write(fresh, to: file)
            }
        } catch { nativeLog("AgentRecipeStore: could not seed %@: %@", host.id, error.localizedDescription) }
    }

    private static func write(_ recipe: Recipe, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(recipe), to: file)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}
