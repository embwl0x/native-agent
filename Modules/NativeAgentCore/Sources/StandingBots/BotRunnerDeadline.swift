import Foundation
// Blueprint: | `BotRunnerDeadline.swift` | Await the helper session's own terminal result |

package enum BotRunnerDeadline {
    package static func settled<T: Sendable>(seconds _: TimeInterval, onDeadline _: @escaping @Sendable () async -> Void,
                                     body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await body()
    }
}
