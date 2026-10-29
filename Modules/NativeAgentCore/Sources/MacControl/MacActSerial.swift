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
// Blueprint: | `MacActSerial.swift` | `MacActSerial` serializes named/exact acts and watch hands, releasing held input on driver transfer |

/// One act at a time, in arrival order. Every act reads and moves a real
/// window, and the pid it will touch is only known after its first look, so
/// the queue is process-wide: parallel calls run one after another.
actor MacActSerial {
    static let shared = MacActSerial()
    private var busy = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    private weak var inputOwner: MacDriverBinding?

    /// A new driver cannot inherit another watch's held keys or buttons.
    func ownInputs(_ binding: MacDriverBinding?) {
        if inputOwner !== binding { inputOwner?.releaseHeldInputs() }
        inputOwner = binding
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard busy else { busy = true; return true }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Cancellation may race the transfer of the slot; its new owner must
        // pass it on before returning, rather than abandoning a busy queue.
        if acquired, Task.isCancelled { release(); return false }
        return acquired
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().1.resume(returning: true) }
    }
}
