import Foundation
import CryptoKit
// Blueprint: | `DiskStorageOwner.swift` | `DiskStorageOwner`: owner retention plans and execution, contained identity-checked moves to Trash and logical-byte outcomes; no history deletion |

/// Owners declare policy and execute only the candidates saved on the card.
public struct DiskStorageOwner: Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public let identity: String
        public let sizeBytes: Int64
    }

    public struct Plan: Codable, Sendable {
        public var owner: String
        public var roots: [String]
        public var policy: String
        public var candidates: [String: Candidate]
        public var notes: [String]

        public init(owner: String, roots: [String], policy: String,
                    candidates: [String: Candidate], notes: [String] = []) {
            self.owner = owner
            self.roots = roots
            self.policy = policy
            self.candidates = candidates
            self.notes = notes
        }
    }

    public struct Outcome: Sendable {
        public let relativePath: String
        public let sizeBytes: Int64
        public let skippedReason: String?

        public init(relativePath: String, sizeBytes: Int64 = 0, skippedReason: String?) {
            self.relativePath = relativePath
            self.sizeBytes = sizeBytes
            self.skippedReason = skippedReason
        }
    }

    public let id: String
    public let plan: @Sendable () async throws -> Plan
    public let reclaim: @Sendable (Plan) async throws -> [Outcome]

    public init(id: String, plan: @escaping @Sendable () async throws -> Plan,
                reclaim: @escaping @Sendable (Plan) async throws -> [Outcome]) {
        self.id = id
        self.plan = plan
        self.reclaim = reclaim
    }

    public static func retained(id: String, roots: [String], policy: String) -> Self {
        Self(id: id, plan: { Plan(owner: id, roots: roots, policy: policy, candidates: [:]) }, reclaim: { saved in
            saved.candidates.keys.sorted().map { Outcome(relativePath: $0, skippedReason: policy) }
        })
    }

    public static func candidate(_ path: String, dataRoot: URL) throws -> Candidate {
        try snapshot(path, dataRoot: dataRoot).candidate
    }

    private static func containedURL(_ path: String, dataRoot: URL) throws -> URL {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = dataRoot.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              resolved.path == root.appendingPathComponent(path).standardizedFileURL.path,
              NativeAgentWorkspaceRoot.relativePath(resolved.path, under: root.path).map({ !$0.isEmpty }) == true,
              try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return resolved
    }

    /// Logical bytes leaving app storage. Trash remains on the volume until the human empties it.
    public static func trash(_ path: String, candidate expected: Candidate, dataRoot: URL) -> Outcome {
        do {
            let current = try snapshot(path, dataRoot: dataRoot)
            guard current.candidate == expected else {
                return Outcome(relativePath: path, skippedReason: "changed since the plan; kept")
            }
            try FileManager.default.trashItem(at: current.url, resultingItemURL: nil)
            return Outcome(relativePath: path, sizeBytes: current.candidate.sizeBytes, skippedReason: nil)
        } catch {
            return Outcome(relativePath: path, skippedReason: "kept: \(error.localizedDescription)")
        }
    }

    private static func snapshot(_ path: String, dataRoot: URL) throws -> (url: URL, candidate: Candidate) {
        let url = try containedURL(path, dataRoot: dataRoot)
        let fm = FileManager.default
        var bytes: Int64 = 0
        var entries: [String] = []
        func record(_ file: URL) throws -> FileAttributeType {
            let a = try fm.attributesOfItem(atPath: file.path)
            guard let volume = a[.systemNumber] as? NSNumber, let inode = a[.systemFileNumber] as? NSNumber,
                  let modified = a[.modificationDate] as? Date, let size = a[.size] as? NSNumber,
                  let type = a[.type] as? FileAttributeType else { throw CocoaError(.fileReadUnknown) }
            entries.append("\(file.path)\0\(volume):\(inode):\(modified.timeIntervalSince1970):\(size):\(type.rawValue)")
            if type == .typeRegular { bytes += size.int64Value }
            return type
        }
        let type = try record(url)
        if type == .typeDirectory {
            var readError: Error?
            guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, error in
                readError = error
                return false
            }) else { throw CocoaError(.fileReadUnknown) }
            for case let file as URL in walk {
                guard entries.count < 50_000 else { throw CocoaError(.fileReadTooLarge) }
                if try record(file) == .typeSymbolicLink { walk.skipDescendants() }
            }
            if let readError { throw readError }
        } else if type != .typeRegular { throw CocoaError(.fileReadUnsupportedScheme) }
        let digest = SHA256.hash(data: Data(entries.sorted().joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (url, Candidate(identity: digest, sizeBytes: bytes))
    }
}
