import Foundation
import Synchronization
import NativeAgentCore
// Blueprint: | `MacInputRouting.swift` | Epoch-bound face input identity; posts once through the windows that stepped aside |

public enum MacInputRouting {
    private static let connections = Mutex(Set<UUID>())

    @concurrent public static func faceConnected(_ connection: UUID, processID: Int32) async throws {
        guard PersonOnlyWindows.isFaceProcess(processID) else {
            throw PersonOnlyWindows.MotorFailure(detail: "The connecting window is not the body's live window process.")
        }
        try connections.withLock {
            try Task.checkCancellation()
            $0.insert(connection)
        }
    }

    @concurrent public static func faceDisconnected(_ connection: UUID) async {
        _ = connections.withLock { $0.remove(connection) }
    }

    /// Post once through the windows that stepped aside. The act's own effect check proves whether it landed; no echo of the event is awaited
    /// (an input monitor's copy of a posted event reads its source fields as zero, so an echo never reliably returned).
    static func post(connections asked: Set<UUID>, _ emit: () -> Bool) async throws {
        try Task.checkCancellation()
        guard connections.withLock({ $0 == asked }) else {
            throw PersonOnlyWindows.MotorFailure(detail: "The windows that stepped aside are not the connected ones; no event was posted.")
        }
        guard emit() else { throw PersonOnlyWindows.MotorFailure(detail: "Input emission was refused; no event was posted.") }
    }
}
