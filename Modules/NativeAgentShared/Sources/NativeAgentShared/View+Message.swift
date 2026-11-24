import Combine
import Foundation
import SwiftUI
// Blueprint: | `View+Message.swift` | Synchronous main-actor notification delivery for mounted views |

public extension View {
    @MainActor func onMessage<Message: NotificationCenter.MainActorMessage>(
        _ type: Message.Type, perform action: @escaping @MainActor (Message) -> Void
    ) -> some View where Message.Subject: AnyObject {
        onReceive(Deferred {
            let messages = PassthroughSubject<Message, Never>()
            let center = NotificationCenter.default
            let token = center.addObserver(of: nil, for: type) { messages.send($0) }
            return messages.handleEvents(receiveCancel: { @Sendable in center.removeObserver(token) })
        }) { message in action(message) }
    }
}
