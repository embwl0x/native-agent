import Foundation

// Blueprint: | `MacDocumentReadTakeover.swift` | `MacDocumentReadTakeover.mark`: physical-input takeover signal for bounded reads, preventing subsequent wheel emissions without changing permissions |

/// A bounded read observes physical input even without an explicit attention
/// session. No permissions change; this only prevents later wheel emissions.
final class MacDocumentReadTakeover: @unchecked Sendable {
    private let lock = NSLock()
    private var takenOver = false
    func mark() { lock.withLock { takenOver = true } }
    var occurred: Bool { lock.withLock { takenOver } }
}
