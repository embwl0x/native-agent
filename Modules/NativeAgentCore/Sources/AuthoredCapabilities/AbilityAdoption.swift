import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityAdoption.swift` | Verified legacy preparation, publication and archival |
extension AbilityStore {
    /// Prepare and read back every live selection before touching any old file.
    /// The presence of state.json commits the forward migration; archive moves
    /// resume on the next load if the process stopped during that final phase.
    public func migrate() throws {
        let fm = FileManager.default
        let legacy = [Legacy.tool, .skill, .sense].map { ($0, dataRoot.appendingPathComponent($0.rawValue + "s")) }
        if fm.fileExists(atPath: root.appendingPathComponent(".old-layout").path) {
            try Self.checkPath(root.appendingPathComponent(".old-layout"))
            guard fm.fileExists(atPath: root.appendingPathComponent("state.json").path) else {
                throw Self.failure("Ability migration archive exists without run state. Preserve the archive and restore abilities/state.json before loading abilities.")
            }
            return
        }
        guard fm.fileExists(atPath: root.appendingPathComponent(".old-layout.incoming").path)
            || legacy.contains(where: { fm.fileExists(atPath: $0.1.appendingPathComponent("registry.json").path) }) else { return }
        if fm.fileExists(atPath: root.appendingPathComponent("state.json").path) {
            try archiveLegacy(legacy)
            return
        }
        let (prepared, stats, _) = try prepareLegacy(legacy)
        try CapabilityLifecycle.requireWrite()
        if fm.fileExists(atPath: root.path), try !fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty {
            throw Self.failure("Ability migration found an incomplete abilities folder without state.json. Preserve it and repair the interrupted migration before retrying.")
        }
        let staging = dataRoot.appendingPathComponent(".abilities-incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (file, slot) in prepared {
            let destination = staging.appendingPathComponent(try path(id: file.id, slot: slot, pathExtension: file.pathExtension).lastPathComponent)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Self.encode(file), to: destination)
            guard try Self.decode(destination) == file else { throw Self.failure("Ability migration readback failed for \(file.kind.rawValue) \(file.id). Old layout was preserved.") }
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue.object(stats).serializedData(pretty: true), to: staging.appendingPathComponent("state.json"))
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.moveItem(at: staging, to: root)
        try archiveLegacy(legacy)
    }
    /// Every live row of the old layout's registries, read and prepared as
    /// ability files; nothing is written. Its ids are lowercased.
    private func prepareLegacy(_ legacy: [(Legacy, URL)]) throws -> (prepared: [(File, Slot)], stats: [String: JSONValue], ids: Set<String>) {
        let fm = FileManager.default
        var prepared: [(File, Slot)] = []
        var stats: [String: JSONValue] = [:]
        var ids: Set<String> = []
        for (kind, directory) in legacy {
            let registry = directory.appendingPathComponent("registry.json")
            guard fm.fileExists(atPath: registry.path) else { continue }
            let value: JSONValue
            do { value = try legacyJSON(registry) }
            catch { throw repairFailure(source: registry, detail: "Ability migration blocked for \(kind.rawValue) registry: \(error.localizedDescription) No abilities migrated.") }
            let rows = value.arrayValue ?? value.objectValue?[kind == .sense ? "senses" : kind.rawValue + "s"]?.arrayValue
            guard let rows else { throw Self.failure("Ability migration blocked: \(kind.rawValue) registry has no rows. Old storage was preserved.") }
            for value in rows {
                let id = value.objectValue?["id"]?.stringValue ?? "<missing id>"
                do {
                    guard let outer = value.objectValue, id != "<missing id>" else { throw Self.failure("Row has no id.") }
                    let row: [String: JSONValue]
                    let previous: [String: JSONValue]?
                    if kind == .sense {
                        let versions = try (outer["versions"]?.arrayValue ?? []).map { version -> [String: JSONValue] in
                            guard let record = version.objectValue?["record"]?.objectValue else {
                                throw Self.failure("A retained sense version has no readable record.")
                            }
                            return record
                        }
                        guard let selected = versions.first(where: { $0["version"] == outer["currentVersion"] }) else { throw Self.failure("Selected sense version is missing.") }
                        row = selected
                        previous = versions.filter { ($0["version"]?.integer ?? 0) < (selected["version"]?.integer ?? 0) }
                            .max { ($0["version"]?.integer ?? 0) < ($1["version"]?.integer ?? 0) }
                    } else { row = outer; previous = nil }
                    let status = (row["status"] ?? row["state"])?.stringValue ?? "active"
                    let ownerOff = CapabilityLifecycle.requiresOwnerToEnable(row)
                    if !ownerOff, ["retired", "archived", "trashed", "rejected", "quarantined"].contains(status)
                        || ["retired", "trashedAt", "droppedAt"].contains(where: { row[$0] != nil && row[$0] != .null }) { continue }
                    guard ids.insert(id.lowercased()).inserted else { throw Self.failure("Id collides with another live tool, skill or sense.") }
                    _ = try path(id: id)
                    stats[id] = .object(row.filter { Self.statistics.contains($0.key) })
                    if kind == .sense, row["language"] == .string("native"), status == "on", row["disabledBy"] == nil { continue }
                    if kind != .sense, let digest = row["candidateDigest"]?.stringValue, digest != row["codeFingerprint"]?.stringValue {
                        prepared.append((try legacyFile(kind: kind, id: id, row: row, directory: directory, digest: digest, slot: .next), .next))
                        if row["codeFingerprint"]?.stringValue == nil,
                           kind == .tool || row["script"]?.objectValue != nil || ["proposed", "draft", "drafted"].contains(status) { continue }
                    }
                    let current = try legacyFile(kind: kind, id: id, row: row, directory: directory)
                    prepared.append((current, .current))
                    if let previous {
                        prepared.append((try legacyFile(kind: kind, id: id, row: previous, directory: directory), .previous))
                    } else {
                        let selected = row["codeFingerprint"]?.stringValue
                        let digest = row["previousVersion"]?.stringValue
                            ?? current.metadata["candidate"]?.objectValue?["prior"]?.objectValue?["codeFingerprint"]?.stringValue
                            ?? row["versions"]?.arrayValue?.compactMap(\.stringValue).last(where: { $0 != selected })
                        if let digest {
                            var previous = try legacyFile(kind: kind, id: id, row: row, directory: directory, digest: digest)
                            if case .int(let version)? = current.metadata["version"] { previous.metadata["version"] = .int(max(1, version - 1)) }
                            if var fields = previous.metadata["record"]?.objectValue,
                               let selection = current.metadata["candidate"]?.objectValue?["prior"]?.objectValue,
                               selection["codeFingerprint"] == .string(digest) {
                                fields.merge(selection) { _, old in old }
                                previous.metadata["record"] = .object(fields)
                            }
                            prepared.append((previous, .previous))
                        }
                    }
                } catch {
                    throw repairFailure(source: registry, detail: "Ability migration blocked for \(kind.rawValue) \(id): \(error.localizedDescription) No abilities migrated; this row would lose its code or authority. The old layout was left untouched.")
                }
            }
        }
        return (prepared, stats, ids)
    }
    /// Prepare an older backup's abilities and readable uncarried kinds before
    /// restore changes anything. The restore seals these bytes and omissions.
    public func restoredLegacyCarry(backupRoot: URL) throws -> (files: [String: Data], notes: [String]) {
        try Self.withLock {
            let fm = FileManager.default
            let backup = AbilityStore(dataRoot: backupRoot)
            let returned = [Legacy.tool, .skill, .sense].map { ($0, backupRoot.appendingPathComponent($0.rawValue + "s")) }
                .filter { fm.fileExists(atPath: $0.1.appendingPathComponent("registry.json").path) }
            guard !returned.isEmpty else { return ([:], []) }
            let (prepared, stats, ids) = try backup.prepareLegacy(returned)
            let kinds = Set(returned.map { $0.0 == .sense ? Kind.sense : Kind.part })
            var notes: [String] = []
            let archive = root.appendingPathComponent(".old-layout")
            if let values = try? archive.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory != true || values.isSymbolicLink == true {
                notes.append("abilities/.old-layout: not a regular migration archive; current archive was not kept.")
            }
            var present: [(file: File, slot: Slot)] = []
            do {
                try VerifiedPath.confirmNoSymlink(root)
                present = try allFiles { url, error in
                    notes.append("abilities/\(url.lastPathComponent): \(error.localizedDescription); current ability was not kept.")
                }
            } catch {
                notes.append("abilities: \(error.localizedDescription); current abilities could not be enumerated and were not kept.")
            }
            var state: [String: JSONValue] = [:]
            do { state = try readState() }
            catch { notes.append("abilities/state.json: current run accounting could not be read or decoded; it was not kept.") }
            let replaced = present.filter { kinds.contains($0.file.kind) || ids.contains($0.file.id.lowercased()) }
            for entry in replaced where !kinds.contains(entry.file.kind) {
                notes.append("abilities/\(entry.file.id): its identity conflicts with the backup; current \(entry.file.kind.rawValue) was not kept.")
            }
            var files: [String: Data] = [:]
            for entry in present where !kinds.contains(entry.file.kind) && !ids.contains(entry.file.id.lowercased()) {
                do {
                    let source = try path(id: entry.file.id, slot: entry.slot, pathExtension: entry.file.pathExtension)
                    files["abilities/" + source.lastPathComponent] = try Data(contentsOf: source)
                } catch { notes.append("abilities/\(entry.file.id): \(error.localizedDescription); current ability was not kept.") }
            }
            for (file, slot) in prepared {
                let name = try backup.path(id: file.id, slot: slot, pathExtension: file.pathExtension).lastPathComponent
                files["abilities/" + name] = try Self.encode(file)
            }
            for entry in replaced { state.removeValue(forKey: entry.file.id) }
            state.merge(stats) { _, restored in restored }
            files["abilities/state.json"] = try JSONValue.object(state).serializedData(pretty: true)
            return (files, notes)
        }
    }
    /// Install only the sealed selection; current accounting is never reread.
    public func installRestoredLegacy(_ files: [String: Data], backupRoot: URL) throws {
        try Self.withLock {
            var selected = files.filter { $0.key.hasPrefix("abilities/") }
            if selected.isEmpty {
                selected = try AbilityStore(dataRoot: backupRoot).restoredLegacyCarry(backupRoot: backupRoot).files
            }
            guard !selected.isEmpty else { return }
            try CapabilityLifecycle.requireWrite()
            let fm = FileManager.default
            try VerifiedPath.confirmNoSymlink(root.deletingLastPathComponent())
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    let kept = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if child.lastPathComponent == ".old-layout", kept?.isDirectory == true, kept?.isSymbolicLink != true { continue }
                    try fm.removeItem(at: child)
                }
            } else if try Self.fileRevision(root) != "missing" { try fm.removeItem(at: root) }
            for (path, bytes) in selected {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: dataRoot.appendingPathComponent(path))
            }
            let legacy = [Legacy.tool, .skill, .sense].filter {
                fm.fileExists(atPath: backupRoot.appendingPathComponent($0.rawValue + "s/registry.json").path)
            }.map { ($0, dataRoot.appendingPathComponent($0.rawValue + "s")) }
            try archiveLegacy(legacy)
        }
    }
    /// The three stores of the layout before abilities/.
    enum Legacy: String { case tool, skill, sense }
    private func legacyFile(kind: Legacy, id: String, row input: [String: JSONValue], directory: URL, digest requested: String? = nil, slot: Slot = .current) throws -> File {
        var row = input
        var metadata: [String: JSONValue] = [:]
        let digest = requested ?? (kind == .sense ? row["candidateDigest"]?.stringValue : row["codeFingerprint"]?.stringValue)
        let body: String
        let ext: String
        if let digest {
            let owner = row["versionOwners"]?.objectValue?[digest]?.stringValue ?? id
            guard !owner.contains("/"), !digest.contains("/"), !digest.hasPrefix(".") else { throw Self.failure("Unsafe candidate identity.") }
            let folder = directory.appendingPathComponent("candidates/\(owner)/\(digest)")
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("candidate.json").path) {
                guard case .object(var candidate) = try legacyJSON(folder.appendingPathComponent("candidate.json")),
                      case .object(var program)? = candidate["program"], let source = program.removeValue(forKey: "source")?.stringValue else {
                    throw Self.failure("Candidate descriptor has no source.")
                }
                guard program["version"] == .string(digest), program["kind"] == .string(kind.rawValue) else {
                    throw Self.failure("Selected candidate identity or kind differs from its row.")
                }
                let sourceURL = folder.appendingPathComponent(kind.rawValue + ".js")
                try Self.checkPath(sourceURL)
                guard try Data(contentsOf: sourceURL) == Data(source.utf8),
                      try legacyJSON(folder.appendingPathComponent("manifest.json")) == candidate["manifest"],
                      try legacyJSON(folder.appendingPathComponent("tests.json")) == candidate["fixtures"] else {
                    throw Self.failure("Selected candidate source, manifest or fixtures changed.")
                }
                candidate["program"] = .object(program)
                if var manifest = candidate["manifest"]?.objectValue, var script = manifest["script"]?.objectValue {
                    script.removeValue(forKey: "source"); manifest["script"] = .object(script); candidate["manifest"] = .object(manifest)
                }
                metadata["candidate"] = .object(candidate)
                let proof = folder.appendingPathComponent("proof.json")
                if FileManager.default.fileExists(atPath: proof.path) { metadata["proof"] = try legacyJSON(proof) }
                body = source; ext = "js"
                if requested != nil, slot != .next, let manifest = candidate["manifest"]?.objectValue {
                    row = manifest
                    row["id"] = .string(id); row["codeFingerprint"] = .string(digest)
                    row["createdAt"] = input["createdAt"]; row["overrides"] = input["overrides"]
                    row["status"] = input["status"]; row["origin"] = input["origin"]
                    row["admission"] = candidate["prior"]?.objectValue?["admission"]
                    if kind == .skill, var script = row["script"]?.objectValue, let revision = input["actionPin"]?.objectValue?["interpreter"] {
                        script["source"] = .string(source)
                        let checksum = SHA256.hash(data: try JSONValue.object(script).serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
                        row["scriptDigest"] = .string(checksum)
                        row["actionPin"] = .object(["digest": .string(checksum), "actions": candidate["dependencyShapes"] ?? .object([:]), "interpreter": revision])
                    }
                }
            } else if kind == .skill, let source = row["script"]?.objectValue?["source"]?.stringValue, requested == nil {
                throw Self.failure("Selected executable skill has no readable candidate \(digest); its validation and admission cannot be preserved (\(source.utf8.count) source bytes).")
            } else { throw Self.failure("Candidate \(digest) is missing from \(owner).") }
        } else if kind == .sense {
            if row["language"] == .string("native") { body = ""; ext = "js" }
            else {
                guard let entry = row["entry"]?.stringValue, let version = row["version"]?.integer else { throw Self.failure("Sense has no entry or version.") }
                let folder = directory.appendingPathComponent("\(id)/v\(version)")
                let entryURL = try legacyRelative(entry, under: folder)
                guard let source = String(data: try Data(contentsOf: entryURL), encoding: .utf8) else { throw Self.failure("Sense source is not UTF-8.") }
                body = source; ext = "js"
                var auxiliary: [String: JSONValue] = [:]
                if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in enumerator where url.pathExtension == "js" && url != entryURL {
                        try Self.checkPath(url)
                        let name = NativeAgentWorkspaceRoot.relativePath(url.path, under: folder.path)!
                        auxiliary[name] = .string(try Data(contentsOf: url).base64EncodedString())
                    }
                }
                metadata["sourceFiles"] = .object(auxiliary)
            }
        } else if kind == .skill {
            let file = directory.appendingPathComponent("bodies/\(id).md")
            try Self.checkPath(file)
            guard let source = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw Self.failure("Skill guidance is not UTF-8.") }
            body = source; ext = "md"
        } else { throw Self.failure("Live tool has no selected candidate.") }
        let ownerOff = CapabilityLifecycle.requiresOwnerToEnable(input)
        if ownerOff || kind == .sense && row["status"] == .string("archived") {
            row["status"] = .string(kind == .sense ? "off" : "disabled")
            if row["state"] != nil { row["state"] = row["status"] }
            if row["phase"] != nil { row["phase"] = row["status"] }
            if ownerOff { row["disabledBy"] = .string("owner") }
        }
        row = row.filter { !Self.statistics.contains($0.key) && !Self.obsolete.contains($0.key) }
        if kind != .sense, slot != .next { for key in Self.pending { row.removeValue(forKey: key) } }
        if var script = row["script"]?.objectValue { script.removeValue(forKey: "source"); row["script"] = .object(script) }
        metadata["record"] = .object(row)
        if let version = input["version"] {
            guard case .int(let number) = version, number >= 1 else {
                throw Self.failure("Legacy ability version must be a positive integer. The old layout was preserved.")
            }
            metadata["version"] = version
        } else {
            metadata["version"] = .int(Int64(max(1, input["versions"]?.arrayValue?.count ?? 1)))
        }
        return try File(id: id, kind: kind == .sense ? .sense : .part, metadata: metadata, body: body, pathExtension: ext)
    }
    private func legacyJSON(_ url: URL) throws -> JSONValue {
        try Self.checkPath(url)
        return try JSONValue.parse(Data(contentsOf: url))
    }
    private func legacyRelative(_ name: String, under root: URL) throws -> URL {
        let path = root.appendingPathComponent(name).standardizedFileURL
        guard let tail = NativeAgentWorkspaceRoot.relativePath(path.path, under: root.path), !tail.isEmpty else { throw Self.failure("Legacy sense source escapes its directory.") }
        try Self.checkPath(path)
        return path
    }
    private func archiveLegacy(_ legacy: [(Legacy, URL)]) throws {
        let fm = FileManager.default
        let incoming = root.appendingPathComponent(".old-layout.incoming")
        for (kind, directory) in legacy {
            let archive = incoming.appendingPathComponent(kind.rawValue + "s")
            let originalRegistry = directory.appendingPathComponent("registry.json")
            let savedRegistry = archive.appendingPathComponent("registry.json")
            let registry = fm.fileExists(atPath: originalRegistry.path) ? originalRegistry : savedRegistry
            guard fm.fileExists(atPath: registry.path) else { continue }
            var names = ["registry.json.lock", "candidates", "proposals", "history", "bodies", "active", "quarantine", "by-id", "migrations"]
            if kind == .sense {
                names += [".trials"]
                for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    where try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    let versions = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil }
                    guard !versions.isEmpty else { continue }
                    for version in versions {
                        let destination = archive.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(version.lastPathComponent)
                        try Self.checkPath(version)
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: version, to: destination)
                    }
                    if try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty { try fm.removeItem(at: folder) }
                }
            }
            names.append("registry.json")
            for name in names {
                guard !name.contains("/"), name != ".", name != ".." else { throw Self.failure("Unsafe legacy storage name.") }
                let source = directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = archive.appendingPathComponent(name)
                guard !fm.fileExists(atPath: destination.path) else { throw Self.failure("Migration archive already contains \(kind.rawValue)s/\(name); preserve both copies and repair the interrupted move.") }
                try Self.checkPath(source)
                try fm.createDirectory(at: archive, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
            }
        }
        // A restored older layout is archived beside the first migration's.
        let archive = root.appendingPathComponent(".old-layout")
        if fm.fileExists(atPath: incoming.path) {
            try fm.moveItem(at: incoming, to: fm.fileExists(atPath: archive.path)
                ? archive.appendingPathComponent("restored-" + UUID().uuidString.lowercased()) : archive)
        }
    }
}
