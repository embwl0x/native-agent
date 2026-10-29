import Foundation
import Darwin
// Blueprint: | `WorkshopReservationDurability.swift` | `WorkshopReservationDurability` canonical reservation and receipt file/directory fsync boundary |

public enum WorkshopReservationDurability {
    public static func flush(_ path: URL) -> Bool {
        let fd = Darwin.open(path.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { return false }
        // The reservation is not durable if the op bytes survive but the
        // canonical feed's directory entry does not. This also fails closed on
        // a symlinked parent instead of crossing the provider boundary through
        // an attacker-controlled path.
        return flushDirectory(path.deletingLastPathComponent())
    }

    static func flushDirectory(_ path: URL) -> Bool {
        let fd = Darwin.open(path.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return Darwin.fsync(fd) == 0
    }
}
