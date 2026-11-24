import Foundation
// Blueprint: | `NotificationCenter+Synchronous.swift` | Synchronous delivery of typed messages on the posting thread or requested queue |

extension NotificationCenter {
    public func observeSynchronously<Message: AsyncMessage>(
        for type: Message.Type, queue: OperationQueue? = nil,
        using observer: @escaping @Sendable () -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: type.name, object: nil, queue: queue) { _ in observer() }
    }

    public func observeSynchronously<Message: AsyncMessage>(
        for type: Message.Type, queue: OperationQueue? = nil,
        using observer: @escaping @Sendable (Message) -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: type.name, object: nil, queue: queue) { notification in
            if let message = type.makeMessage(notification) { observer(message) }
        }
    }
}
