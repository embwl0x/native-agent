import Foundation

extension FileSenseRegistry {
    /// A single portable JSON bundle: metadata plus explicitly manifested source,
    /// never a recursive copy of the sense directory or its notebook.
    struct Bundle: Codable, Sendable {
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
            let folder = try Self.safeURL("\(id)/v\(version.record.version)", under: self.root)
            var files: [String: Data] = [:]
            for name in version.files {
                let path = try Self.safeURL(name, under: folder)
                let bytes = try Self.readCode(at: path)
                try Self.validateCode(name, bytes: bytes)
                files[name] = bytes
            }
            var record = version.record
            // Local paths and usage history do not travel with code.
            record.reach.readPaths = []
            record.uses = 0
            record.corrections = 0
            record.lastUsedAt = nil
            record.enabledAt = nil
            record.grownBecause = nil
            record.unavailableReason = nil
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

    public func importBundle(from bundle: URL) async throws -> SenseRecord {
        let path = try Self.safeURL(bundle.lastPathComponent, under: bundle.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBundleBytes else {
            throw Self.failure("Sense bundle must be a regular file within the size limit.")
        }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= Self.maximumBundleBytes else { throw Self.failure("Sense bundle exceeds the size limit.") }
        let imported = try JSONDecoder().decode(Bundle.self, from: bytes)
        guard imported.format == 1, imported.record.language != .native else { throw Self.failure("Unsupported portable sense bundle.") }
        try Self.validate(Version(record: imported.record, files: imported.codeFiles.keys.sorted()))
        return try await withStore { store in
            if let i = store.senses.firstIndex(where: { $0.id == imported.record.id }) {
                let j = store.senses[i].versions.firstIndex { $0.record.version == store.senses[i].currentVersion }!
                guard store.senses[i].versions[j].record.origin == .shared,
                      store.senses[i].versions[j].record.corner.key == imported.record.corner.key else {
                    throw Self.failure("Import would replace a locally owned sense or a different corner.")
                }
            }
            var record = imported.record
            record.origin = .shared
            record.status = .on
            record.unavailableReason = nil
            record.createdAt = Date()
            record.reach.readPaths = []
            record.grownBecause = nil
            // insert clears the imported usage claims. Verbs remain disabled
            // until the runner records this version's first successful local read.
            return (true, try self.insert(record, files: imported.codeFiles, into: &store))
        }
    }
}
