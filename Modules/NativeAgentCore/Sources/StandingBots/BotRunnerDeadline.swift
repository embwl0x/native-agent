import Foundation
// Blueprint: | `BotRunnerDeadline.swift` | Report helper deadlines without cancelling work; scheduled runs and conversations share settlement |

/// A deadline reports lateness while work settles under its own lifetime; only the person's Stop ends it early.
package enum BotRunnerDeadline {
    /// The claim keeps its crossing mark until the session has settled.
    package static func settled<T: Sendable>(seconds: TimeInterval, onDeadline: @escaping @Sendable () async -> Void,
                                     body: @escaping @Sendable () async throws -> T) async throws -> T {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(max(0, seconds))) }
            catch { return }
            await onDeadline()
        }
        let result: Result<T, Error>
        do { result = .success(try await body()) }
        catch { result = .failure(error) }
        deadline.cancel()
        await deadline.value
        return try result.get()
    }
}
