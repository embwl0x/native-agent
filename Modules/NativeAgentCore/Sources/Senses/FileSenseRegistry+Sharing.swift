import Foundation
import PersistenceCore
// Blueprint: | `FileSenseRegistry+Sharing.swift` | Approval-gated portable code/record export |

extension FileSenseRegistry {
    /// Export only explicitly manifested source and metadata; the directory and notebook are private.
    struct Bundle: Encodable, Sendable {
        var format = 1
        var record: SenseRecord
        var codeFiles: [String: Data]
    }

    public func exportBundle(id: String, to destination: URL, userApproved: Bool = false) async throws -> SenseExportResult {
        try await withStore { store in
            let version = store.senses[try Self.index(id, in: store)].current
            guard version.record.language != .native else { throw Self.failure("Built-in native code cannot be shared as a portable sense.") }
            guard userApproved else { return (false, .approvalNeeded(senseID: id)) }
            if let failure = version.sourceFailure { throw Self.failure(failure) }
            guard let names = version.files else { throw Self.failure("Sense source membership has not been checked.") }
            let files = try self.sourceFiles(version.record).filter { names.contains($0.key) }
            var record = version.record
            // Local paths and usage history must not travel with code.
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
            guard NativeAgentWorkspaceRoot.relativePath(resolved.path, under: dataRoot.path) == nil else {
                throw Self.failure("Export destination must be outside the private data root.")
            }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw Self.failure("Export destination already exists.") }
            _ = try Self.safeURL(target.lastPathComponent, under: target.deletingLastPathComponent())
            // Hard links publish atomically without replacement; Foundation cannot combine atomic and withoutOverwriting options.
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
