import Foundation
import NativeAgentShared
// Blueprint: | `ChatStore+ReplyObservation.swift` | One signed reply/rejection/resync receiver across chat, talk and background audio; attaching resumes bounded delivery observation after durable restoration |

extension ChatStore {
    /// Both doors attach to this one receiver. Its lifetime is the shared
    /// store's, so presenting the call cannot remove the chat's ears.
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
