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
// Blueprint: | `MacActSerial.swift` | `MacActSerial` serializes named/exact acts and watch hands, releasing held input on driver transfer; expired queue parkers remove themselves or pass on a raced slot |

/// One act at a time, in arrival order. Every act reads and moves a real
/// window, and the pid it will touch is only known after its first look, so
/// the queue is process-wide: parallel calls run one after another.
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

    func acquire() async -> Bool {
        guard !Task.isCancelled, !TaskWaitDeadline.expired else { return false }
        guard busy else { busy = true; return true }
        let id = UUID()
        let done = ScopedWaiter()
        waiters.append((id, done))
        await done.park()
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index)
            return false
        }
        // Cancellation may race the transfer of the slot; its new owner must
        // pass it on before returning, rather than abandoning a busy queue.
        if Task.isCancelled || TaskWaitDeadline.expired { release(); return false }
        return true
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().1.resume() }
    }
}
