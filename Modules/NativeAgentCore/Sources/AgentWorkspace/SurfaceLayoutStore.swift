import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import os
import PersistenceCore
// Blueprint: | `SurfaceLayoutStore.swift` | `SurfaceLayoutAvailability`, `SurfaceLayoutLive`, `read`, `write`, `setSurfaceExpanded`, `LatestRead` |
// Publish snapshot reads through LatestRead; writer-locked version checks also govern previous-content restoration.
// Checked version exhaustion refuses before either write, and layout availability never owns page discovery.

/// Every surface reads the same root-scoped ui/layout.json. Seed only checked absence or an untouched seed; preserve edits and unreadable bytes. New blocks
/// take their seed positions, while unreadable layout exposes shipped vocabulary with its failure, never a substitute layout. Pages remain discoverable
/// independently. Current/previous files enter off-disk backup; phone sync projects only current ui_layout.json, as PrivacyMap records.
public enum SurfaceLayoutStore {
    /// Validate partial writes against the same vocabulary as full documents.
    public static let writeArgumentSchema: JSONValue = {
        func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        let text = ToolSchema.strSchema()
        // A page of the agent's own is a block on the surfaces that take one; whether it is one now is checked at the write.
        let page = object(["name": .object(["type": .string("string"),
                "pattern": .string("^" + SurfaceLayout.pagePrefix + "[a-z][a-z0-9-]{1,31}$")]),
            "hidden": ToolSchema.boolSchema(), "expanded": .object(["type": .string("null")])], required: ["name", "hidden"])
        let surfaces = Dictionary(uniqueKeysWithValues: SurfaceLayout.vocabulary.map { surface, _, blocks in
            (surface, JSONValue.object(["type": .string("array"), "items": .object(["oneOf": .array(blocks.map { block -> JSONValue in
                let folds = SurfaceLayout.folds.contains(surface + "." + block.name)
                return object(["name": .object(["const": .string(block.name)]), "hidden": ToolSchema.boolSchema(),
                    "expanded": folds ? ToolSchema.boolSchema() : .object(["type": .string("null")])],
                    required: ["name", "hidden"] + (folds ? ["expanded"] : []))
            } + (SurfaceLayout.pageSurfaces.contains(surface) ? [page] : []))])]))
        })
        let profile = object(["hidden": .object(["type": .string("array"), "items": text])], required: ["hidden"])
        let profiles = SurfaceLayout.seed(from: "", at: "").profiles.keys.sorted()
        return object(["layoutVersion": ToolSchema.intSchema(minimum: 1), "seededFrom": text, "updatedAt": text,
            "source": text, "digest": text, "surfaces": object(surfaces),
            "profiles": object(Dictionary(uniqueKeysWithValues: profiles.map { ($0, profile) })),
            "phone": ToolSchema.enumStringSchema(profiles)])
    }()

    private struct Loaded: Sendable {
        var root: URL
        /// This read's checked document or failure; never a retained layout on failure.
        var availability: SurfaceLayoutAvailability
        /// The file's identity when `layout` was read; a change re-reads it.
        var stamp: SnapshotTailOpLog.FileStamp?
    }

    /// Scope caches by data root so hosts cannot read or seed another runtime's layout.
    private static let loaded = OSAllocatedUnfairLock<[String: Loaded]>(initialState: [:])

    /// Re-read layout when its file identity changes.
    public static func layout(dataRoot: URL) -> SurfaceLayoutAvailability { withLoaded(dataRoot) { $0.availability } }

    public static var profile: String? { UserDefaults.standard.string(forKey: "nativeagent.viewMode") }

    /// Return the checked version with the layout so subsequent writes can detect concurrent edits.
    public static func read(dataRoot: URL) -> JSONValue {
        withLoaded(dataRoot) { state in
            if let failure = state.availability.failure { return failureResult(failure) }
            do {
            let layout = try state.availability.get()
            var result: [String: JSONValue] = [
                "status": .string("ok"), "layout": try JSONValue.fromEncodable(layout),
                "version": .string(try version(layout)), "showing": profile.map(JSONValue.string) ?? .null,
                "path": .string(file(state.root).path), "profiles": .string(SurfaceLayout.profilesAbout),
                "blocks": blockVocabulary,
            ]
            if let previous = try? JSONValue.parse(Data(contentsOf: previous(state.root))) { result["previous"] = previous }
            result["layout_source"] = .string("validated_file")
            return .object(result)
            } catch { return failureResult(storageFailure(file(state.root), error)) }
        }
    }

    /// Partial writes retain omitted fields; check content and version so hand edits conflict too. Keep replaced bytes in layout.previous.json.
    public static func write(_ document: JSONValue, expectedVersion: String, dataRoot: URL, undoing receipt: JSONValue? = nil) -> JSONValue {
        guard case .object(let parts) = document else {
            return refused("invalid_layout", "layout is an object: layout.read's layout, or only the surfaces, profiles or phone it changes.")
        }
        do { try document.validate(schema: writeArgumentSchema) }
        catch { return refused("invalid_layout", "layout doesn't match its declared shape: \(error). Start from layout.read's layout.") }
        return withLoaded(dataRoot) { state in
            let file = file(state.root)
            do {
                return try CredentialFileLock.withLock(file) {
                    refresh(&state)
                    // A file that does not read is fixed by hand, never written over.
                    if let failure = state.availability.failure { return failureResult(failure) }
                    let layout = try state.availability.get()
                    let currentVersion = try version(layout)
                    guard expectedVersion == currentVersion else {
                        return refused("stale_layout", """
                            That layout was read at version \(expectedVersion.isEmpty ? "(none given)" : expectedVersion); it is at \(currentVersion) now, by \
                            a write or a hand edit. Read it again with layout.read.
                            """)
                    }
                    if case .object(let receipt) = receipt, receipt["version"] != .string(currentVersion) {
                        return refused("stale_layout", "The layout changed after that receipt. Read it again with layout.read.")
                    }
                    guard case .object(var merged) = try JSONValue.fromEncodable(layout) else { return refused("write_failed", "The layout could not be read.")
                        }
                    for (key, value) in parts {
                        if case .object(let named) = value, case .object(var current)? = merged[key] {
                            current.merge(named) { $1 }
                            merged[key] = .object(current)
                        } else { merged[key] = value }
                    }
                    let given: SurfaceLayout
                    do { given = try validated(.object(merged)) }
                    catch { return refused("invalid_layout",
                        "layout doesn't match a layout's shape: \(error). Start from layout.read's layout and change only what you mean to.") }
                    // A page of the agent's own is placed only while it is one: each page block the write adds names an active part's page now.
                    let placed = SurfaceLayout.pageSurfaces.sorted().flatMap { surface -> [String] in
                        let before = Set((layout.surfaces[surface] ?? []).map(\.name))
                        return (given.surfaces[surface] ?? []).filter { !before.contains($0.name) }.compactMap { SurfaceLayout.ownPage(surface, $0.name) }
                    }
                    if !placed.isEmpty {
                        let own = try ownPages(dataRoot: state.root)
                        if let missing = placed.first(where: { !own.contains($0) }) {
                            return refused("not_own_page", """
                                page:\(missing) names no page of the agent's own now: no active part has the face \
                                {projection:true, page:"\(missing)"}. Nothing was written.
                                """, instruction: """
                                    Save and turn on a part whose face is {projection:true, page:"\(missing)"} with ability.save, then place \
                                    page:\(missing); app {} lists the agent's own pages.
                                    """, next: .object(["tool": .string("app"), "input": .object([:])]))
                        }
                    }
                    // Previous-content recognition only labels the receipt; it never admits a stale write.
                    let givenContent = try content(given)
                    let restored: Int?
                    if let old = try? validated(file: previous(state.root)), try content(old) == givenContent {
                        restored = old.layoutVersion
                    } else { restored = nil }
                    let changed = try JSONValue.differences(content(layout), givenContent)
                    guard !changed.isEmpty else {
                        return .object(["status": .string("no_change"), "changed": .bool(false), "version": .string(currentVersion),
                                        "detail": .string("That is the layout as it is. Nothing was written.")])
                    }
                    let saved = try commit(given, over: &state, source: "her")
                    var receipt: [String: JSONValue] = ["status": .string("updated"), "changed": .bool(true),
                        "layout_version": .int(Int64(saved.layoutVersion)), "version": .string(try version(saved)),
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
                    "remedy": Repair.reconcile(instruction: failure?.instruction
                        ?? "Read the layout and backup before another write; fix the reported storage error.", nextCall: call)])
            }
        }
    }

    /// Person fold changes follow the same versioned writer as agent edits.
    @discardableResult
    public static func setExpanded(_ open: Bool, surface: String, block: String, dataRoot: URL) -> Result<SurfaceLayout, SurfaceLayoutFailure> {
        withLoaded(dataRoot) { state in
            let file = file(state.root)
            do {
                let saved = try CredentialFileLock.withLock(file) {
                    refresh(&state)
                    var next = try state.availability.get()
                    guard var blocks = next.surfaces[surface],
                          let index = blocks.firstIndex(where: { $0.name == block }), blocks[index].expanded != nil else {
                        throw JSONValue.ShapeError(description: "\(surface).\(block) is not a foldable layout block")
                    }
                    guard blocks[index].expanded != open else { return next }
                    blocks[index].expanded = open
                    next.surfaces[surface] = blocks
                    return try commit(next, over: &state, source: "person")
                }
                return .success(saved)
            } catch { return .failure(storageFailure(file, error)) }
        }
    }

    /// Retain replaced bytes before publishing the next version.
    private static func commit(_ next: SurfaceLayout, over state: inout Loaded, source: String) throws -> SurfaceLayout {
        var saved = next
        let current = try state.availability.get()
        let (version, overflow) = current.layoutVersion.addingReportingOverflow(1)
        guard !overflow else {
            throw ToolFailureError("The layout version is exhausted. No write was attempted; the saved layout is preserved.",
                effects: .none, code: "layout_version_exhausted",
                instruction: "Repair the layout version while preserving its original bytes before changing the layout.", recovery: .reconcile)
        }
        saved.layoutVersion = version
        saved.seededFrom = current.seededFrom
        saved.updatedAt = ISO8601DateFormatter().string(from: Date())
        saved.source = source
        saved.digest = try content(saved).digest
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
            throw ToolFailureError(
                "Backup write failed at \(backup.path): \(error.localizedDescription). The backup may have changed; layout replacement was not attempted.",
                effects: .unknown, nextCall: ToolFailureError.call("app", ["action": .string("layout.read")]),
                code: "layout_backup_write_failed", instruction: "Inspect the backup and fix the reported storage error before another write.",
                    recovery: .reconcile)
        }
        do { try write(saved, to: file) }
        catch {
            throw ToolFailureError("""
                The previous layout was saved at \(backup.path); replacing \(file.path) failed: \(error.localizedDescription). The on-disk layout is \
                unverified.
                """,
                effects: .partial, nextCall: ToolFailureError.call("app", ["action": .string("layout.read")]),
                code: "layout_replacement_failed", instruction: "Read the layout and backup before another change; fix the reported storage error.",
                    recovery: .reconcile)
        }
        state.availability = .available(saved)
        // The next read checks the committed file, including any intervening hand edit.
        state.stamp = nil
        return saved
    }

    private static func refused(_ reason: String, _ detail: String,
                                instruction: String = "Read the current layout and its shape; correct the requested change.",
                                next: JSONValue = .object(["tool": .string("app"), "input": .object(["action": .string("layout.read")])])) -> JSONValue {
        .object(["status": .string("refused"), "reason": .string(reason), "changed": .bool(false), "effects": .string("none"), "detail": .string(detail),
            "remedy": .object(["kind": .string("correct_arguments"), "instruction": .string(instruction), "next_call": next])])
    }

    /// The agent's own pages now, read from the abilities as the engine reads them: each active part whose face is
    /// `{projection:true, page:"<id>"}`. An unreadable store fails the write that asked, with its cause.
    private static func ownPages(dataRoot: URL) throws -> Set<String> {
        do { return Set(try AbilityStore(dataRoot: dataRoot).pageParts().map(\.page)) }
        catch {
            throw ToolFailureError("The abilities could not be read to check which pages are the agent's own: \(error.localizedDescription). "
                + "Nothing was written.", effects: .none, nextCall: ToolFailureError.call("app", ["page": .string("tools")]),
                code: "abilities_unreadable", instruction: "Repair the reported ability-store problem, then place the page again.", recovery: .inspect)
        }
    }

    private static func storageFailure(_ file: URL, _ error: Error) -> SurfaceLayoutFailure {
        SurfaceLayoutFailure(path: file.path, detail: "Layout unavailable: \(error.localizedDescription).",
            instruction: ToolFailureError.fileRepairInstruction(file,
                    shape: "The file must be a valid SurfaceLayout JSON object; use layout.read's blocks and profiles as the vocabulary.")
                    + " Repair the saved layout while preserving its original bytes; layout.write is blocked until it validates.")
    }

    public static func failureResult(_ failure: SurfaceLayoutFailure) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string("invalid_file"), "effects": .string("none"),
            "path": .string(failure.path), "detail": .string(failure.localizedDescription),
            "blocks": blockVocabulary, "profiles": .string(SurfaceLayout.profilesAbout),
            "remedy": Repair.remedy(owner: failure.path, nextCall: nil, tap: nil, instruction: failure.instruction)])
    }

    private static var blockVocabulary: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: SurfaceLayout.vocabulary.map { surface, about, blocks in
            (surface, .string(about + ". Blocks: " + blocks.map { $0.shows.isEmpty ? $0.name : "\($0.name) (\($0.shows))" }.joined(separator: ", ")
                + (SurfaceLayout.pageSurfaces.contains(surface) ? ". " + SurfaceLayout.pageBlockAbout : "")))
        }))
    }

    /// Read and write validators share one vocabulary; require unique blocks and fold-only `expanded`.
    private static func validated(_ document: JSONValue, addingMissing: Bool = true) throws -> SurfaceLayout {
        var layout = try document.decodedExactly(as: SurfaceLayout.self)
        // Versions start at one. Int.max is readable but exhausted: commit reports that boundary before touching either saved file.
        guard layout.layoutVersion > 0 else {
            throw JSONValue.ShapeError(description: "layoutVersion must be a positive integer")
        }
        let known = Dictionary(uniqueKeysWithValues: SurfaceLayout.vocabulary.map { ($0.surface, $0.blocks.map(\.name)) })
        func shape(_ text: String) -> JSONValue.ShapeError { JSONValue.ShapeError(description: text) }
        for (surface, blocks) in layout.surfaces.sorted(by: { $0.key < $1.key }) {
            guard let names = known[surface] else {
                throw shape("surfaces.\(surface) is not a surface; they are \(known.keys.sorted().joined(separator: ", "))")
            }
            var seen = Set<String>()
            for (index, block) in blocks.enumerated() {
                let at = "surfaces.\(surface)[\(index)]"
                guard names.contains(block.name) || SurfaceLayout.ownPage(surface, block.name) != nil else {
                    let takesPages = SurfaceLayout.pageSurfaces.contains(surface)
                    if takesPages, block.name.hasPrefix(SurfaceLayout.pagePrefix),
                       let refusal = AppDoorNames.ownPageRefusal(String(block.name.dropFirst(SurfaceLayout.pagePrefix.count))) {
                        throw shape("\(at).name \"\(block.name)\": \(refusal)")
                    }
                    throw shape("\(at).name \"\(block.name)\" is not a \(surface) block; they are \(names.joined(separator: ", "))"
                        + (takesPages ? ", or page:<id> for a page of the agent's own" : ""))
                }
                guard seen.insert(block.name).inserted else { throw shape("\(at).name \"\(block.name)\" is listed twice") }
                let folds = SurfaceLayout.folds.contains(surface + "." + block.name)
                guard (block.expanded != nil) == folds else {
                    throw shape(folds ? "\(at).expanded is missing"
                        : "\(at).expanded is only on a block that folds: \(SurfaceLayout.folds.sorted().joined(separator: ", "))")
                }
            }
        }
        let profiles = SurfaceLayout.seed(from: "", at: "").profiles.keys
        let blocks = Set(known.flatMap { surface, names in names.map { surface + "." + $0 } })
        for (name, profile) in layout.profiles.sorted(by: { $0.key < $1.key }) {
            guard profiles.contains(name) else { throw shape("profiles.\(name) is not a profile; they are \(profiles.sorted().joined(separator: ", "))") }
            for (index, hidden) in profile.hidden.enumerated() where !blocks.contains(hidden) && !SurfaceLayout.placesOwnPage(hidden) {
                throw shape("profiles.\(name).hidden[\(index)] \"\(hidden)\" names no surface.block")
            }
        }
        guard profiles.contains(layout.phone) else { throw shape("phone \"\(layout.phone)\" is not a profile") }
        if addingMissing { layout.addMissing() }
        return layout
    }

    /// A saved file reads in the current vocabulary (`dropRemoved`); writes through the agent's door are checked against it strictly.
    private static func validated(file: URL, addingMissing: Bool = true) throws -> SurfaceLayout {
        var saved = try JSONValue.parse(Data(contentsOf: file)).decodedExactly(as: SurfaceLayout.self)
        saved.dropRemoved()
        return try validated(JSONValue.fromEncodable(saved), addingMissing: addingMissing)
    }

    /// Exclude author and time from the content digest so identical layouts compare equally.
    private static func content(_ layout: SurfaceLayout) throws -> JSONValue {
        var bare = layout
        (bare.layoutVersion, bare.seededFrom, bare.updatedAt, bare.source, bare.digest) = (0, "", "", "", "")
        return try JSONValue.fromEncodable(bare)
    }

    /// Include visible content in the version so hand edits invalidate stale writes.
    private static func version(_ layout: SurfaceLayout) throws -> String { try "\(layout.layoutVersion)@" + content(layout).digest }

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

    /// A failed read replaces the checked value with its owning failure.
    private static func refresh(_ state: inout Loaded) {
        let file = file(state.root)
        let now = SnapshotTailOpLog.fileStamp(file)
        guard now == nil || now != state.stamp || state.availability.failure != nil else { return }
        state.stamp = now
        do {
            state.availability = .available(try validated(file: file))
        } catch {
            state.availability = .unavailable(storageFailure(file, error))
        }
    }

    private static func scan(_ root: URL) -> Loaded {
        let build = NativeAgentBuildIdentity.current
        let file = file(root)
        do {
            try seed(file, from: "\(build.version) (\(build.build))")
            let identity = SnapshotTailOpLog.fileStamp(file)
            return Loaded(root: root, availability: .available(try validated(file: file)), stamp: identity)
        } catch {
            return Loaded(root: root, availability: .unavailable(storageFailure(file, error)), stamp: nil)
        }
    }

    private static func seed(_ file: URL, from build: String) throws {
        // Read the persisted Helpers rail preference so its chosen value survives layout seeding.
        let helpersOff = UserDefaults.standard.object(forKey: "uiBotsShelfPreview") as? Bool == false
        var fresh = SurfaceLayout.seed(from: build, at: ISO8601DateFormatter().string(from: Date()), hidden: helpersOff ? ["rail.bots"] : [])
        fresh.digest = try content(fresh).digest
        try CredentialFileLock.withLock(file) {
            guard let identity = entryStamp(file) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if identity != .absent {
                // Seed identity is structural: an untouched seed can contain a block the current vocabulary has removed.
                // Authored documents still pass the current vocabulary check when scan reads the selected file.
                let saved = try JSONValue.parse(Data(contentsOf: file)).decodedExactly(as: SurfaceLayout.self)
                guard saved.layoutVersion == 1, saved.source == "seed",
                      saved.digest == (try content(saved).digest), saved.digest != fresh.digest else { return }
            }
            try write(fresh, to: file)
        }
    }

    private static func write(_ layout: SurfaceLayout, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(layout), to: file)
    }

    /// Entry absence is checked without following links: a dangling link is not a missing layout.
    private static func entryStamp(_ file: URL) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
        return SnapshotTailOpLog.FileStamp(info)
    }
}

/// Share one root's observed layout so every surface redraws on any writer's edit.
@MainActor @Observable
public final class SurfaceLayoutLive {
    public static let didChange = Notification.Name("NativeAgent.surfaceLayoutChanged")
    public private(set) var availability: SurfaceLayoutAvailability
    public var layout: SurfaceLayout? { availability.value }
    private let root: URL
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let snapshotRead = LatestRead()

    public nonisolated init(dataRoot: URL) {
        root = dataRoot
        _availability = SurfaceLayoutStore.layout(dataRoot: dataRoot)
    }

    deinit { observation?.cancel() }

    /// Each engine root starts its existing layout watch once, independent of windows.
    public func start() {
        let root = root
        observation = Task { [weak self] in await Self.watch(root: root) { [weak self] in self } }
    }

    @discardableResult
    public func setExpanded(_ open: Bool, surface: String, block: String) async -> Result<SurfaceLayout, SurfaceLayoutFailure> {
        let root = root
        let saved = await Task.detached { SurfaceLayoutStore.setExpanded(open, surface: surface, block: block, dataRoot: root) }.value
        switch saved {
        case .success(let value):
            snapshotRead.write {
                availability = .available(value)
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        case .failure(let failure):
            SystemToastCenter.shared.push(error: failure.localizedDescription, autoDismissAfter: nil)
            await snapshotRead.read {
                await Task.detached { SurfaceLayoutStore.layout(dataRoot: root) }.value
            } publish: {
                availability = $0
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
        return saved
    }

    private static func watch(root: URL, projection: @MainActor () -> SurfaceLayoutLive?) async {
        let events = FileChangeEvents(paths: [SurfaceLayoutStore.file(root)], emitInitial: true)
        await withTaskCancellationHandler {
            for await _ in events.stream {
                guard let owner = projection() else { break }
                await owner.snapshotRead.read {
                    await Task.detached { SurfaceLayoutStore.layout(dataRoot: root) }.value
                } publish: { next in
                    if next != owner.availability {
                        owner.availability = next
                        NotificationCenter.default.post(name: Self.didChange, object: nil)
                    }
                }
            }
        } onCancel: { events.cancel() }
    }
}
