import Foundation
// Blueprint: | `BotRunnerDeadline.swift` | One helper seconds deadline is reported when crossed and never cancels its work; scheduled runs and direct conversations share it |

/// The run's time budget is a fact reported when it is crossed, never a
/// cancel around the helper's work: the turn finishes under its own lifetime,
/// and the person's Stop is what ends one early (10-24: cancelling cut a helper
/// off mid-conversation and sent her a blank message).
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
