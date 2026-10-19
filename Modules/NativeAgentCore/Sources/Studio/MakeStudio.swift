import Foundation
import Observation
import NativeAgentCore
import PersistenceCore

/// What she makes for User: mockups, screens, icons, artwork. Each piece is a
/// ref with numbered versions, so an earlier one stays one click back and a
/// comment can name the exact version it is about.
///
/// <dataRoot>/make/<ref>/v<N>.<ext> + meta.json. Beside generated_images and
/// apart from studio/ (her taste journal), so a ref folder never reads as one
/// of the journal's. A version is a copy: what User commented on stays as it was.
public struct MakeStudio: Sendable {
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

    /// Nil only when the ref has no meta.json; unreadable or damaged meta throws.
    public func readMeta(_ ref: String) throws -> Meta? {
        guard Self.isRef(ref) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: folder(ref).appendingPathComponent("meta.json"))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(Meta.self, from: data)
    }

    /// The ref with the newest version; nil only when Make holds nothing. An
    /// unreadable folder or meta throws rather than reading as empty.
    public func newestRef() throws -> String? {
        let refs: [String]
        do { refs = try FileManager.default.contentsOfDirectory(atPath: root.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        return try refs.filter(Self.isRef).compactMap(readMeta)
            .max { ($0.versions.last?.created ?? "") < ($1.versions.last?.created ?? "") }?.ref
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
            let n = (meta.versions.last?.n ?? 0) + 1
            let ext = file.pathExtension.lowercased()
            let version = Version(n: n, file: ext.isEmpty ? "v\(n)" : "v\(n).\(ext)", prompt: prompt, model: model,
                                  created: StudioClock.nowISO())
            let dir = folder(meta.ref)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(version.file))
            meta.versions.append(version)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(meta), to: dir.appendingPathComponent("meta.json"))
            return (meta.ref, version)
        }
    }

    /// image.generate's images, as versions of `ref` (a new ref when nil).
    /// The envelope gains `make_ref` for what landed and `make_failed` for each
    /// image that did not, with why; a requested ref is never swapped for a new one.
    public static func registerGenerated(_ result: JSONValue, prompt: String, ref: String?, dataRoot: URL) -> JSONValue {
        guard case .object(var response) = result, response["status"] == .string("ok"),
              case .array(let images)? = response["images"] else { return result }
        let studio = MakeStudio(dataRoot: dataRoot)
        var ref = ref, landed = false, failed: [JSONValue] = []
        let model: String? = if case .string(let name)? = response["model"] { name } else { nil }
        for image in images {
            guard case .object(let row) = image, case .string(let path)? = row["path"] else { continue }
            do {
                ref = try studio.add(URL(fileURLWithPath: path), ref: ref, prompt: prompt, model: model).ref
                landed = true
            } catch {
                failed.append(.object(["path": .string(path), "error": .string(error.localizedDescription)]))
            }
        }
        if landed, let ref { response["make_ref"] = .string(ref) }
        if !failed.isEmpty { response["make_failed"] = .array(failed) }
        return .object(response)
    }
}

extension MakeStudio {
    /// What User reads in the header: a mockup's own <title>, else an image's
    /// prompt, else the file's name. The ref stays in the tooltip.
    public static func title(_ version: MakeStudio.Version, file: URL) -> String {
        if webTypes.contains(file.pathExtension.lowercased()),
           let html = try? String(contentsOf: file, encoding: .utf8),
           let open = html.range(of: "<title>", options: .caseInsensitive),
           let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) {
            let text = html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        if let prompt = version.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { return prompt }
        return file.lastPathComponent
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
        public static let shared = Shelf()
        private var metadata: [String: MakeStudio.Meta] = [:]
        private var refs: [String] = []
        public private(set) var newest: MakeStudio.Meta?
        public private(set) var loaded = false
        /// Why the shelf shows less than the disk holds; the last good
        /// membership and metadata stand meanwhile, never an empty shelf.
        public private(set) var fault: String?
        private var studio: MakeStudio?
        private var watcher: FileChangeWatcher?
        private var armed: [URL] = []
        private var pending: Set<URL> = []
        private var loading = false

        public func meta(_ ref: String?) -> MakeStudio.Meta? {
            ref.map { metadata[$0] } ?? newest
        }

        public func open(dataRoot: URL) {
            guard studio?.dataRoot != dataRoot else { return }
            let studio = MakeStudio(dataRoot: dataRoot)
            self.studio = studio
            metadata = [:]
            refs = []
            newest = nil
            loaded = false
            changed(studio.root)
        }

        private func changed(_ path: URL) {
            pending.insert(path)
            guard !loading else { return }
            loading = true
            Task {
                defer { loading = false }
                while !pending.isEmpty {
                    guard let studio = self.studio else { return }
                    let changes = pending
                    pending.removeAll()
                    let previous = metadata
                    let previousRefs = refs
                    let fresh = await Task.detached(priority: .utility) {
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
                            do { result[ref] = try studio.readMeta(ref) } catch {
                                faults.append("\(ref)/meta.json could not be read: \(error.localizedDescription)")
                            }
                        }
                        return (result, refs, refs.compactMap { result[$0] }.max { ($0.versions.last?.created ?? "") < ($1.versions.last?.created ?? "") },
                                faults.isEmpty ? nil : faults.joined(separator: "; "))
                    }.value
                    guard self.studio?.dataRoot == studio.dataRoot else { continue }
                    if fresh.0 != metadata { metadata = fresh.0 }
                    refs = fresh.1
                    if newest != fresh.2 { newest = fresh.2 }
                    fault = fresh.3
                    loaded = true
                    rearm(studio)
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
            watcher = FileChangeWatcher(paths: paths) { [weak self] path in
                Task { @MainActor in self?.changed(path.standardizedFileURL) }
            }
            // Close the registration race once, using the now-armed source.
            pending.formUnion(paths)
            changed(studio.root)
        }
    }

}
