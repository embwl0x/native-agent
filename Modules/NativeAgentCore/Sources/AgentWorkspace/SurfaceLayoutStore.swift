import Darwin
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import os
import PersistenceCore

/// HOW THE APP LAYS OUT ITS SURFACES, as one file she can read and rewrite:
/// ui/layout.json (`SurfaceLayout`). The window's views, her home and the
/// door's page index draw from it; the Swift vocabulary is only the seed. A
/// missing file is seeded at version 1; a present one is never overwritten by
/// a seed, so her edits win; one still exactly as a seed wrote it takes this
/// build's seed when that changed. A block a newer build adds lands at its
/// seed position. Cloned from `AgentRecipeStore`; every call names the
/// host's data root, and what is cached is that root's.
public enum SurfaceLayoutStore {
    private struct Loaded: Sendable {
        var root: URL
        /// The file as last validated: what the window draws.
        var layout: SurfaceLayout
        /// The file's identity when `layout` was read; a change re-reads it.
        var stamp: String
        /// Why the file doesn't read as a layout and how to fix it; nil when it does.
        var problem: String?
    }

    /// By data root: a test copy or presentation host never reads or seeds another's.
    private static let loaded = OSAllocatedUnfairLock<[String: Loaded]>(initialState: [:])

    /// The layout the window draws, re-read when the file changed.
    public static func layout(dataRoot: URL) -> SurfaceLayout { withLoaded(dataRoot) { $0.layout } }

    /// The profile the window shows (`nativeagent.viewMode`); nil before a window set it.
    public static var profile: String? { UserDefaults.standard.string(forKey: "nativeagent.viewMode") }

    /// `layout.read`: the layout, the version a write must carry, the one a
    /// write replaced, and what every surface and block is.
    public static func read(dataRoot: URL) -> JSONValue {
        withLoaded(dataRoot) { state in
            var result: [String: JSONValue] = [
                "status": .string("ok"), "layout": (try? JSONValue.fromEncodable(state.layout)) ?? .null,
                "version": .string(version(state.layout)), "showing": profile.map(JSONValue.string) ?? .null,
                "path": .string(file(state.root).path), "profiles": .string(SurfaceLayout.profilesAbout),
                "blocks": .object(Dictionary(uniqueKeysWithValues: SurfaceLayout.vocabulary.map { surface, about, blocks in
                    (surface, .string(about + ". Blocks: " + blocks.map { $0.shows.isEmpty ? $0.name : "\($0.name) (\($0.shows))" }.joined(separator: ", ")))
                })),
            ]
            if let previous = try? JSONValue.parse(Data(contentsOf: previous(state.root))) { result["previous"] = previous }
            if let problem = state.problem { result["problem"] = .string(problem) }
            return .object(result)
        }
    }

    /// `layout.write`: the layout as read, edited, or only the parts it
    /// changes (a surface's whole block list, a profile, phone); the rest
    /// stays. Every field it names is one the shape has, at the version it
    /// was read, which a hand edit since moves as a write does. The write
    /// bumps layoutVersion and keeps the replaced file as
    /// layout.previous.json; writing that back, at whatever version, undoes it.
    public static func write(_ document: JSONValue, expectedVersion: String, dataRoot: URL) -> JSONValue {
        guard case .object(let parts) = document else {
            return refused("invalid_layout", "layout is an object: layout.read's layout, or only the surfaces, profiles or phone it changes.")
        }
        return withLoaded(dataRoot) { state in
            let file = file(state.root)
            do {
                return try CredentialFileLock.withLock(file) {
                    refresh(&state)
                    // A file that does not read is fixed by hand, never written over.
                    if let problem = state.problem { return refused("invalid_file", problem) }
                    guard case .object(var merged)? = try? JSONValue.fromEncodable(state.layout) else { return refused("write_failed", "The layout could not be read.") }
                    for (key, value) in parts {
                        if case .object(let named) = value, case .object(var current)? = merged[key] {
                            current.merge(named) { $1 }
                            merged[key] = .object(current)
                        } else { merged[key] = value }
                    }
                    let given: SurfaceLayout
                    do { given = try validated(.object(merged)) }
                    catch { return refused("invalid_layout", "layout doesn't match a layout's shape: \(error). Start from layout.read's layout and change only what you mean to.") }
                    // Undo: the version a write replaced goes back whatever version it carries.
                    let restored = (try? validated(file: previous(state.root))).flatMap { content($0) == content(given) ? $0.layoutVersion : nil }
                    guard restored != nil || expectedVersion == version(state.layout) else {
                        return refused("stale_layout", "That layout was read at version \(expectedVersion.isEmpty ? "(none given)" : expectedVersion); it is at \(version(state.layout)) now, by a write or a hand edit. Read it again with layout.read.")
                    }
                    let changed = JSONValue.differences(content(state.layout), content(given))
                    guard !changed.isEmpty else {
                        return .object(["status": .string("unchanged"), "changed": .bool(false), "version": .string(version(state.layout)),
                                        "detail": .string("That is the layout as it is. Nothing was written.")])
                    }
                    let saved = try commit(given, over: &state, source: "her")
                    var receipt: [String: JSONValue] = ["status": .string("written"), "changed": .bool(true),
                        "layout_version": .int(Int64(saved.layoutVersion)), "version": .string(version(saved)),
                        "fields_changed": .array(changed.map(JSONValue.string)), "path": .string(file.path),
                        "previous": .string(previous(state.root).path),
                        "detail": .string((restored.map { "Restored layout version \($0) as version \(saved.layoutVersion). " }
                            ?? "The layout is version \(saved.layoutVersion) now. ")
                            + "The window shows it now. Writing the previous one back with layout.write undoes it.")]
                    if let restored { receipt["restored_version"] = .int(Int64(restored)) }
                    return .object(receipt)
                }
            } catch { return refused("write_failed", "\(file.path) could not be written: \(error.localizedDescription).") }
        }
    }

    /// The person opened or closed a fold: written as a write is (version
    /// bumped, the replaced one kept), under source "person".
    public static func setExpanded(_ open: Bool, surface: String, block: String, dataRoot: URL) {
        withLoaded(dataRoot) { state in
            let file = file(state.root)
            do {
                try CredentialFileLock.withLock(file) {
                    refresh(&state)
                    guard state.problem == nil, var blocks = state.layout.surfaces[surface],
                          let index = blocks.firstIndex(where: { $0.name == block }), blocks[index].expanded != nil,
                          blocks[index].expanded != open else { return }
                    blocks[index].expanded = open
                    var next = state.layout
                    next.surfaces[surface] = blocks
                    _ = try commit(next, over: &state, source: "person")
                }
            } catch { nativeLog("SurfaceLayoutStore: %@ could not be written: %@", file.path, error.localizedDescription) }
        }
    }

    /// The next version: the file it replaces kept as layout.previous.json.
    private static func commit(_ next: SurfaceLayout, over state: inout Loaded, source: String) throws -> SurfaceLayout {
        var saved = next
        saved.layoutVersion = state.layout.layoutVersion + 1
        saved.seededFrom = state.layout.seededFrom
        saved.updatedAt = ISO8601DateFormatter().string(from: Date())
        saved.source = source
        saved.digest = content(saved).digest
        let file = file(state.root)
        if let replaced = try? Data(contentsOf: file) { try SwiftNativePersistenceCore.writeDataAtomicDurable(replaced, to: previous(state.root)) }
        try write(saved, to: file)
        state.layout = saved
        state.stamp = stamp(file)
        state.problem = nil
        return saved
    }

    private static func refused(_ reason: String, _ detail: String) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string(reason), "changed": .bool(false), "detail": .string(detail + " Nothing was written.")])
    }

    /// The shape check, then the vocabulary: every surface, block and profile
    /// one this build knows, each block once, `expanded` exactly on a fold.
    private static func validated(_ document: JSONValue) throws -> SurfaceLayout {
        var layout = try document.decodedExactly(as: SurfaceLayout.self)
        let known = Dictionary(uniqueKeysWithValues: SurfaceLayout.vocabulary.map { ($0.surface, $0.blocks.map(\.name)) })
        func shape(_ text: String) -> JSONValue.ShapeError { JSONValue.ShapeError(description: text) }
        for (surface, blocks) in layout.surfaces.sorted(by: { $0.key < $1.key }) {
            guard let names = known[surface] else {
                throw shape("surfaces.\(surface) is not a surface; they are \(known.keys.sorted().joined(separator: ", "))")
            }
            var seen = Set<String>()
            for (index, block) in blocks.enumerated() {
                let at = "surfaces.\(surface)[\(index)]"
                guard names.contains(block.name) else { throw shape("\(at).name \"\(block.name)\" is not a \(surface) block; they are \(names.joined(separator: ", "))") }
                guard seen.insert(block.name).inserted else { throw shape("\(at).name \"\(block.name)\" is listed twice") }
                let folds = SurfaceLayout.folds.contains(surface + "." + block.name)
                guard (block.expanded != nil) == folds else {
                    throw shape(folds ? "\(at).expanded is missing" : "\(at).expanded is only on a block that folds: \(SurfaceLayout.folds.sorted().joined(separator: ", "))")
                }
            }
        }
        let profiles = SurfaceLayout.seed(from: "", at: "").profiles.keys
        let blocks = Set(known.flatMap { surface, names in names.map { surface + "." + $0 } })
        for (name, profile) in layout.profiles.sorted(by: { $0.key < $1.key }) {
            guard profiles.contains(name) else { throw shape("profiles.\(name) is not a profile; they are \(profiles.sorted().joined(separator: ", "))") }
            for (index, hidden) in profile.hidden.enumerated() where !blocks.contains(hidden) {
                throw shape("profiles.\(name).hidden[\(index)] \"\(hidden)\" names no surface.block")
            }
        }
        guard profiles.contains(layout.phone) else { throw shape("phone \"\(layout.phone)\" is not a profile") }
        layout.addMissing()
        return layout
    }

    private static func validated(file: URL) throws -> SurfaceLayout {
        let document: JSONValue
        do { document = try JSONValue.parse(Data(contentsOf: file)) } catch { throw JSONValue.ShapeError(description: "not JSON") }
        return try validated(document)
    }

    /// What the person sees, without who wrote it when: what a version and the digest cover.
    private static func content(_ layout: SurfaceLayout) -> JSONValue {
        var bare = layout
        (bare.layoutVersion, bare.seededFrom, bare.updatedAt, bare.source, bare.digest) = (0, "", "", "", "")
        return (try? JSONValue.fromEncodable(bare)) ?? .null
    }

    /// The version a write must carry: the layout version and what it shows,
    /// so a hand edit, which bumps nothing, still moves it.
    private static func version(_ layout: SurfaceLayout) -> String { "\(layout.layoutVersion)@" + content(layout).digest }

    private static func withLoaded<T: Sendable>(_ root: URL, _ body: @Sendable (inout Loaded) -> T) -> T {
        let key = root.standardizedFileURL.path
        return loaded.withLock { states in
            var current = states[key] ?? scan(root)
            refresh(&current)
            defer { states[key] = current }
            return body(&current)
        }
    }

    public static func file(_ root: URL) -> URL { root.appendingPathComponent(SurfaceLayout.path) }

    private static func previous(_ root: URL) -> URL { root.appendingPathComponent("ui/layout.previous.json") }

    /// Re-read the file when it changed since `layout` was read. One that no
    /// longer reads leaves the window as it was and says why.
    private static func refresh(_ state: inout Loaded) {
        let file = file(state.root)
        let now = stamp(file)
        guard now != state.stamp else { return }
        state.stamp = now
        do {
            state.layout = try validated(file: file)
            state.problem = nil
        } catch {
            state.problem = "\(SurfaceLayout.path) doesn't read as a layout: \(error). Fix the file, or delete it and relaunch to seed it again; "
                + "until then the window keeps the layout it last read and layout.write is refused."
            nativeLog("SurfaceLayoutStore: %@", state.problem ?? "")
        }
    }

    private static func scan(_ root: URL) -> Loaded {
        let build = NativeAgentBuildIdentity.current
        seed(file(root), from: "\(build.version) (\(build.build))")
        var state = Loaded(root: root, layout: SurfaceLayout.seed(from: "", at: ""), stamp: "", problem: nil)
        refresh(&state)
        return state
    }

    private static func seed(_ file: URL, from build: String) {
        // The Helpers rail switch this file replaced (`uiBotsShelfPreview`), as it was left.
        let helpersOff = UserDefaults.standard.object(forKey: "uiBotsShelfPreview") as? Bool == false
        var fresh = SurfaceLayout.seed(from: build, at: ISO8601DateFormatter().string(from: Date()), hidden: helpersOff ? ["rail.bots"] : [])
        fresh.digest = content(fresh).digest
        do {
            try CredentialFileLock.withLock(file) {
                if FileManager.default.fileExists(atPath: file.path) {
                    guard let data = try? Data(contentsOf: file), let saved = try? JSONValue.parse(data).decodedExactly(as: SurfaceLayout.self),
                          saved.layoutVersion == 1, saved.source == "seed",
                          saved.digest == content(saved).digest, saved.digest != fresh.digest else { return }
                }
                try write(fresh, to: file)
            }
        } catch { nativeLog("SurfaceLayoutStore: could not seed %@: %@", file.path, error.localizedDescription) }
    }

    private static func write(_ layout: SurfaceLayout, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(layout), to: file)
    }

    /// The file's identity, size and times; any change re-reads it.
    private static func stamp(_ file: URL) -> String {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return "-" }
        return "\(info.st_ino) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
}

/// The layout the window draws, re-read when ui/layout.json changes on disk
/// (the `SimpleViewStore.watch` shape): her write, the person's fold or a
/// hand edit re-renders every surface at once.
@MainActor @Observable
public final class SurfaceLayoutLive {
    public static let shared = SurfaceLayoutLive()
    public private(set) var layout = SurfaceLayout.seed(from: "", at: "")
    /// The host's data root, as the app resolved it (`attach`).
    private var root: URL?

    private init() {}

    /// At launch, before a window draws: the host's root and its layout.
    public func attach(dataRoot: URL) {
        root = dataRoot
        layout = SurfaceLayoutStore.layout(dataRoot: dataRoot)
    }

    /// The window's one watch, for as long as it is up (`ContentView`).
    public func watch() async {
        guard let root else { return }
        let events = FileChangeEvents(paths: [SurfaceLayoutStore.file(root)], emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                let next = await Task.detached { SurfaceLayoutStore.layout(dataRoot: root) }.value
                if next != layout { layout = next }
            }
        } onCancel: { events.cancel() }
    }
}
