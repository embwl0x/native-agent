import Foundation
import NativeAgentShared
import AppKit
import Observation
import AuthoredCapabilities
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MakeStudio.swift` | Root-scoped artifact metadata, native decoding, durable version allocation and previews; generated-image registration is editable `Resources/abilities/make-generated.js`, composing native raw generation results with `make.add` (prompt/model metadata retained); native generation receipt paths are scoped to that call, and the registration primitive admits those verified app outputs while arbitrary files retain the workspace fence; `MakeStudio.Shelf` owns watcher/coalescing lifetime and publishes its read results through `LatestRead`; each preview file/revision owns L0 `PartFaces` for editable `Resources/abilities/make-title.js` (HTML title → prompt → filename); native unavailable/failed status accompanies the face, views only read their preview's snapshots; shutdown drains projections and cancellation never rearms a retired shelf |

/// What she makes for User: mockups, screens, icons, artwork. Each piece is a
/// ref with numbered versions, so an earlier one stays one click back and a
/// comment can name the exact version it is about.
///
/// <dataRoot>/make/<ref>/v<N>.<ext> + meta.json. Beside generated_images and
/// apart from studio/ (her taste journal), so a ref folder never reads as one
/// of the journal's. A version is a copy: what User commented on stays as it was.
public struct MakeStudio: Sendable {
    /// Native generation receipt paths, scoped to its registration call. A
    /// part cannot add provenance by naming a file or a directory in its input.
    @TaskLocal public static var generatedImagePaths: Set<String> = []

    public struct Version: Codable, Sendable, Equatable {
        public let n: Int
        public let file: String
        public let prompt: String?
        public let model: String?
        public let created: String
    }

    public struct Meta: Codable, Sendable, Equatable {
        public let ref: String
        public var versions: [Version]
    }

    public struct Refusal: Error, LocalizedError, Sendable {
        public let reason: String
        public let message: String
        public var errorDescription: String? { message }
    }

    public let dataRoot: URL
    public var root: URL { dataRoot.appendingPathComponent("make", isDirectory: true) }

    public init(dataRoot: URL) { self.dataRoot = dataRoot }

    public func folder(_ ref: String) -> URL { root.appendingPathComponent(ref, isDirectory: true) }

    public func url(_ ref: String, _ version: Version) -> URL { folder(ref).appendingPathComponent(version.file) }

    public static func isRef(_ ref: String) -> Bool {
        !ref.isEmpty && ref.count <= 40 && ref.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private func checkedDestination(_ ref: String, file: String) throws -> URL {
        let dir = folder(ref).standardizedFileURL.resolvingSymlinksInPath()
        let destination = dir.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isRef(ref), dir.deletingLastPathComponent() == root.standardizedFileURL.resolvingSymlinksInPath(),
              !file.isEmpty, !file.contains("/"), !file.contains("\\"), file != ".", file != "..",
              destination.deletingLastPathComponent() == dir else {
            throw Refusal(reason: "invalid_metadata", message: "Make paths must stay inside their ref folder. Metadata was preserved.")
        }
        return destination
    }

    /// Nil only when the ref has no meta.json; unreadable or damaged meta throws.
    public func readMeta(_ ref: String) throws -> Meta? {
        guard Self.isRef(ref) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: checkedDestination(ref, file: "meta.json"))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        guard meta.ref == ref else {
            throw Refusal(reason: "invalid_metadata", message: "Make metadata names a different ref. Metadata was preserved.")
        }
        var previous = 0
        for version in meta.versions {
            guard version.n > previous else {
                throw Refusal(reason: "invalid_metadata", message: "Make versions must have positive, increasing numbers. Metadata was preserved.")
            }
            previous = version.n
            let stem = "v\(version.n)"
            guard version.file == stem || (version.file.hasPrefix(stem + ".") && !version.file.hasSuffix(".")) else {
                throw Refusal(reason: "invalid_metadata", message: "Make version filenames must name their version. Metadata was preserved.")
            }
            _ = try checkedDestination(ref, file: version.file)
        }
        return meta
    }

    /// Metadata with the newest version; nil for an empty store, unreadable folders or metadata throw.
    public func newestMeta() throws -> Meta? {
        let refs: [String]
        do { refs = try FileManager.default.contentsOfDirectory(atPath: root.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        return try refs.filter(Self.isRef).compactMap(readMeta)
            .max { ($0.versions.last?.created ?? "") < ($1.versions.last?.created ?? "") }
    }

    /// Copies `file` in as the next version of `ref`, or of a new ref when nil.
    @discardableResult
    public func add(_ file: URL, ref: String? = nil, prompt: String? = nil, model: String? = nil) throws -> (ref: String, version: Version) {
        let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return try CredentialFileLock.withLock(root) {
            var meta: Meta
            if ref.isEmpty {
                meta = Meta(ref: String(UUID().uuidString.lowercased().prefix(8)), versions: [])
            } else {
                guard let found = try self.readMeta(ref) else {
                    throw Refusal(reason: "unknown_ref", message: "No Make ref is called \(ref). Leave ref out to start a new one.")
                }
                meta = found
            }
            let (n, exhausted) = (meta.versions.last?.n ?? 0).addingReportingOverflow(1)
            guard !exhausted else {
                throw Refusal(reason: "version_exhausted", message: "Make has no version numbers left for this ref. Nothing was written.")
            }
            let ext = file.pathExtension.lowercased()
            let version = Version(n: n, file: ext.isEmpty ? "v\(n)" : "v\(n).\(ext)", prompt: prompt, model: model,
                                  created: NativeTimestampFormat.sixDigitUTCOffset(Date()))
            let dir = folder(meta.ref)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = try checkedDestination(meta.ref, file: version.file)
            try FileManager.default.copyItem(at: file, to: copy)
            meta.versions.append(version)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(meta), to: checkedDestination(meta.ref, file: "meta.json"))
            } catch let writeError {
                // A directory-sync error can follow the metadata rename. Keep a
                // referenced copy (or an unreadable commit); remove only a known orphan.
                do {
                    if try readMeta(meta.ref)?.versions.contains(version) != true {
                        try FileManager.default.removeItem(at: copy)
                    }
                } catch { nativeLog("Make append cleanup: %@", error.localizedDescription) }
                throw writeError
            }
            return (meta.ref, version)
        }
    }

}

extension MakeStudio {
    /// Prepared off-main, then handed to the renderer without mutating its image.
    public struct Preview: Sendable {
        public let file: URL
        public let revision: Int
        public let titleFaces: PartFaces?
        public let image: NSImage?
    }

    public static let webTypes: Set = ["html", "htm", "xhtml", "svg"]
    public static let imageTypes: Set = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    public static func exportDestination(projectPath: String?, name: String) -> (project: URL?, target: URL?) {
        let project = projectPath.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        var target = project?.appendingPathComponent(name)
        // Never over a file already there: the panel asks first.
        if let planned = target, FileManager.default.fileExists(atPath: planned.path)
            || FileManager.default.fileExists(atPath: planned.deletingPathExtension().appendingPathExtension("prompt.txt").path) {
            target = nil
        }
        return (project, target)
    }

    public static func export(_ file: URL, to target: URL, prompt: String) throws -> String {
        // The same file by identity (a hard link or symlink too), not by path.
        let identity = { (url: URL) in
            try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        }
        guard identity(target).map({ $0.isEqual(identity(file)) }) != true else {
            return "That is the studio's own file, so nothing was saved. Pick another place."
        }
        let sidecar = target.deletingPathExtension().appendingPathExtension("prompt.txt")
        // Written beside the target and swapped in: a failed save leaves what was there.
        try Data(contentsOf: file).write(to: target, options: .atomic)
        try prompt.write(to: sidecar, atomically: true, encoding: .utf8)
        return "Saved to \(target.path)"
    }

    /// One event-driven index serves the visible shelf and the auto-open signal.
    @MainActor
    @Observable
    public final class Shelf {
        private var metadata: [String: MakeStudio.Meta] = [:]
        private var refs: [String] = []
        public private(set) var newest: MakeStudio.Meta?
        public private(set) var loaded = false
        /// Why the shelf shows less than the disk holds; the last good
        /// membership and metadata stand meanwhile, never an empty shelf.
        public private(set) var fault: String?
        private nonisolated let studio: MakeStudio
        private var watcher: FileChangeWatcher?
        private var armed: [URL] = []
        private var pending: Set<URL> = []
        private var refresh: Task<Void, Never>?
        private var lifecycle = UUID()
        private var stopped = false
        @ObservationIgnored private lazy var latest = LatestRead()
        @ObservationIgnored private nonisolated let project: PartFaces.Call
        @ObservationIgnored private var titleProjections: [String: (faces: PartFaces, task: Task<Void, Never>)] = [:]
        @ObservationIgnored private var titleOrder: [String] = []
        @ObservationIgnored private var previewReads: [UUID: Task<Preview, Never>] = [:]

        public nonisolated init(dataRoot: URL, project: @escaping PartFaces.Call) {
            studio = MakeStudio(dataRoot: dataRoot)
            self.project = project
        }

        public nonisolated func file(_ ref: String, _ version: Version) -> URL { studio.url(ref, version) }
        public nonisolated func folder(_ ref: String) -> URL { studio.folder(ref) }

        public func preview(_ ref: String, _ version: Version, revision: Int) async -> Preview {
            if stopped || Task.isCancelled { return Preview(file: file(ref, version), revision: revision, titleFaces: nil, image: nil) }
            let id = UUID()
            let read = Task { await preparePreview(ref, version, revision: revision) }
            previewReads[id] = read
            defer { previewReads.removeValue(forKey: id) }
            return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
        }

        private func preparePreview(_ ref: String, _ version: Version, revision: Int) async -> Preview {
            let file = file(ref, version)
            let read = Task.detached(priority: .userInitiated) { () -> (JSONValue, String?, NSImage?) in
                var html: JSONValue = .object(["state": .string("not_applicable")])
                var unavailable: String?
                if MakeStudio.webTypes.contains(file.pathExtension.lowercased()) {
                    do { html = .object(["state": .string("available"), "text": .string(try String(contentsOf: file, encoding: .utf8))]) }
                    catch { unavailable = "\(file.lastPathComponent) could not be decoded: \(error.localizedDescription)" }
                }
                return (.object(["file": .string(file.path), "revision": .int(Int64(revision)),
                    "filename": .string(file.lastPathComponent), "html": html,
                    "prompt": version.prompt.map(JSONValue.string) ?? .null]), unavailable,
                    MakeStudio.imageTypes.contains(file.pathExtension.lowercased()) ? NSImage(contentsOf: file) : nil)
            }
            let (input, unavailable, image) = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
            // Each file/revision has its own source, including concurrent page renders.
            let key = "\(file.path) \(revision)"
            let faces = titleProjections[key]?.faces ?? PartFaces(dataRoot: studio.dataRoot, call: project)
            if !stopped, !Task.isCancelled {
                let previous = titleProjections[key]?.task
                previous?.cancel()
                titleProjections[key] = (faces, Task {
                    if let previous { await settle { await previous.value } }
                    guard !stopped, !Task.isCancelled else { return }
                    await faces.sourceChanged(id: "make-title", epoch: 0, input: input, unavailable: unavailable)
                })
                // Only recent previews keep live titles; each retired one stops its part watcher.
                titleOrder.removeAll { $0 == key }
                titleOrder.append(key)
                while titleOrder.count > 4 {
                    if let gone = titleProjections.removeValue(forKey: titleOrder.removeFirst()) { gone.task.cancel(); _ = gone.faces.stop() }
                }
            }
            return Preview(file: file, revision: revision, titleFaces: faces, image: image)
        }

        public func meta(_ ref: String?) -> MakeStudio.Meta? {
            ref.map { metadata[$0] } ?? newest
        }

        public func start() {
            guard !stopped, !loaded else { return }
            changed(studio.root)
        }

        /// Terminal engine shutdown retires this root's shelf and its reads.
        public func shutdown() -> Task<Void, Never> {
            stopped = true
            lifecycle = UUID()
            watcher?.cancel()
            watcher = nil
            armed = []
            pending.removeAll()
            let refreshDrain = refresh
            refreshDrain?.cancel()
            refresh = nil
            let reads = Array(previewReads.values)
            for read in reads { read.cancel() }
            let projections = Array(titleProjections.values)
            for projection in projections { projection.task.cancel() }
            titleProjections.removeAll()
            titleOrder.removeAll()
            let faceDrains = projections.map { $0.faces.stop() }
            return Task.detached {
                await settle {
                    for read in reads { _ = await read.value }
                    for projection in projections { await projection.task.value }
                    for drain in faceDrains { await drain.value }
                    if let refreshDrain { await refreshDrain.value }
                }
            }
        }

        private func changed(_ path: URL) {
            guard !stopped else { return }
            pending.insert(path)
            guard refresh == nil else { return }
            let lifecycle = self.lifecycle
            refresh = Task {
                defer { if self.lifecycle == lifecycle { refresh = nil } }
                while !Task.isCancelled, self.lifecycle == lifecycle, !pending.isEmpty {
                    let studio = self.studio
                    let changes = pending
                    pending.removeAll()
                    let previous = metadata
                    let previousRefs = refs
                    await latest.read({
                        let read = Task.detached(priority: .utility) {
                            var refs = previousRefs, faults: [String] = []
                            if changes.contains(studio.root) {
                                do {
                                    try FileManager.default.createDirectory(at: studio.root, withIntermediateDirectories: true)
                                    refs = try FileManager.default.contentsOfDirectory(atPath: studio.root.path).filter(MakeStudio.isRef)
                                } catch {
                                    faults.append("\(studio.root.path) could not be read: \(error.localizedDescription)")
                                }
                            }
                            let membership = Set(refs)
                            var result = previous.filter { membership.contains($0.key) }
                            for ref in refs where result[ref] == nil || changes.contains(studio.folder(ref).appendingPathComponent("meta.json")) {
                                if Task.isCancelled { break }
                                do { result[ref] = try studio.readMeta(ref) } catch {
                                    faults.append("\(ref)/meta.json could not be read: \(error.localizedDescription)")
                                }
                            }
                            return (result, refs, refs.compactMap { result[$0] }.max { ($0.versions.last?.created ?? "") < ($1.versions.last?.created ?? "") },
                                    faults.isEmpty ? nil : faults.joined(separator: "; "))
                        }
                        return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
                    }, publish: { fresh in
                        guard !Task.isCancelled, self.lifecycle == lifecycle else { return }
                        if fresh.0 != metadata { metadata = fresh.0 }
                        refs = fresh.1
                        if newest != fresh.2 { newest = fresh.2 }
                        fault = fresh.3
                        loaded = true
                        rearm(studio)
                    })
                }
            }
        }

        /// Every ref's meta, not only the shown one's: a new version of another
        /// ref is the new newest. A new ref changes the set, so it is re-armed.
        private func rearm(_ studio: MakeStudio) {
            let paths = [studio.root] + refs.sorted().map { studio.folder($0).appendingPathComponent("meta.json") }
            guard paths != armed else { return }
            armed = paths
            watcher?.cancel()
            let lifecycle = self.lifecycle
            watcher = FileChangeWatcher(paths: paths) { [weak self] path in
                Task { @MainActor in
                    guard let self, self.lifecycle == lifecycle else { return }
                    self.changed(path.standardizedFileURL)
                }
            }
            // Close the registration race once, using the now-armed source.
            pending.formUnion(paths)
            changed(studio.root)
        }
    }

}
