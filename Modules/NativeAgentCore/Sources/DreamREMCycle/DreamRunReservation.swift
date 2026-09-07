import Foundation
import Darwin

/// Exclusive, crash-safe reservation for a dream run (2026-09-06). Same
/// `<target>.lock` + nonblocking `flock` shape the rest of the tree uses; the
/// lock lives on the open file description, so a second runner in THIS process
/// conflicts with the first exactly as another process would, and a crash
/// releases it without leaving a stale claim file to clear by hand.
///
/// 2026-09-06: module-internal (was private) so the weekly REM pass takes the
/// same reservation — a forced manual REM and the scheduled one could otherwise
/// distil the same dreams concurrently.
struct DreamRunReservation {
    private let fd: Int32

    /// nil when another run holds the reservation. Throws only when the lock
    /// file cannot be opened or flock fails for a reason other than contention.
    static func acquire(at path: URL) throws -> DreamRunReservation? {
        let fd = Darwin.open(path.path, O_CREAT | O_WRONLY, 0o600)
        if fd < 0 {
            throw NSError(
                domain: "DreamRunReservation",
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open lock failed: \(String(cString: strerror(errno)))",
                ]
            )
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return DreamRunReservation(fd: fd)
        }
        let lockError = errno
        Darwin.close(fd)
        if lockError == EWOULDBLOCK { return nil }
        throw NSError(
            domain: "DreamRunReservation",
            code: Int(lockError),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "flock LOCK_EX failed: \(String(cString: strerror(lockError)))",
            ]
        )
    }

    func release() {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
