import Foundation
import Darwin
// Blueprint: | `DataRootLife.swift` | `DataRootLife`; one root life-id, created once when absent as their first life (`first`) and replaced by the restore intent's UUID; `life(of:)` reads a missing stamp as the first life, so an upgrade never reads as a restore; resumable owners stamp at beginning and admit only that life, projecting work from another life stopped with reason restored |

/// A restore brings back what she had, never what she was doing.
/// Resumable owners retain the life in which work began, never adopt it on read.
public enum DataRootLife {
    public static let stoppedReason = "restored"
    /// Her first life. Work saved before lives were stamped began in it, so an
    /// upgrade never reads as a restore; only a restore starts a new life.
    public static let first = "00000000-0000-0000-0000-000000000000"

    /// The life a stamp names; no stamp is her first life.
    public static func life(of stamp: String?) -> String { stamp ?? first }

    public static func current(in root: URL) throws -> String {
        let path = root.appendingPathComponent("life-id")
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let pending = root.appendingPathComponent(".life-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: pending) }
            try Data(first.utf8).write(to: pending, options: .withoutOverwriting)
            try sync(pending)
            if link(pending.path, path.path) == 0 { try sync(path) }
            else if errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == 36 else { throw CocoaError(.fileReadCorruptFile) }
        let id = try String(contentsOf: path, encoding: .utf8)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw CocoaError(.fileReadCorruptFile) }
        return id
    }

    public static func isCurrent(_ lifeID: String?, in root: URL) throws -> Bool {
        try current(in: root) == life(of: lifeID)
    }

    /// The durable restore intent supplies one new identity across interrupted installation.
    public static func begin(in root: URL, id: UUID) throws {
        let path = root.appendingPathComponent("life-id")
        try Data(id.uuidString.lowercased().utf8).write(to: path, options: .atomic)
        try sync(path)
    }

    private static func sync(_ path: URL) throws {
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.synchronize()
        let directory = open(path.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
