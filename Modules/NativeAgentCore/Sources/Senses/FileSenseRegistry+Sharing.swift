import Foundation
// Blueprint: | `FileSenseRegistry+Sharing.swift` | Approval-gated portable code/record export |

extension FileSenseRegistry {
    /// A single portable JSON bundle: metadata plus explicitly manifested source,
    /// never a recursive copy of the sense directory or its notebook.
    struct Bundle: Encodable, Sendable {
        var format = 1
        var record: SenseRecord
        var codeFiles: [String: Data]
    }

    public func exportBundle(id: String, to destination: URL, userApproved: Bool = false) async throws -> SenseExportResult {
        try await withStore { store in
            let (i, j) = try Self.current(id, in: store)
            let version = store.senses[i].versions[j]
            guard version.record.language != .native else { throw Self.failure("Built-in native code cannot be shared as a portable sense.") }
            guard userApproved else { return (false, .approvalNeeded(senseID: id)) }
            let files = try self.sourceFiles(version.record).filter { version.files.contains($0.key) }
            var record = version.record
            // Local paths and usage history do not travel with code.
            record.reach.readPaths = []
            record.uses = 0
            record.corrections = 0
            record.lastUsedAt = nil
            record.enabledAt = nil
            record.grownBecause = nil
            record.unavailableReason = nil
            record.candidateDigest = nil
            record.disabledBy = nil
            let bytes = try Self.encode(Bundle(record: record, codeFiles: files))
            guard bytes.count <= Self.maximumBundleBytes else { throw Self.failure("Sense bundle exceeds the size limit.") }
            let target = destination.standardizedFileURL
            let resolved = target.resolvingSymlinksInPath()
            let dataRoot = self.root.deletingLastPathComponent()
            guard resolved.path != dataRoot.path, !resolved.path.hasPrefix(dataRoot.path + "/") else {
                throw Self.failure("Export destination must be outside the private data root.")
            }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw Self.failure("Export destination already exists.") }
            _ = try Self.safeURL(target.lastPathComponent, under: target.deletingLastPathComponent())
            // A hard link publishes the completed file atomically and refuses
            // replacement. Foundation's atomic and withoutOverwriting write
            // options cannot be combined.
            let stage = target.deletingLastPathComponent().appendingPathComponent(".sense-export-\(UUID().uuidString)")
            do {
                try bytes.write(to: stage, options: .withoutOverwriting)
                try FileManager.default.linkItem(at: stage, to: target)
                try FileManager.default.removeItem(at: stage)
            } catch {
                if FileManager.default.fileExists(atPath: stage.path) {
                    do { try FileManager.default.removeItem(at: stage) }
                    catch { Self.report(error) }
                }
                throw error
            }
            return (false, .exported(target))
        }
    }
}
