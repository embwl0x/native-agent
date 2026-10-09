import Foundation

extension FileSenseRegistry {
    static let maximumBundleBytes = 8_000_000
    static let maximumCodeBytes = 4_000_000
    private static let forbiddenComponents: Set<String> = ["data", "persona", "ledger", "wall-ledger", "secrets", "credentials"]

    static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
            throw failure("Sense id must contain only letters, digits, hyphens and underscores.")
        }
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, path.utf8.count <= 512, !path.contains("\\"), !path.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !forbiddenComponents.contains($0.lowercased()) }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw failure("Sense code path is unsafe or names private material.")
        }
    }

    static func validateCode(_ path: String, bytes: Data) throws {
        try validatePath(path)
        guard ["js", "swift"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              bytes.count <= maximumCodeBytes, !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else {
            throw failure("A sense bundle may contain only bounded UTF-8 JavaScript or Swift source files.")
        }
    }

    static func validate(_ version: Version) throws {
        let record = version.record
        try validateID(record.id)
        guard record.version > 0, record.uses >= 0, record.corrections >= 0,
              record.createdAt.timeIntervalSince1970.isFinite,
              record.enabledAt?.timeIntervalSince1970.isFinite != false,
              record.lastUsedAt?.timeIntervalSince1970.isFinite != false,
              let corner = SenseCorner(key: record.corner.key), corner == record.corner,
              version.files.count <= 128,
              Set(version.files.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == version.files.count else {
            throw failure("Sense metadata or code manifest is invalid.")
        }
        for path in version.files { try validateCode(path, bytes: Data()) }
        if record.language == .native {
            guard record.origin == .builtIn, record.entry == nil, version.files.isEmpty else {
                throw failure("Native senses must be built-in and have no portable entry file.")
            }
        } else {
            guard let entry = record.entry, version.files.contains(entry),
                  URL(fileURLWithPath: entry).pathExtension.lowercased() == (record.language == .javascript ? "js" : "swift") else {
                throw failure("Sense entry file is missing from its code manifest or has the wrong language.")
            }
        }
    }

    static func validate(_ store: Store) throws {
        guard store.format == 1, Set(store.senses.map { $0.id.lowercased() }).count == store.senses.count else { throw failure("Unsupported or duplicate sense registry records.") }
        var activeCorners: Set<String> = []
        for entry in store.senses {
            try validateID(entry.id)
            guard !entry.versions.isEmpty,
                  Set(entry.versions.map(\.record.version)).count == entry.versions.count,
                  entry.versions.contains(where: { $0.record.version == entry.currentVersion }) else {
                throw failure("Sense registry has invalid version history.")
            }
            for version in entry.versions {
                guard version.record.id == entry.id else { throw failure("Sense version belongs to a different id.") }
                try validate(version)
            }
            let record = entry.versions.first { $0.record.version == entry.currentVersion }!.record
            if record.status == .on, !activeCorners.insert(record.corner.key).inserted { throw failure("More than one sense is on for the same corner.") }
        }
    }

    /// Reject symlinks in the owned root and every existing path component.
    /// Missing paths are allowed for publication; other filesystem errors propagate.
    static func safeURL(_ relative: String, under root: URL) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw failure("Sense storage path escapes its root.")
        }
        var current = root
        for component in [""] + relative.split(separator: "/").map(String.init) {
            if !component.isEmpty { current.appendPathComponent(component) }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw failure("Sense storage cannot follow symbolic links.") }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                continue
            }
        }
        return current
    }

    static func readCode(at path: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumCodeBytes else {
            throw failure("Sense source must be a bounded regular file.")
        }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= maximumCodeBytes else { throw failure("Sense source exceeds the size limit.") }
        return bytes
    }

    static func readSourceFiles(at folder: URL) throws -> [String: Data] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw failure("Sense code folder cannot be read.")
        }
        var files: [String: Data] = [:]
        var total = 0
        for case let path as URL in enumerator {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw failure("Sense code folder contains a symbolic link.") }
            if values.isDirectory == true {
                if forbiddenComponents.contains(path.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, ["js", "swift"].contains(path.pathExtension.lowercased()) else { continue }
            let name = String(path.path.dropFirst(folder.path.count + 1))
            let bytes = try readCode(at: path)
            try validateCode(name, bytes: bytes)
            total += bytes.count
            guard files.count < 128, total <= maximumCodeBytes else { throw failure("Sense source exceeds the size limit.") }
            files[name] = bytes
        }
        if let enumerationError { throw enumerationError }
        return files
    }
}
