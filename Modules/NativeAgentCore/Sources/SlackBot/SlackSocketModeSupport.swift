import Foundation
// Blueprint: | `SlackSocketModeSupport.swift` | `SlackHandlingCompletion` retains deferred settings work through reply settlement; checked socket errors |

/// Settings restarts run after reply delivery settles, within the accepted handler's retained lifetime rather than in detached work.
actor SlackHandlingCompletion {
    private var operations: [@Sendable () async -> Void] = []

    func append(_ operation: @escaping @Sendable () async -> Void) {
        operations.append(operation)
    }

    func finish() async {
        let pending = operations
        operations.removeAll()
        guard !pending.isEmpty else { return }
        for operation in pending { await operation() }
    }
}

enum SlackSocketModeError: Error, CustomStringConvertible {
    case api(String)

    var description: String {
        switch self {
        case .api(let message): return message
        }
    }
}
