import AppKit
import Foundation
import NativeAgentShared
// Blueprint: | `FaceCallRouter.swift` | Renderer reverse-call dispatch and the applied-frame page capture callback |

@MainActor
final class FaceCallRouter {
    typealias Handler = @MainActor (FaceCall) async throws -> FaceReply?
    typealias PageImage = @MainActor (PageRenderRequest) async throws -> PageRenderResult

    private let client: PipeFaceClient
    private let pageImage: PageImage
    private let showWindow: @MainActor (FaceDestination?) async throws -> FaceReply
    private var handlers: [Handler] = []
    private var disconnectHandlers: [@MainActor () -> Void] = []
    private var connected = true

    init(client: PipeFaceClient, pageImage: @escaping PageImage,
         showWindow: @escaping @MainActor (FaceDestination?) async throws -> FaceReply) {
        self.client = client; self.pageImage = pageImage; self.showWindow = showWindow
    }

    /// Each presentation owner registers its calls and releases its local resources on disconnection.
    func register(_ handler: @escaping Handler, disconnect: @escaping @MainActor () -> Void) {
        handlers.append(handler)
        disconnectHandlers.append(disconnect)
    }

    func reply(to call: FaceCall) async -> FaceReply {
        do {
            try Task.checkCancellation()
            guard connected else { throw FaceWireError.disconnected }
            switch call {
            case .showMainWindow(let destination): return try await showWindow(destination)
            case .renderPage(let request):
                try client.requireApplied(request)
                return .rendered(try await pageImage(request))
            default:
                for handler in handlers {
                    if let reply = try await handler(call) { return reply }
                }
                return .refused(.init(code: "face_call_unmounted", message: "This window has no mounted owner for the requested presentation.",
                                      cause: nil, effects: .none))
            }
        } catch is CancellationError { return .cancelled }
        catch let failure as WireFailure { return .failed(failure) }
        catch FaceWireError.disconnected {
            // Not connected yet (no frame drawn) or any more: the window has nothing showing to answer from, which is not a failed presentation.
            return .failed(.init(code: FaceWireError.disconnectedCode, message: "The window is not connected.", cause: nil, effects: .none))
        } catch {
            return .failed(.init(code: "face_call_failed", message: "The window could not complete the requested presentation.",
                                 cause: error.localizedDescription, effects: .unknown))
        }
    }

    func disconnect() {
        guard connected else { return }
        connected = false
        for release in disconnectHandlers { release() }
        handlers.removeAll(); disconnectHandlers.removeAll()
    }
}
