import Foundation
// Blueprint: | `FaceClient.swift` | `FaceClient`, `FaceActHandler`, `InProcessFaceClient`: the one way a window view acts on them, in-process or over the pipe |

/// What a window view holds of her: the feed it draws and the acts it sends. The same views run over either transport.
@MainActor
public protocol FaceClient: AnyObject {
    var face: FaceFeed { get }
    /// Send one act and await her typed reply. A decision or readback is an act; its answer is the reply, never a face slot.
    func act(_ act: FaceAct) async throws -> FaceActReply
}

/// Her side of the acts: the body's one dispatcher. Each act is handled by its engine owner, off the window's thread.
public protocol FaceActHandler: Sendable {
    func handle(_ act: FaceAct) async throws -> FaceActReply
}

/// The window and her body in one process: acts go straight to her dispatcher; the feed is the in-process feed.
@MainActor
public final class InProcessFaceClient: FaceClient {
    public let face: FaceFeed
    private let handler: any FaceActHandler

    public init(face: FaceFeed, handler: any FaceActHandler) {
        self.face = face
        self.handler = handler
    }

    public func act(_ act: FaceAct) async throws -> FaceActReply {
        try await handler.handle(act)
    }
}
