import Foundation

/// Cancel at the run duration without abandoning an ordinary session writer.
enum BotRunnerDeadline {
    /// Retain the run claim until the chat client and its persistence settle.
    /// A non-cooperative provider cannot overlap a later turn in this session.
    static func settled<T: Sendable>(seconds: TimeInterval, body: @escaping @Sendable () async throws -> T) async throws -> T {
        let child = Task { try await body() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(max(0, seconds))) }
            catch { return }
            child.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
    }

}
