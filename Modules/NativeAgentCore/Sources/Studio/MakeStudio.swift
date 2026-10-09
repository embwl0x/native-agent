import Foundation
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

    public func meta(_ ref: String) -> Meta? {
        guard Self.isRef(ref),
              let data = try? Data(contentsOf: folder(ref).appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// The ref with the newest version.
    public func newestRef() -> String? {
        let refs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return refs.compactMap(meta).max { ($0.versions.last?.created ?? "") < ($1.versions.last?.created ?? "") }?.ref
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
                guard let found = self.meta(ref) else {
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
            try encoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            return (meta.ref, version)
        }
    }

    /// image.generate's images, as versions of `ref` (a new ref when nil or
    /// unknown). The envelope gains `make_ref`; a failed copy leaves it as it was.
    public static func registerGenerated(_ result: JSONValue, prompt: String, ref: String?, dataRoot: URL) -> JSONValue {
        guard case .object(var response) = result, response["status"] == .string("ok"),
              case .array(let images)? = response["images"] else { return result }
        let studio = MakeStudio(dataRoot: dataRoot)
        var ref = ref.flatMap { studio.meta($0) == nil ? nil : $0 }
        let model: String? = if case .string(let name)? = response["model"] { name } else { nil }
        for image in images {
            guard case .object(let row) = image, case .string(let path)? = row["path"],
                  let added = try? studio.add(URL(fileURLWithPath: path), ref: ref, prompt: prompt, model: model)
            else { continue }
            ref = added.ref
        }
        if let ref { response["make_ref"] = .string(ref) }
        return .object(response)
    }
}
