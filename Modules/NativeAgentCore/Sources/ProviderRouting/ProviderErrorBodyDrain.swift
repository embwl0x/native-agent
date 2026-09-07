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
        // 2026-09-06: `timeout` is an IDLE deadline, not an absolute one. The
        // absolute two-second cut truncated a slowly delivered 400 body and
        // dropped the phrase ("maximum context length", usage exhaustion) that
        // classification turns into compaction or an actionable notice; the
        // partial body then read as a generic terminal error. While bytes keep
        // arriving the read continues, up to a longer absolute cap.
        let progress = ProviderErrorBodyDrainProgress()
        let absoluteCap = max(timeout * 5, 10)
        let watchdog = Task {
            let started = Date()
            var seen = 0
            do {
                while true {
                    try await Task.sleep(for: .seconds(timeout))
                    let now = progress.count
                    if now == seen || Date().timeIntervalSince(started) >= absoluteCap {
                        bytes.task.cancel()
                        return
                    }
                    seen = now
                }
            } catch {
                // A completed/cancelled read retired the sole deadline.
            }
        }
        let result = await withTaskCancellationHandler {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    progress.count = body.count
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

/// Byte progress shared between the drain loop and its idle watchdog.
private final class ProviderErrorBodyDrainProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
