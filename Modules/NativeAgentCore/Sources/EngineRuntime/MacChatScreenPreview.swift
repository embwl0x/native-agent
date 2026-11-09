import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ChatTurnRuntime
import AgentWorkspace
import NativeAgentShared
// Blueprint: | `MacChatScreenPreview.swift` | `TurnsFacade.receiveScreenPreview`: off-main encoded masked preview, scoped to its exact active turn |

private actor TurnPreviewEncoder {
    static let shared = TurnPreviewEncoder()

    func encode(_ update: MacScreenPreviewUpdate) -> TurnFace.Preview {
        var encoded: Data?
        var failure: String?
        if let image = update.image {
            let bytes = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { encoded = bytes as Data }
                else { failure = "The screen preview could not be encoded as PNG." }
            } else {
                failure = "The PNG encoder could not open the screen preview."
            }
        }
        return TurnFace.Preview(imageData: encoded, imageError: failure, readText: update.readText,
            caption: update.caption ?? "", updatedAt: update.at)
    }
}

extension TurnsFacade {
    public func receiveScreenPreview(_ update: MacScreenPreviewUpdate, identity: MacChatTurnIdentity) async {
        let preceding = screenPreviewPublication
        let publication = Task { @MainActor in
            await preceding?.value
            await applyScreenPreview(update, identity: identity)
        }
        screenPreviewPublication = publication
        await publication.value
    }

    private func applyScreenPreview(_ update: MacScreenPreviewUpdate, identity: MacChatTurnIdentity) async {
        guard activeTurnIDsBySession[identity.sessionId] == identity.turnId else { return }
        let encoded = await TurnPreviewEncoder.shared.encode(update)
        guard activeTurnIDsBySession[identity.sessionId] == identity.turnId else { return }
        let previous = screenPreviewBySession[identity.sessionId]
        let replaces = update.replacesImage || update.image != nil || update.readText != nil
        let preview = TurnFace.Preview(
            imageData: replaces ? encoded.imageData : previous?.imageData,
            imageError: replaces ? encoded.imageError : previous?.imageError,
            readText: replaces ? encoded.readText : previous?.readText,
            caption: update.caption ?? previous?.caption ?? "", updatedAt: encoded.updatedAt
        )
        screenPreviewBySession[identity.sessionId] = preview
    }
}
