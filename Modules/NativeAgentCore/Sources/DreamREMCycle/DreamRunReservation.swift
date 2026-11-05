import Foundation
import Darwin
// Blueprint: | `DreamRunReservation.swift` | `DreamRunReservation` struct; `acquire`, `release` |

/// Use process and cross-process exclusion; crashes release flock.
struct DreamRunReservation {
    private let fd: Int32

    /// Contention is nil; failed lock creation or noncontention flock errors throw.
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
