import Foundation
import Synchronization

// Blueprint: | `MacDocumentReadTakeover.swift` | `MacDocumentReadTakeover.mark`: Physical takeover blocks later read-scroll emissions |

/// A bounded read observes physical input even without an explicit attention session. No permissions change; this only prevents later wheel emissions.
final class MacDocumentReadTakeover: Sendable {
    private let takenOver = Atomic(false)
    func mark() { takenOver.store(true, ordering: .releasing) }
    var occurred: Bool { takenOver.load(ordering: .acquiring) }
}
