import Darwin
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import os
import PersistenceCore
// Blueprint: | `SurfaceLayoutStore.swift` | Root-scoped layout store and `SurfaceLayoutLive`; the engine's one observed layout feeds Mac, DeviceSync, quiet Today, page index and live tour stops. `read`/`write` validate one shape/version and preserve replaced bytes; chat fold writes route through `setSurfaceExpanded`. Snapshot reads publish through `LatestRead`; PrivacyMap inventories the whole ui directory, including the previous revision. |

/// HOW THE APP LAYS OUT ITS SURFACES, as one file she can read and rewrite:
/// ui/layout.json (`SurfaceLayout`). The window's views, her home and the
/// door's page index draw from it; the Swift vocabulary is only the seed. A
/// missing file is seeded at version 1; a present one is never overwritten by
/// a seed, so her edits win; one still exactly as a seed wrote it takes this
/// build's seed when that changed. A block a newer build adds lands at its
/// seed position. Cloned from `AgentRecipeStore`; every call names the
/// host's data root, and what is cached is that root's.
/// Current/previous layouts: off-disk backup only; phone projects the current ui_layout.json. PrivacyMap lists ui/.
public enum SurfaceLayoutStore {
    private struct Loaded: Sendable {
        var root: URL
        /// The file as last validated: what the window draws.
        var layout: SurfaceLayout
        /// The file's identity when `layout` was read; a change re-reads it.
        var stamp: String
        /// Why the file doesn't read as a layout and how to fix it; nil when it does.
        var problem: String?
        var hasValidatedFile = false
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
            result["layout_source"] = .string(state.hasValidatedFile ? "validated_file" : "seed_in_memory")
            if let problem = state.problem {
                result.merge(invalidFile(state, detail: problem).objectValue ?? [:]) { _, failure in failure }
            }
            return .object(result)
        }
    }

    /// `layout.write`: the layout as read, edited, or only the parts it
    /// changes (a surface's whole block list, a profile, phone); the rest
    /// stays. Every field it names is one the shape has, at the version it
    /// was read, which a hand edit since moves as a write does. The write
    /// bumps layoutVersion and keeps the replaced file as
    /// layout.previous.json; writing that back, at whatever version, undoes it.
    public static func write(_ document: JSONValue, expectedVersion: String, dataRoot: URL, undoing receipt: JSONValue? = nil) -> JSONValue {
        guard case .object(let parts) = document else {
            return refused("invalid_layout", "layout is an object: layout.read's layout, or only the surfaces, profiles or phone it changes.")
        }
        return withLoaded(dataRoot) { state in
            let file = file(state.root)
            do {
                return try CredentialFileLock.withLock(file) {
                    refresh(&state)
                    // A file that does not read is fixed by hand, never written over.
                    if let problem = state.problem { return invalidFile(state, detail: problem) }
                    if case .object(let receipt) = receipt, receipt["version"] != .string(version(state.layout)) {
                        return refused("stale_layout", "The layout changed after that receipt. Read it again with layout.read.")
                    }
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
                            + "The window shows it now. One call undoes it: app {action: undo}.")]
                    if let restored { receipt["restored_version"] = .int(Int64(restored)) }
                    return .object(receipt)
                }
            } catch {
                let failure = error as? ToolFailureError
                let call = failure?.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                    ?? .object(["tool": .string("app"), "input": .object(["action": .string("layout.read")])])
                return .object(["status": .string(failure?.status.rawValue ?? "failed"),
                    "reason": .string(failure?.code ?? "layout_write_failed"),
                    "detail": .string(failure?.message ?? "\(file.path) could not be written: \(error.localizedDescription)."),
                    "effects": .string(failure?.effects.rawValue ?? "unknown"),
                    "remedy": Repair.reconcile(instruction: failure?.instruction ?? "Read the layout and backup before another write; fix the reported storage error.", nextCall: call)])
            }
        }
    }

    /// The person opened or closed a fold: written as a write is (version
    /// bumped, the replaced one kept), under source "person".
    @discardableResult
    public static func setExpanded(_ open: Bool, surface: String, block: String, dataRoot: URL) -> SurfaceLayout? {
        withLoaded(dataRoot) { state in
            let file = file(state.root)
            do {
                return try CredentialFileLock.withLock(file) {
                    refresh(&state)
                    guard state.problem == nil, var blocks = state.layout.surfaces[surface],
                          let index = blocks.firstIndex(where: { $0.name == block }), blocks[index].expanded != nil,
                          blocks[index].expanded != open else { return nil }
                    blocks[index].expanded = open
                    var next = state.layout
                    next.surfaces[surface] = blocks
                    return try commit(next, over: &state, source: "person")
                }
            } catch { nativeLog("SurfaceLayoutStore: %@ could not be written: %@", file.path, error.localizedDescription) }
            return nil
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
        let replaced: Data
        do { replaced = try Data(contentsOf: file) }
        catch {
            throw ToolFailureError("Cannot read \(file.path) for its backup: \(error.localizedDescription). No write was attempted.",
                effects: .none, nextCall: ToolFailureError.call("app", ["action": .string("layout.read")]),
                code: "layout_backup_read_failed", instruction: "Restore read access to the layout before changing it.", recovery: .reconcile)
        }
        let backup = previous(state.root)
        do { try SwiftNativePersistenceCore.writeDataAtomicDurable(replaced, to: backup) }
        catch {
            throw ToolFailureError("Backup write failed at \(backup.path): \(error.localizedDescription). The backup may have changed; layout replacement was not attempted.",
                effects: .unknown, nextCall: ToolFailureError.call("app", ["action": .string("layout.read")]),
                code: "layout_backup_write_failed", instruction: "Inspect the backup and fix the reported storage error before another write.", recovery: .reconcile)
        }
        do { try write(saved, to: file) }
        catch {
            throw ToolFailureError("The previous layout was saved at \(backup.path); replacing \(file.path) failed: \(error.localizedDescription). The on-disk layout is unverified.",
                effects: .partial, nextCall: ToolFailureError.call("app", ["action": .string("layout.read")]),
                code: "layout_replacement_failed", instruction: "Read the layout and backup before another change; fix the reported storage error.", recovery: .reconcile)
        }
        state.layout = saved
        state.stamp = stamp(file)
        state.problem = nil
        state.hasValidatedFile = true
        return saved
    }

    private static func refused(_ reason: String, _ detail: String) -> JSONValue {
        .object(["status": .string("refused"), "reason": .string(reason), "changed": .bool(false), "effects": .string("none"), "detail": .string(detail),
            "remedy": .object(["kind": .string("correct_arguments"), "instruction": .string("Read the current layout and its shape; correct the requested change."),
                "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("layout.read")])])])])
    }

    private static func invalidFile(_ state: Loaded, detail: String) -> JSONValue {
        let file = file(state.root)
        return .object(["status": .string("failed"), "reason": .string("invalid_file"), "effects": .string("none"), "detail": .string(detail),
            "remedy": Repair.remedy(owner: file.path, nextCall: nil, tap: nil,
                instruction: ToolFailureError.fileRepairInstruction(file,
                    shape: "The file must be a valid SurfaceLayout JSON object; use layout.read's blocks and profiles as the vocabulary.")
                    + " Repair the saved layout while preserving its original bytes; layout.write is blocked until it validates.")])
    }

    /// The shape check, then the vocabulary: every surface, block and profile
    /// one this build knows, each block once, `expanded` exactly on a fold.
    /// A file an older build wrote may name a surface, block or hidden entry
    /// this build no longer has: those are dropped on read (`fromFile`), never
    /// fatal. A write still refuses a name it does not know.
    private static func validated(_ document: JSONValue, fromFile: Bool = false) throws -> SurfaceLayout {
        var layout = try document.decodedExactly(as: SurfaceLayout.self)
        let known = Dictionary(uniqueKeysWithValues: SurfaceLayout.vocabulary.map { ($0.surface, $0.blocks.map(\.name)) })
        if fromFile {
            layout.surfaces = layout.surfaces.filter { known[$0.key] != nil }
            for (surface, blocks) in layout.surfaces { layout.surfaces[surface] = blocks.filter { known[surface]!.contains($0.name) } }
            let named = Set(known.flatMap { surface, names in names.map { surface + "." + $0 } })
            for name in layout.profiles.keys { layout.profiles[name]?.hidden.removeAll { !named.contains($0) } }
        }
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
        let document = try JSONValue.parse(Data(contentsOf: file))
        return try validated(document, fromFile: true)
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
            state.hasValidatedFile = true
        } catch {
            state.problem = "\(SurfaceLayout.path) is unavailable: \(error). "
                + (state.hasValidatedFile ? "The window retains the last validated layout. " : "No valid layout file has been read; the window displays the in-memory seed. ")
                + "The file is preserved and layout.write is blocked until it is repaired."
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

/// One engine root's observed layout, shared by its windows and phone snapshot.
/// Her write, the person's fold or a hand edit re-renders every surface at once.
@MainActor @Observable
public final class SurfaceLayoutLive {
    public private(set) var layout: SurfaceLayout
    private let root: URL
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let snapshotRead = LatestRead()

    public nonisolated init(dataRoot: URL) {
        root = dataRoot
        _layout = SurfaceLayoutStore.layout(dataRoot: dataRoot)
    }

    deinit { observation?.cancel() }

    /// Each engine root starts its existing layout watch once, independent of windows.
    public func start() {
        let root = root
        observation = Task { [weak self] in await Self.watch(root: root) { [weak self] in self } }
    }

    public func setExpanded(_ open: Bool, surface: String, block: String) async {
        let root = root
        let saved = await Task.detached { SurfaceLayoutStore.setExpanded(open, surface: surface, block: block, dataRoot: root) }.value
        if let saved {
            snapshotRead.write { layout = saved }
        }
    }

    private static func watch(root: URL, projection: @MainActor () -> SurfaceLayoutLive?) async {
        let events = FileChangeEvents(paths: [SurfaceLayoutStore.file(root)], emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard let owner = projection() else { break }
                await owner.snapshotRead.read {
                    await Task.detached { SurfaceLayoutStore.layout(dataRoot: root) }.value
                } publish: { next in
                    if next != owner.layout { owner.layout = next }
                }
            }
        } onCancel: { events.cancel() }
    }
}
