import Foundation
import NativeAgentShared
import AppKit
import Observation
import AuthoredCapabilities
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MakeStudio.swift` | Root-scoped artifacts, versions and previews; LatestRead shelf; file/revision title feed slots; shutdown drain |

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
        /// The version the person changed by hand to make this one (a table edited in the window). Absent on every other version; a build
        /// without this field reads the record and drops it from the record when it next appends a version.
        public var personEditOf: Int?
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
        guard Self.isRef(ref), dir.deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path,
              !file.isEmpty, !file.contains("/"), !file.contains("\\"), file != ".", file != "..",
              destination.deletingLastPathComponent().path == dir.path else {
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

    /// The page and make.read share the metadata owner and its exact version paths.
    public func receipt(_ meta: Meta) -> JSONValue {
        .object(["status": .string("ok"), "ref": .string(meta.ref),
            "versions": .array(meta.versions.map { version in
                var row: [String: JSONValue] = ["n": .int(Int64(version.n)), "path": .string(url(meta.ref, version).path),
                    "created": .string(version.created)]
                if let prompt = version.prompt { row["prompt"] = .string(prompt) }
                if let model = version.model { row["model"] = .string(model) }
                if let madeBy = version.madeBy { row["made_by"] = .string(madeBy) }
                if let edited = version.personEditOf { row["person_edit_of"] = .int(Int64(edited)) }
                return .object(row)
            })])
    }

    /// Read membership afresh; a ref's unreadable metadata is its own row, never an omitted made thing.
    public func shelfPage(offset: Int) throws -> JSONValue {
        let refs: [String]
        let readState: String
        do {
            refs = try FileManager.default.contentsOfDirectory(atPath: root.path).filter(Self.isRef)
            readState = "read"
        } catch CocoaError.fileReadNoSuchFile {
            refs = []
            readState = "not_created"
        }
        var rows: [(ref: String, created: Date?, value: JSONValue)] = []
        for ref in refs {
            do {
                guard let meta = try readMeta(ref), let latest = meta.versions.last else {
                    throw Refusal(reason: "metadata_missing", message: "No retained version metadata was found for this ref.")
                }
                guard let created = NativeTimestampFormat.parseISO8601(latest.created) else {
                    throw Refusal(reason: "invalid_metadata", message: "The newest version's created timestamp is not an ISO-8601 date.")
                }
                var row: [String: JSONValue] = ["ref": .string(ref), "version": .int(Int64(latest.n)),
                    "version_count": .int(Int64(meta.versions.count)), "created": .string(latest.created),
                    "path": .string(url(ref, latest).path),
                    "next_call": .object(["page": .string("make"), "item": .string(ref)])]
                if let madeBy = latest.madeBy { row["made_by"] = .string(madeBy) }
                if let edited = latest.personEditOf { row["person_edit_of"] = .int(Int64(edited)) }
                rows.append((ref, created, .object(row)))
            } catch {
                rows.append((ref, nil, .object(["ref": .string(ref), "status": .string("unavailable"),
                    "path": .string(folder(ref).appendingPathComponent("meta.json").path), "detail": .string(error.localizedDescription),
                    "next_call": .object(["page": .string("make"), "item": .string(ref)])])))
            }
        }
        rows.sort {
            switch ($0.created, $1.created) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.ref < $1.ref
            }
        }
        let start = min(max(0, offset), rows.count), end = start + min(25, rows.count - start)
        return .object(["status": .string("ok"), "page": .string("make"), "items": .array(rows[start..<end].map(\.value)),
            "read_state": .string(readState),
            "total": .int(Int64(rows.count)), "count": .int(Int64(end - start)), "offset": .int(Int64(start)),
            "unavailable_count": .int(Int64(rows.filter { $0.created == nil }.count)),
            "has_more": .bool(end < rows.count), "next_offset": end < rows.count ? .int(Int64(end)) : .null,
            "next_call": end < rows.count ? .object(["page": .string("make"), "args": .object(["offset": .int(Int64(end))])]) : .null])
    }

    /// `personEditOf` lays the person's edit of that version: it is appended only while that version is still the ref's newest, so an edit
    /// never lands on top of newer work.
    @discardableResult
    public func add(_ file: URL, ref: String? = nil, prompt: String? = nil, model: String? = nil,
                    madeBy: String? = nil, personEditOf: Int? = nil) throws -> (ref: String, version: Version) {
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
            if let personEditOf, ref.isEmpty || meta.versions.last?.n != personEditOf {
                throw Refusal(reason: "version_superseded", message: """
                    Version \(personEditOf), the one you changed, is not the newest of \(meta.ref) any more, so I saved nothing. \
                    The newest is the one to change.
                    """)
            }
            let (n, exhausted) = (meta.versions.last?.n ?? 0).addingReportingOverflow(1)
            guard !exhausted else {
                throw Refusal(reason: "version_exhausted", message: "Make has no version numbers left for this ref. Nothing was written.")
            }
            let ext = file.pathExtension.lowercased()
            let version = Version(n: n, file: ext.isEmpty ? "v\(n)" : "v\(n).\(ext)", prompt: prompt, model: model,
                                  created: NativeTimestampFormat.sixDigitUTCOffset(Date()), madeBy: madeBy, personEditOf: personEditOf)
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

private enum PersonEditPart: TurnPart { static let unset: Int? = nil }

extension Turn {
    /// The Make version the person's own tap edited (a table saved from the window); make.add lays the edit as that version's successor.
    /// Only the stem sets it, through `ToolsFacade.personTap`.
    public var personEditOf: Int? {
        get { self[PersonEditPart.self] }
        set { self[PersonEditPart.self] = newValue }
    }
}

extension MakeStudio {
    /// Prepare off-main without mutating the image handed to the renderer.
    public struct Preview: Sendable {
        public let file: URL
        public let revision: Int
        public let titleKey: FaceKey?
        public let image: NSImage?
        public let imageFailure: String?
    }

    public static let webTypes: Set = ["html", "htm", "xhtml", "svg"]
    public static let imageTypes: Set = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]
    /// Plain text, Markdown and delimited sheets: what a page can show as its own words.
    public static let textTypes: Set = ["txt", "text", "md", "markdown", "csv", "tsv"]

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
        private nonisolated let feed: FaceFeedSource
        @ObservationIgnored private var titleProjections: [String: (faces: PartFaces, task: Task<Void, Never>)] = [:]
        @ObservationIgnored private var titleOrder: [String] = []
        @ObservationIgnored private var previewReads: [UUID: Task<Preview, Never>] = [:]

        public nonisolated init(dataRoot: URL, feed: FaceFeedSource, project: @escaping PartFaces.Call) {
            studio = MakeStudio(dataRoot: dataRoot)
            self.feed = feed
            self.project = project
        }

        public nonisolated func file(_ ref: String, _ version: Version) -> URL { studio.url(ref, version) }
        public nonisolated func folder(_ ref: String) -> URL { studio.folder(ref) }

        public func preview(_ ref: String, _ version: Version, revision: Int) async -> Preview {
            if stopped || Task.isCancelled { return Preview(file: file(ref, version), revision: revision, titleKey: nil, image: nil,
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
            let titleKey = PageFaceKey.makeTitle(file: file, revision: revision)
            let faces = titleProjections[key]?.faces ?? PartFaces(dataRoot: studio.dataRoot, feed: feed, key: { _ in titleKey }, call: project)
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
                    if let gone = titleProjections.removeValue(forKey: titleOrder.removeFirst()) {
                        gone.task.cancel()
                        await gone.faces.close()
                    }
                }
            }
            return Preview(file: file, revision: revision, titleKey: titleKey, image: image, imageFailure: imageFailure)
        }

        public func meta(_ ref: String?) -> MakeStudio.Meta? {
            ref.map { metadata[$0] } ?? newest
        }

        public var allMetadata: [MakeStudio.Meta] {
            metadata.values.sorted {
                let left = $0.versions.last?.created ?? "", right = $1.versions.last?.created ?? ""
                return left == right ? $0.ref < $1.ref : left < right
            }
        }

        public func start() {
            guard !stopped, !loaded else { return }
            changed(studio.root)
        }

        public func prepareCapture() async throws {
            start()
            if let refresh { await refresh.value }
            try Task.checkCancellation()
            if stopped { throw Refusal(reason: "make_stopped", message: "The Make shelf has closed.") }
            if let fault { throw Refusal(reason: "make_unavailable", message: fault) }
            guard loaded else { throw Refusal(reason: "make_unread", message: "The Make shelf has supplied no completed reading.") }
        }

        public func flushPreviewTitle(_ ref: String, version: Version, revision: Int) async {
            let key = "\(file(ref, version).path) \(revision)"
            guard let projection = titleProjections[key] else { return }
            await projection.task.value
            await projection.faces.flush()
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
            return Task.detached {
                await settle {
                    for read in reads { _ = await read.value }
                    for projection in projections { await projection.task.value }
                    for projection in projections { await projection.faces.close() }
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
