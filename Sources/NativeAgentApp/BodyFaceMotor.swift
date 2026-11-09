import Foundation
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `BodyFaceMotor.swift` | Connection-held motor acknowledgments and driving feedback for the separate face |

enum BodyFaceMotor {
    @concurrent static func connect(_ connection: UUID, acts: EngineFaceActs) async {
        let (points, writer) = AsyncStream<PointerPresentation>.makeStream()
        Task {
            for await point in points {
                do { try await acknowledge(.agentPointerMoved(point), connection: connection, acts: acts) }
                catch { ModuleLog.app("[face] pointer feedback failed: %@", error.localizedDescription); return }
            }
        }
        PersonOnlyWindows.installRenderer(connection: connection, motor: .init(
            prepare: { operation, point, driver in
                try await acknowledge(.passPointerThrough(operation: operation, x: point.x, y: point.y,
                    driver: driver.map { .init(session: $0.session, turn: $0.turn) }), connection: connection, acts: acts)
            }, restore: { operation in
                try await acknowledge(.restorePointerInteraction(operation: operation), connection: connection, acts: acts)
            }, stepAside: { driver in
                try await acknowledge(.stepAside(driver: driver.map { .init(session: $0.session, turn: $0.turn) }), connection: connection, acts: acts)
            }, pointer: { point, pressed in
                writer.yield(.init(x: point.x, y: point.y, pressed: pressed, name: nil, driver: nil))
            }, keyboard: {
                try await acknowledge(.waitForKeyboard, connection: connection, acts: acts)
            }, disconnected: { writer.finish() }))
    }

    private static func acknowledge(_ call: FaceCall, connection: UUID, acts: EngineFaceActs) async throws {
        switch try await acts.call(call, renderer: connection) {
        case .acknowledged: return
        case .failed(let failure), .refused(let failure): throw failure
        case .cancelled: throw CancellationError()
        default: throw FaceWireError.invalidFeedOrder
        }
    }
}
