import Foundation
import NativeAgentShared
// Blueprint: | `MindFaceCalls.swift` | Inspector reverse calls read and rearm the mounted renderer subscription |

@MainActor
enum MindFaceCalls {
    static func install(router: FaceCallRouter, client: PipeFaceClient) {
        router.register({ call in
            switch call {
            case .readInspectorHealth:
                guard let connection = client.connectionID else { throw FaceWireError.disconnected }
                return .inspector(TurnInspectorDoctor.report(connection: connection))
            case .rearmInspectorSubscription(let view, let subscription):
                guard let connection = client.connectionID else { throw FaceWireError.disconnected }
                return .inspector(try await TurnInspectorDoctor.rearm(connection: connection, view: view, subscription: subscription))
            default: return nil
            }
        }, disconnect: { TurnInspectorDoctor.active = nil })
    }
}
