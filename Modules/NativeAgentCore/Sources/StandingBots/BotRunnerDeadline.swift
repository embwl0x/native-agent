import Foundation

/// The run's time budget is a fact reported when it is crossed, never a
/// cancel around her session: the turn finishes under its own lifetime, and
/// the person's Stop is what ends one early.
enum BotRunnerDeadline {
    /// The claim keeps its crossing mark until the session has settled.
    static func settled<T: Sendable>(seconds: TimeInterval, onDeadline: @escaping @Sendable () async -> Void,
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
