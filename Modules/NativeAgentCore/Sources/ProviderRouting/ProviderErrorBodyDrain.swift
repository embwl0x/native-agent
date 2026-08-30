import Foundation

/// Best-effort error diagnostics with exact-request ownership. HTTP status
/// classification remains with each adapter; a failed/stalled body read is
/// not a new provider verdict. User cancellation remains cancellation.
enum ProviderErrorBodyDrain {
    static func read(
        _ bytes: URLSession.AsyncBytes, maxBytes: Int, timeout: TimeInterval
    ) async throws -> Data {
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard maxBytes > 0 else { return Data() }
        // Read on the caller's task. The old unstructured read outlived Stop until
        // its deadline, then swallowed cancellation as a provider HTTP error.
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                bytes.task.cancel()
            } catch {
                // A completed/cancelled read retired the sole deadline.
            }
        }
        let result = await withTaskCancellationHandler {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= maxBytes { break }
                }
            } catch {}
            return body
        } onCancel: {
            // Cancel exactly this request, never the shared URLSession.
            bytes.task.cancel()
        }
        watchdog.cancel()
        await watchdog.value
        // A timeout/ordinary read error still returns diagnostic bytes for
        // normal HTTP mapping. User cancellation must not refresh catalogs or
        // masquerade as a retryable provider error after Stop/Steer.
        try Task.checkCancellation()
        return result
    }
}
