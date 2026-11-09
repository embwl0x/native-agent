import Foundation
import NativeAgentCore

// Blueprint: | `ProviderErrorBodyDrain.swift` | Error diagnostics settled by body EOF, read error, byte cap or cancellation |

enum ProviderErrorBodyDrain {
    struct Incomplete: Error, Sendable, LocalizedError, ProviderFailureWrapping {
        let cause: any Error
        let partialBody: Data
        let status: Int?
        let retryAfter: Int?

        private var detail: String {
            let response = status.map { "HTTP \($0)" } ?? "Provider response (HTTP status unavailable)"
            let body = ContextSecretContentPolicy.redactedFragment(String(decoding: partialBody, as: UTF8.self))
            return "\(response) diagnostic body failed after \(partialBody.count) bytes: \(ProviderFailure.diagnosticDescription(cause)); body: \(body)"
        }

        var errorDescription: String? { detail }

        var providerFailureCause: any Error {
            guard let status else { return cause }
            return ProviderFailure.Diagnostic(cause: ProviderFailure.http(status: status, detail: String(decoding: partialBody, as: UTF8.self),
                retryAfter: retryAfter), detail: detail, retryAfter: retryAfter)
        }
    }

    static func read(_ bytes: ProviderHTTPBytes, maxBytes: Int) async throws -> Data {
        defer { bytes.cancel() }
        guard maxBytes > 0 else { throw POSIXError(.EINVAL) }
        return try await withTaskCancellationHandler {
            var body = Data()
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    body.append(byte)
                    if body.count == maxBytes { break }
                }
            } catch {
                try Task.checkCancellation()
                throw Incomplete(cause: error, partialBody: body, status: (bytes.task.response as? HTTPURLResponse)?.statusCode,
                                 retryAfter: parseRetryAfterSeconds(from: bytes.task.response))
            }
            try Task.checkCancellation()
            return body
        } onCancel: {
            bytes.cancel()
        }
    }
}
