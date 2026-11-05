import Foundation
import NativeAgentShared
// Blueprint: | `ChatStore+ReplyObservation.swift` | Shared signed reply/rejection/resync receiver; restores bounded delivery observation |

extension ChatStore {
    /// The shared store owns this receiver so presenting Talk cannot remove Chat's observation.
    func attachReplyReceiver(using client: MacBridgeClient) {
        pendingRetryClient = client
        Task { [weak self] in
            await self?.restorationTask?.value
            self?.resumeDeliveryConfirmations()
        }
        if replyObserverID == nil {
            replyObserverID = client.observeICloudReplies { [weak self] message in
                Task { @MainActor in await self?.receiveICloudReply(message) }
            }
        }
        if rejectionObserverID == nil {
            rejectionObserverID = client.observeICloudReplyRejections { [weak self] rejection in
                Task { @MainActor in self?.receiveICloudRejection(rejection) }
            }
        }
        if resyncObserverID == nil {
            resyncObserverID = client.observeICloudResyncHints { [weak self, weak client] hint in
                Task { @MainActor in
                    guard let client else { return }
                    self?.receiveICloudResyncHint(hint, client: client)
                }
            }
        }
    }
}
