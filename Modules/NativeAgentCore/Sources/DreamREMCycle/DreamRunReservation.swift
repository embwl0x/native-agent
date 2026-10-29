import Foundation
import Darwin
// Blueprint: | `DreamRunReservation.swift` | `DreamRunReservation` struct; `acquire`, `release` |

/// Dream and REM reservations exclude same-process and cross-process runners; crashes release flock.
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
