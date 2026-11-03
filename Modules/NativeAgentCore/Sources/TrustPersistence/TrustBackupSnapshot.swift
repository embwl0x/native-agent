import Foundation
import Darwin
import CryptoKit
import NativeAgentShared
import PersistenceCore
import Transcripts
import TrustCenter
import AuthoredCapabilities
import MemoryV2
import Privacy
import SystemOps
import os
// Blueprint: | `TrustBackupSnapshot.swift` | TrustBackupPersistence current sealed snapshot evidence; checked complete enumeration, explicit canonical persona destination, link containment and pre-staging restorable validation |

struct NativeBackupIntegrityFile: Codable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int64
    let sha256: String
}

/// A symlink in the data root, kept in a local backup's manifest as its raw `readlink` target instead of bytes; restore
/// recreates the link itself.
struct NativeBackupLink: Equatable {
    let path: String
    let target: String
}

struct NativeValidatedBackupSnapshot {
    let id: String
    let dataDirectory: URL
    /// Validated captured scopes: the only paths restore may replace.
    let copied: [String]
    let files: [NativeBackupIntegrityFile]
    let links: [NativeBackupLink]
    let reason: String
    let createdAt: String
    let manifestSHA256: String
}

extension TrustBackupPersistence {
    static func validateBackupSnapshot(
        id rawID: String,
        dataRoot root: URL,
        requireRestorableAuthority: Bool = true
    ) throws -> NativeValidatedBackupSnapshot {
        guard let uuid = UUID(uuidString: rawID) else {
            throw Self.backupError(code: 422, "Backup id is not a UUID.")
        }
        let id = uuid.uuidString.lowercased()
        guard rawID.lowercased() == id else {
            throw Self.backupError(code: 422, "Backup id is not canonical.")
        }

        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupDir = backupRoot.appendingPathComponent(id, isDirectory: true)
        let dataDir = backupDir.appendingPathComponent("data", isDirectory: true)
        let manifestPath = backupDir.appendingPathComponent("manifest.json")
        try Self.requireRegularDirectory(backupRoot)
        try Self.requireRegularDirectory(backupDir)
        try Self.requireRegularDirectory(dataDir)
        try Self.requireRegularFile(manifestPath, maximumBytes: 16 * 1024 * 1024)

        let manifestData = try Data(contentsOf: manifestPath, options: [.mappedIfSafe])
        let manifest = try JSONValue.parse(manifestData)
        guard case .object(let object) = manifest,
              object["app"] == .string("NativeAgent"),
              object["kind"] == .string("backup"),
              object["id"] == .string(id),
              object["integrityVersion"] == .int(2),
              object["scopeVersion"] == .int(3),
              case .string(let personaPath)? = object["personaRoot"],
              case .string(let lifeID)? = object["lifeID"],
              UUID(uuidString: lifeID)?.uuidString.lowercased() == lifeID,
              case .string(let reason)? = object["reason"],
              case .string(let createdAt)? = object["createdAt"],
              case .array(let copiedValues)? = object["copied"],
              case .array(let fileValues)? = object["files"],
              case .array(let linkValues)? = object["links"], linkValues.count <= 10_000 else {
            throw Self.backupError(
                code: 422,
                "Backup manifest is missing its current identity, persona destination or integrity contract. Create a complete current NativeAgent backup."
            )
        }
        guard reason.utf8.count <= 1_000, createdAt.utf8.count <= 128 else {
            throw Self.backupError(code: 422, "Backup manifest metadata exceeds its bound.")
        }
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: root).standardizedFileURL
        guard personaPath == personaRoot.path else {
            throw Self.backupError(code: 422, "Backup persona destination differs from the live persona owner: \(personaRoot.path)")
        }

        var links: [NativeBackupLink] = []
        for value in linkValues {
            guard case .object(let link) = value,
                  case .string(let path)? = link["path"],
                  case .string(let target)? = link["target"],
                  Self.isValidBackupFilePath(path),
                  !target.isEmpty, target.utf8.count <= 4_096,
                  // Case-folded: on a case-insensitive volume `A` and `a/b` overlap, and recreating one would write through the
                  // other.
                  !links.contains(where: {
                      let (a, b) = ($0.path.lowercased(), path.lowercased())
                      return NativeAgentWorkspaceRoot.relativePath(b, under: a) != nil || NativeAgentWorkspaceRoot.relativePath(a, under: b) != nil
                  }) else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid or overlapping link.")
            }
            links.append(NativeBackupLink(path: path, target: target))
        }

        let allowed = Set(Self.backupRelativePaths)
        var copied: [String] = []
        var copiedSet: Set<String> = []
        for value in copiedValues {
            guard case .string(let path) = value,
                  allowed.contains(path),
                  copiedSet.insert(path).inserted else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid or duplicate scope member.")
            }
            let copiedSource = dataDir.appendingNativeRelativePath(path)
            guard Self.pathEntryExists(copiedSource) else {
                throw Self.backupError(code: 422, "Backup manifest names a scope member that is absent: \(path)")
            }
            let scopeValues = try copiedSource.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard scopeValues.isSymbolicLink != true,
                  scopeValues.isDirectory == true || scopeValues.isRegularFile == true else {
                throw Self.backupError(code: 422, "Backup manifest names a non-regular scope member: \(path)")
            }
            copied.append(path)
        }
        // Links live only below `memory/` (`memory/agent/notes.jsonl` points into the persona root): restore's effect-fence
        // overlays and authority checks never touch Memory, so none reads or writes through a recreated link.
        for link in links {
            guard link.path.hasPrefix("memory/"), copied.contains("memory"),
                  !Self.pathEntryExists(dataDir.appendingNativeRelativePath(link.path)),
                  Self.isBackupLinkTargetInside(link, dataRoot: root) else {
                throw Self.backupError(
                    code: 422,
                    "Backup link must sit under memory/ and point inside the data or persona root: \(link.path) -> \(link.target)"
                )
            }
        }

        guard fileValues.count <= 100_000 else {
            throw Self.backupError(code: 422, "Backup manifest contains too many files.")
        }
        var files: [NativeBackupIntegrityFile] = []
        var filePaths: Set<String> = []
        for value in fileValues {
            guard case .object(let file) = value,
                  case .string(let path)? = file["path"],
                  case .int(let sizeBytes)? = file["sizeBytes"],
                  case .string(let sha256)? = file["sha256"],
                  sizeBytes >= 0,
                  Self.isValidBackupFilePath(path),
                  Self.isValidSHA256(sha256),
                  copied.contains(where: { NativeAgentWorkspaceRoot.relativePath(path, under: $0) != nil }),
                  filePaths.insert(path).inserted else {
                throw Self.backupError(code: 422, "Backup manifest has an invalid file member.")
            }
            files.append(NativeBackupIntegrityFile(
                path: path,
                sizeBytes: sizeBytes,
                sha256: sha256
            ))
        }

        let actualFiles = try Self.backupIntegrityFiles(in: dataDir)
        guard actualFiles == files.sorted(by: { $0.path < $1.path }) else {
            throw Self.backupError(
                code: 422,
                "Backup file membership or SHA-256 integrity does not match its manifest."
            )
        }

        guard copied.contains("persona") else {
            throw Self.backupError(code: 422, "Backup does not contain the live persona scope.")
        }
        try Self.requireRegularDirectory(dataDir.appendingPathComponent("persona"))
        try Self.requireRegularFile(dataDir.appendingPathComponent("persona/SOUL.md"), maximumBytes: nil)
        if requireRestorableAuthority {
            guard copied.contains("abilities"), copied.contains("chat/sessions.json") else {
                throw Self.backupError(code: 422, "Restore requires captured current abilities and session index scopes; no restore was staged or current data replaced.")
            }
            try Self.requireRegularDirectory(dataDir.appendingPathComponent("abilities"))
            try Self.validateBackupChatSessionIndex(dataDir: dataDir)
            _ = try Self.requiredTranscriptGenerationFloor(in: dataDir)
            try Self.validateBackupTrustPolicy(dataDir: dataDir)
            try Self.validateBackupCapabilityAuthority(dataDir: dataDir)
        }
        return NativeValidatedBackupSnapshot(
            id: id,
            dataDirectory: dataDir,
            copied: copied,
            files: actualFiles,
            links: links,
            reason: reason,
            createdAt: createdAt,
            manifestSHA256: Self.sha256Hex(manifestData)
        )
    }

    static func backupIntegrityFiles(in root: URL) throws -> [NativeBackupIntegrityFile] {
        try Self.requireRegularDirectory(root)
        let entries = try Self.backupEntries(in: root)
        var files: [NativeBackupIntegrityFile] = []
        for item in entries {
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw Self.backupError(code: 422, "Backup contains a symbolic link: \(item.lastPathComponent)")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw Self.backupError(code: 422, "Backup contains a non-regular file: \(item.lastPathComponent)")
            }
            guard let relative = NativeAgentWorkspaceRoot.relativePath(item.standardizedFileURL.path, under: root.standardizedFileURL.path), !relative.isEmpty else {
                throw Self.backupError(code: 422, "Backup member escapes its data directory.")
            }
            guard Self.isValidBackupFilePath(relative) else {
                throw Self.backupError(code: 422, "Backup contains an invalid relative path.")
            }
            // A regular sidecar coordinates writers; it is never snapshot data.
            if item.lastPathComponent.hasSuffix(".lock") { continue }
            let digest = try Self.fileDigest(item)
            files.append(NativeBackupIntegrityFile(
                path: relative,
                sizeBytes: digest.sizeBytes,
                sha256: digest.sha256
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// No caller can mistake a stopped enumeration for a complete inventory.
    static func backupEntries(in root: URL) throws -> [URL] {
        try Self.requireRegularDirectory(root)
        let failure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                failure.withLock { $0 = error }
                return false
            }
        ) else {
            throw Self.backupError(code: 422, "Backup contents could not be enumerated: \(root.path)")
        }
        var entries: [URL] = []
        for case let item as URL in enumerator { entries.append(item) }
        if let error = failure.withLock({ $0 }) { throw error }
        return entries
    }

    static func fileDigest(_ path: URL) throws -> (sizeBytes: Int64, sha256: String) {
        try VolumeIO.requireReadyForReading(path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func backupIntegrityFileJSON(_ file: NativeBackupIntegrityFile) -> JSONValue {
        .object([
            "path": .string(file.path),
            "sizeBytes": .int(file.sizeBytes),
            "sha256": .string(file.sha256),
        ])
    }

    static func backupLinkJSON(_ link: NativeBackupLink) -> JSONValue {
        .object(["path": .string(link.path), "target": .string(link.target)])
    }

    /// Copies a link as a link (its raw target, never its bytes); `takeBackupLinks` then moves it from `data/` into the
    /// manifest.
    static func copyBackupLink(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: fm.destinationOfSymbolicLink(atPath: source.path)
        )
    }

    /// Removes every link copied into a backup's `data/` and returns them for the manifest, so the sealed bytes stay regular
    /// files only.
    static func takeBackupLinks(in dataDir: URL) throws -> [NativeBackupLink] {
        let fm = FileManager.default
        let entries = try Self.backupEntries(in: dataDir)
        let rootPath = dataDir.standardizedFileURL.path
        var links: [NativeBackupLink] = []
        for item in entries
        where try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            guard let relative = NativeAgentWorkspaceRoot.relativePath(item.standardizedFileURL.path, under: rootPath), !relative.isEmpty else {
                throw Self.backupError(code: 422, "Backup link escapes its data directory.")
            }
            links.append(NativeBackupLink(
                path: relative,
                target: try fm.destinationOfSymbolicLink(atPath: item.path)
            ))
        }
        for link in links {
            try fm.removeItem(atPath: rootPath + "/" + link.path)
        }
        return links.sorted { $0.path < $1.path }
    }

    /// A recorded link, resolved from where it lives in the data root, must land inside the data root or the live persona root.
    private static func isBackupLinkTargetInside(_ link: NativeBackupLink, dataRoot root: URL) -> Bool {
        let base = root.appendingNativeRelativePath(link.path).deletingLastPathComponent()
        let target = link.target.hasPrefix("/")
            ? URL(fileURLWithPath: link.target)
            : base.appendingPathComponent(link.target)
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
        return [root, PersistenceCore.defaultPersonaRoot(dataRoot: root)].contains {
            let allowed = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return NativeAgentWorkspaceRoot.relativePath(resolved, under: allowed) != nil
        }
    }

    static func requireRegularDirectory(_ path: URL) throws {
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw Self.backupError(code: 422, "Backup path is not a regular directory: \(path.lastPathComponent)")
        }
    }

    static func pathEntryExists(_ path: URL) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == 0
    }

    static func requireRegularFile(_ path: URL, maximumBytes: Int?) throws {
        let values = try path.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw Self.backupError(code: 422, "Backup path is not a regular file: \(path.lastPathComponent)")
        }
        if let maximumBytes {
            guard let size = values.fileSize, size >= 0, size <= maximumBytes else {
                throw Self.backupError(code: 422, "Backup file exceeds its size bound: \(path.lastPathComponent)")
            }
        }
    }

    private static func isValidBackupFilePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              path.utf8.count <= 4_096 else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func backupError(code: Int, _ description: String) -> NSError {
        NSError(domain: "NativeAgentBackup", code: code, userInfo: [
            NSLocalizedDescriptionKey: description,
        ])
    }

    public static func writeCodableJSON<T: Encodable>(_ value: T, to path: URL) throws {
        let json = try JSONValue.fromEncodable(value)
        try writeJSONValue(json, to: path)
    }

    public static func writeJSONValue(_ value: JSONValue, to path: URL) throws {
        let data = try value.serializedData(pretty: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
    }

    private static func validateBackupChatSessionIndex(dataDir: URL) throws {
        for file in try ChatSessionRetention.archivedTranscripts(dataRoot: dataDir).values.flatMap({ $0 }) {
            try Self.requireRegularFile(file, maximumBytes: nil)
        }
        let source = dataDir.appendingNativeRelativePath("chat/sessions.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        _ = try ChatSessionIndexFile.loadObjectRowsForMutation(at: source)
    }

    private static func validateBackupTrustPolicy(dataDir: URL) throws {
        let source = dataDir.appendingNativeRelativePath("trust/policy.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let defaults = SwiftNativeTrustCenter(dataRoot: dataDir).defaultTrustPolicy()
        _ = try SwiftNativeTrustCenter.loadRawPolicyChecked(at: source, defaults: defaults)
    }

    private static func validateBackupCapabilityAuthority(dataDir: URL) throws {
        guard FileManager.default.fileExists(atPath: dataDir.path) else { return }
        let sources = dataDir.appendingNativeRelativePath("catalog/sources/sources.json")
        let roots = dataDir.appendingNativeRelativePath("catalog/trust/roots.json")
        _ = try CapabilityCatalogStoreReader.loadCatalogSourcesChecked(at: sources)
        _ = try CapabilityCatalogStoreReader.loadCapabilityTrustRootsChecked(at: roots)
    }
}
