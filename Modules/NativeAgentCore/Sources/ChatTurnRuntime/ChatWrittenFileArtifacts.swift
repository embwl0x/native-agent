import Foundation
import CryptoKit
import UniformTypeIdentifiers
import PersistenceCore
import ChatToolRuntime

/// Whole-file write receipts shared by live delivery and canonical recovery,
/// and what a turn left changed in the world.
public enum ChatWrittenFileArtifacts {
    public struct File {
        public let name: String
        public let mime: String
        public let bytes: Data
        public let reference: JSONValue
    }

    public static func files(from dispatches: [TurnEngineResult.ToolDispatchRecord],
                             maximumBytes: Int = 10_000_000) -> [File] {
        dispatches.compactMap { dispatch in
            guard dispatch.ranCall.tool == "write_file" else { return nil }
            let input = dispatch.ranCall.input
            guard case .object(let receipt) = dispatch.result, receipt["ok"] == .bool(true),
                  receipt["append"] == .bool(false), case .string(let content)? = input["content"],
                  receipt["bytes_written"] == .int(Int64(content.utf8.count)),
                  case .string(let path)? = input["path"], content.utf8.count <= maximumBytes else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let bytes = Data(content.utf8)
            var reference: [String: JSONValue] = [
                "type": .string("file"), "name": .string(name), "mime": .string(mime),
                "byteSize": .int(Int64(bytes.count)),
                "sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()),
            ]
            // Use the writer's resolved path, never the input's relative alias.
            // A missing reference remains visible to recovery as incomplete.
            if case .string(let savedPath)? = receipt["path"], savedPath.hasPrefix("/") {
                reference["path"] = .string(savedPath)
            }
            return File(name: name, mime: mime, bytes: bytes, reference: .object(reference))
        }
    }

    /// What the turn left changed on disk, read as it closes: the files
    /// modified since it started in each folder one of her own landed writes
    /// put a file in (from its receipt, a part's or script's own calls
    /// included; a shell call's is its directory), whoever wrote them, so the
    /// render another app made beside her file is in it too. A folder counts only
    /// where her file-read policy reaches, links resolved, and never her data
    /// root; hidden files are no news. A folder too big to list, or one that
    /// can't be read, says so. Newest first.
    public static func world(from dispatches: [TurnEngineResult.ToolDispatchRecord], since: Date, dataRoot: URL) async -> JSONValue? {
        var folders: [String] = [], unlisted: [String] = []
        func landed(_ folder: String) { if !folders.contains(folder) { folders.append(folder) } }
        /// A landed write's place: its file's folder, or a shell call's directory.
        func place(_ fields: [String: JSONValue]) -> Bool {
            if case .string(let path)? = fields["destination"] ?? fields["path"], path.hasPrefix("/") {
                landed(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                return true
            }
            guard case .string(let cwd)? = fields["cwd"], cwd.hasPrefix("/") else { return false }
            landed(cwd)
            return true
        }
        /// A receipt, a list's members, and a part or script run's own calls,
        /// each from its own receipt; a run whose writes can't be placed says so.
        func collect(_ value: JSONValue) {
            guard case .object(let receipt) = value else { return }
            if case .array(let members)? = receipt["receipts"] { return members.forEach(collect) }
            guard ChatToolOutcome.outputLooksSuccessful(value) || receipt["calls"] != nil, !ChatToolOutcome.isWaitingOnPerson(value),
                  receipt["status"] != .string("preview"), receipt["execution"] != .string("preview") else { return }
            if receipt["read_only"] == .bool(false), place(receipt) { return }
            let run = if case .string(let skill)? = receipt["skill"] { skill + " run" } else { "a script run" }
            guard case .array(let calls)? = receipt["calls"] else {
                if receipt["run_id"] != nil, receipt["effects"] != .string("none") {
                    unlisted.append(run)
                }
                return
            }
            for case .object(let row) in calls where row["status"] == .string("ok") && row["read_only"] == .bool(false) {
                if case .object(let at)? = row["at"], place(at) { continue }
                if case .object(let result)? = row["result"], place(result) { continue }
                // A write with no place on its row: its effects don't say where.
                if row["effects"] != .string("none"), !unlisted.contains(run) { unlisted.append(run) }
            }
        }
        for dispatch in dispatches where dispatch.ranCall.input["preview"] != .bool(true) { collect(dispatch.result) }
        let policy = SwiftToolDispatcher(dataRoot: dataRoot, allowProcessGlobalTools: false)
        let own = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        var changed: [(Date, JSONValue)] = [], notes: [JSONValue] = []
        func note(_ path: String, _ words: String) { notes.append(.object(["path": .string(path), "note": .string(words)])) }
        // One budget for the whole capture: each folder opened, each raw entry
        // read and each entry's metadata cost one; what it can't reach says so.
        var budget = captureBudget
        for written in folders {
            guard budget > 0 else { note(written, "not listed: this turn's listing ran out of budget"); continue }
            guard let folder = try? await policy.resolveTrustedFilePath(written), folder.path != own,
                  !folder.path.hasPrefix(own + "/") else { continue }
            budget -= 1
            // The folder admitted, listed through its verified descriptor: no
            // component, and no entry, is followed if it became a link.
            let descriptor: Int32
            do { descriptor = try VerifiedPath.open(folder, flags: O_RDONLY | O_DIRECTORY) }
            catch let failure as VerifiedPath.Failure { note(folder.path, "unavailable: " + failure.message); continue }
            catch { note(folder.path, "unavailable: " + error.localizedDescription); continue }
            guard let directory = fdopendir(descriptor) else {
                note(folder.path, "unavailable: " + String(cString: strerror(errno)))
                close(descriptor)
                continue
            }
            defer { closedir(directory) }
            errno = 0
            while let pointer = readdir(directory) {
                budget -= 1
                guard budget > 0 else { note(folder.path, "partly listed: this turn's listing ran out of budget"); break }
                var raw = pointer.pointee.d_name
                let name = withUnsafePointer(to: &raw) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard !name.hasPrefix(".") else { continue }
                budget -= 1
                let path = folder.appendingPathComponent(name).path
                var metadata = stat()
                guard fstatat(dirfd(directory), name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    note(path, "unavailable: " + String(cString: strerror(errno)))
                    errno = 0
                    continue
                }
                let modified = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1e9)
                guard modified >= since else { continue }
                var entry: [String: JSONValue] = ["path": .string(path), "modified": .string(ISO8601DateFormatter().string(from: modified))]
                if metadata.st_mode & S_IFMT == S_IFDIR { entry["folder"] = .bool(true) }
                else if metadata.st_mode & S_IFMT == S_IFREG { entry["bytes"] = .int(Int64(metadata.st_size)) }
                changed.append((modified, .object(entry)))
            }
            if errno != 0, budget > 0 { note(folder.path, "unavailable: " + String(cString: strerror(errno))) }
        }
        for run in unlisted { note(run, "writes not listed") }
        let all = changed.sorted { $0.0 > $1.0 }.prefix(16).map(\.1) + notes
        return all.isEmpty ? nil : .array(all)
    }

    /// What one turn's capture may spend: folders opened, raw entries read, metadata read.
    static let captureBudget = 2000
}
