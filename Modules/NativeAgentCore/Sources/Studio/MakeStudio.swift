import Foundation
import NativeAgentShared
import AppKit
import Observation
import AuthoredCapabilities
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MakeStudio.swift` | Root-scoped artifact metadata, native decoding, durable version allocation and previews; generated-image registration is editable `Resources/abilities/make-generated.js`, composing native raw generation results with `make.add` (prompt/model metadata retained); `MakeRegistration` explicitly carries native generation receipt paths to that registration call, and the registration primitive admits those verified app outputs while arbitrary files retain the workspace fence; `MakeStudio.Shelf` owns watcher/coalescing lifetime and publishes its read results through `LatestRead`; each preview file/revision owns L0 `PartFaces` for editable `Resources/abilities/make-title.js` (HTML title → prompt → filename); native unavailable/failed status accompanies the face, views only read their preview's snapshots; shutdown drains projections and cancellation never rearms a retired shelf |

/// Native receipts admitted for one registration operation. Parts cannot supply this evidence in their input.
public struct MakeRegistration: Sendable {
    public let generatedImagePaths: Set<String>
    public init(generatedImagePaths: Set<String>) { self.generatedImagePaths = generatedImagePaths }
}

/// Numbered copies keep each version and the user's comments tied to unchanged bytes. Store refs under make/, apart from the taste journal's studio/ directory
/// to prevent identity collisions.
public struct MakeStudio: Sendable {
    public struct Version: Codable, Sendable, Equatable {
        public let n: Int
        public let file: String
        public let prompt: String?
        public let model: String?
        public let created: String
        /// Native provenance for another agent's output registered as the agent's: "made by ‹contact› for ‹job›". The agent's own versions have none.
        public var madeBy: String?
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

    @discardableResult
    public func add(_ file: URL, ref: String? = nil, prompt: String? = nil, model: String? = nil,
                    madeBy: String? = nil) throws -> (ref: String, version: Version) {
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
                                  created: NativeTimestampFormat.sixDigitUTCOffset(Date()), madeBy: madeBy)
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
                // A directory-sync error can follow the metadata rename. Keep a referenced copy (or an unreadable commit); remove only a known orphan.
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
    /// Prepare off-main without mutating the image handed to the renderer.
    public struct Preview: Sendable {
        public let file: URL
        public let revision: Int
        public let titleFaces: PartFaces?
        public let image: NSImage?
        public let imageFailure: String?
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
        // Preserve an existing destination until the panel confirms replacement.
        if let planned = target, FileManager.default.fileExists(atPath: planned.path)
            || FileManager.default.fileExists(atPath: planned.deletingPathExtension().appendingPathExtension("prompt.txt").path) {
            target = nil
        }
        return (project, target)
    }

    public struct ExportResult: Sendable {
        public enum Output: Sendable {
            case saved(URL)
            /// A thrown atomic write leaves its final effect unconfirmed.
            case unconfirmed(URL, String)
            case notAttempted(URL)

            var message: String {
                switch self {
                case .saved(let path): "Saved to \(path.path)."
                case .unconfirmed(let path, let cause): "Save outcome unconfirmed at \(path.path): \(cause). Inspect this file before repeating the export."
                case .notAttempted(let path): "Not attempted at \(path.path)."
                }
            }
        }
        public let work: Output
        public let prompt: Output
        public var message: String { "Work: \(work.message) Prompt: \(prompt.message)" }
    }

    /// One owner prepares both outputs before replacing either, then reports each replacement independently. Two file replacements are not a transaction.
    public static func export(_ file: URL, to target: URL, prompt: String) throws -> ExportResult {
        // Compare file identity so hard links and symlinks cannot bypass the same-file check.
        func identity(_ url: URL) throws -> (system: NSNumber, file: NSNumber)? {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            guard let system = attributes[.systemNumber] as? NSNumber,
                  let file = attributes[.systemFileNumber] as? NSNumber else {
                throw Refusal(reason: "export_identity_unavailable", message: "Could not establish file identity at \(url.path). Nothing was exported.")
            }
            return (system, file)
        }
        let sidecar = target.deletingPathExtension().appendingPathExtension("prompt.txt")
        guard let source = try identity(file) else {
            throw Refusal(reason: "export_source_unavailable", message: "The studio's source file is missing. Nothing was exported.")
        }
        for output in [target, sidecar] {
            if let existing = try identity(output), existing.system == source.system, existing.file == source.file {
                throw Refusal(reason: "export_is_source", message: "An export output is the studio's own file. Pick another place; nothing was exported.")
            }
        }
        let bytes = try Data(contentsOf: file)
        let promptBytes = Data(prompt.utf8)
        do { try bytes.write(to: target, options: .atomic) }
        catch { return ExportResult(work: .unconfirmed(target, error.localizedDescription), prompt: .notAttempted(sidecar)) }
        do { try promptBytes.write(to: sidecar, options: .atomic) }
        catch { return ExportResult(work: .saved(target), prompt: .unconfirmed(sidecar, error.localizedDescription)) }
        return ExportResult(work: .saved(target), prompt: .saved(sidecar))
    }

    /// Share one event-driven index so the visible shelf and auto-open signal cannot disagree.
    @MainActor
    @Observable
    public final class Shelf {
        private var metadata: [String: MakeStudio.Meta] = [:]
        private var refs: [String] = []
        public private(set) var newest: MakeStudio.Meta?
        public private(set) var loaded = false
        /// Keep last-good membership and metadata visible when the disk read is incomplete.
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
            if stopped || Task.isCancelled { return Preview(file: file(ref, version), revision: revision, titleFaces: nil, image: nil,
                imageFailure: "Image preview preparation stopped.") }
            let id = UUID()
            let read = Task { await preparePreview(ref, version, revision: revision) }
            previewReads[id] = read
            defer { previewReads.removeValue(forKey: id) }
            return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
        }

        private func preparePreview(_ ref: String, _ version: Version, revision: Int) async -> Preview {
            let file = file(ref, version)
            let read = Task.detached(priority: .userInitiated) { () -> (JSONValue, String?, NSImage?, String?) in
                var html: JSONValue = .object(["state": .string("not_applicable")])
                var unavailable: String?
                if MakeStudio.webTypes.contains(file.pathExtension.lowercased()) {
                    do { html = .object(["state": .string("available"), "text": .string(try String(contentsOf: file, encoding: .utf8))]) }
                    catch { unavailable = "\(file.lastPathComponent) could not be decoded: \(error.localizedDescription)" }
                }
                var image: NSImage?
                var imageFailure: String?
                if MakeStudio.imageTypes.contains(file.pathExtension.lowercased()) {
                    do {
                        let bytes = try Data(contentsOf: file)
                        guard let decoded = NSImage(data: bytes) else {
                            throw Refusal(reason: "image_decode_failed", message: "AppKit could not decode image bytes at \(file.path).")
                        }
                        image = decoded
                    } catch { imageFailure = "Image preview unavailable: \(error.localizedDescription)" }
                }
                return (.object(["file": .string(file.path), "revision": .int(Int64(revision)),
                    "filename": .string(file.lastPathComponent), "html": html,
                    "prompt": version.prompt.map(JSONValue.string) ?? .null]), unavailable,
                    image, imageFailure)
            }
            let (input, unavailable, image, imageFailure) = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
            // Scope sources per file and revision so concurrent previews cannot publish each other's titles.
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
            return Preview(file: file, revision: revision, titleFaces: faces, image: image, imageFailure: imageFailure)
        }

        public func meta(_ ref: String?) -> MakeStudio.Meta? {
            ref.map { metadata[$0] } ?? newest
        }

        public func start() {
            guard !stopped, !loaded else { return }
            changed(studio.root)
        }

        /// Retire shelf reads at engine shutdown so they cannot rearm observers.
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

        /// Watch every ref: any new version can become newest, and a new ref requires rearming membership observation.
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
