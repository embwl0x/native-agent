import Foundation
import Synchronization
import NativeAgentCore
// Blueprint: | `MacInputRouting.swift` | Routed-event receipts and epoch-bound face input identity |

public enum MacInputRouting {
    private struct Receipt {
        let connections: Set<UUID>
        let reader: CheckedContinuation<Void, Error>
    }
    private struct State {
        var owner: UUID?
        var failure: String?
        var opening: [UUID: CheckedContinuation<Void, Error>] = [:]
        var pending: [Int64: Receipt] = [:]
        var connections: Set<UUID> = []
    }
    private static let state = Mutex(State())
    @concurrent static func open(_ owner: UUID, available: Bool) async {
        let readers = state.withLock {
            $0.owner = owner
            $0.failure = available ? nil : "Native input monitors are unavailable; input routing cannot be acknowledged."
            let readers = $0.opening
            $0.opening.removeAll()
            return readers
        }
        for reader in readers.values {
            if available { reader.resume() }
            else { reader.resume(throwing: PersonOnlyWindows.MotorFailure(detail: "Native input monitors are unavailable.")) }
        }
    }

    @concurrent static func close(_ owner: UUID) async {
        let readers = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            guard state.owner == owner else { return [] }
            state.owner = nil
            state.failure = "The Mac input monitor owner shut down before routing was acknowledged."
            let readers = Array(state.opening.values) + state.pending.values.map(\.reader)
            state.opening.removeAll(); state.pending.removeAll()
            return readers
        }
        for reader in readers { reader.resume(throwing: PersonOnlyWindows.MotorFailure(detail: "The Mac input monitor owner shut down.")) }
    }

    @concurrent static func routed(_ token: Int64) async {
        state.withLock { $0.pending.removeValue(forKey: token) }?.reader.resume()
    }

    @concurrent public static func faceConnected(_ connection: UUID, processID: Int32) async throws {
        guard PersonOnlyWindows.isFaceProcess(processID) else {
            throw PersonOnlyWindows.MotorFailure(detail: "The connecting window is not the body's live window process.")
        }
        try state.withLock {
            try Task.checkCancellation()
            $0.connections.insert(connection)
        }
    }

    @concurrent public static func faceDisconnected(_ connection: UUID) async {
        let receipts = state.withLock {
            $0.connections.remove(connection)
            let readers = $0.pending.filter { $0.value.connections.contains(connection) }
            for token in readers.keys { $0.pending.removeValue(forKey: token) }
            return readers
        }
        for receipt in receipts.values {
            receipt.reader.resume(throwing: PersonOnlyWindows.MotorFailure(
                detail: "The window disconnected after input was posted; its routing is unconfirmed."))
        }
    }

    static func post(connections: Set<UUID>, _ emit: (Int64) -> Bool) async throws {
        let openingID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (reader: CheckedContinuation<Void, Error>) in
                state.withLock {
                    if Task.isCancelled { reader.resume(throwing: CancellationError()) }
                    else if let failure = $0.failure { reader.resume(throwing: PersonOnlyWindows.MotorFailure(detail: failure)) }
                    else if $0.owner != nil { reader.resume() }
                    else { $0.opening[openingID] = reader }
                }
            }
        } onCancel: {
            state.withLock { $0.opening.removeValue(forKey: openingID) }?.resume(throwing: CancellationError())
        }
        let token = Int64.random(in: 1...Int64.max)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (reader: CheckedContinuation<Void, Error>) in
                let failure = state.withLock { state -> PersonOnlyWindows.MotorFailure? in
                    guard !Task.isCancelled, state.pending[token] == nil, state.owner != nil, state.failure == nil,
                          state.connections == connections else {
                        return .init(detail: "The input routing receipt could not be registered.")
                    }
                    state.pending[token] = Receipt(connections: connections, reader: reader)
                    guard emit(token) else {
                        state.pending.removeValue(forKey: token)
                        return .init(detail: "Input emission was refused; no event was posted.")
                    }
                    return nil
                }
                if let failure { reader.resume(throwing: failure) }
            }
        } onCancel: {
            state.withLock { $0.pending.removeValue(forKey: token) }?.reader.resume(throwing:
                PersonOnlyWindows.MotorFailure(detail: "Input routing was cancelled; any posted event has an unconfirmed outcome."))
        }
    }
}
