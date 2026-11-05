import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CryptoKit
import ApplicationServices
import CoreGraphics
import AppKit
import NativeAgentShared
import UserNotifications
import Experiences
import Senses
// Blueprint: | `MacActSerial.swift` | `MacActSerial`: FIFO acts/watch hands; release held input on transfer and pass raced slots |

/// Serialize process-wide because the target PID is known only after the first look and concurrent acts share real windows.
actor MacActSerial {
    static let shared = MacActSerial()
    private var busy = false
    private var waiters: [(UUID, ScopedWaiter)] = []
    private weak var inputOwner: MacDriverBinding?

    /// A new driver cannot inherit another watch's held keys or buttons.
    func ownInputs(_ binding: MacDriverBinding?) {
        if inputOwner !== binding { inputOwner?.releaseHeldInputs() }
        inputOwner = binding
    }

    func acquire(context: MacOperationContext) async -> Bool {
        guard !Task.isCancelled, !context.expired else { return false }
        guard busy else { busy = true; return true }
        let id = UUID()
        let done = ScopedWaiter()
        waiters.append((id, done))
        await done.park(budget: context.waitBudget)
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index)
            return false
        }
        // Cancellation may race the transfer of the slot; its new owner must pass it on before returning, rather than abandoning a busy queue.
        if Task.isCancelled || context.expired { release(); return false }
        return true
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().1.resume() }
    }
}
