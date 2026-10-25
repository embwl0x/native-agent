import Foundation
import NativeAgentCore

// Blueprint: | `ProviderErrorBodyDrain.swift` | `ProviderErrorBodyDrain`: bounded exact-request diagnostic reads with idle deadlines; adapters retain HTTP verdicts and cancellation stays cancellation |

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
        // Read on the caller's task; its progress writer wakes the sole deadline.
        // 2026-09-06: `timeout` is an IDLE deadline, not an absolute one. The
        // absolute two-second cut truncated a slowly delivered 400 body and
        // dropped the phrase ("maximum context length", usage exhaustion) that
        // classification turns into compaction or an actionable notice; the
        // partial body then read as a generic terminal error. While bytes keep
        // arriving the read continues, up to a longer absolute cap.
        let progress = ProviderErrorBodyDrainProgress()
        let absoluteCap = max(timeout * 5, 10)
        let watchdog = Task {
            while !Task.isCancelled {
                let (lastActivity, finished, wake) = progress.observe()
                guard !finished else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if progress.expire(now: now, idle: timeout, absolute: absoluteCap) {
                    bytes.task.cancel()
                    return
                }
                let delay = max(0, min(lastActivity + timeout, progress.startedAt + absoluteCap) - now)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await wake.park() }
                    group.addTask { try? await Task.sleep(for: .seconds(delay)) }
                    await group.next()
                    group.cancelAll()
                }
            }
        }
        let result = await withTaskCancellationHandler {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    progress.recordActivity()
                    if body.count >= maxBytes { break }
                }
            } catch {}
            return body
        } onCancel: {
            // Cancel exactly this request, never the shared URLSession.
            progress.finish()
            bytes.task.cancel()
        }
        progress.finish()
        watchdog.cancel()
        await watchdog.value
        // A timeout/ordinary read error still returns diagnostic bytes for
        // normal HTTP mapping. User cancellation must not refresh catalogs or
        // masquerade as a retryable provider error after Stop/Steer.
        try Task.checkCancellation()
        return result
    }
}

/// One read owns progress, wake registration and its terminal transition.
private final class ProviderErrorBodyDrainProgress: @unchecked Sendable {
    private let lock = NSLock()
    let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var wake: ScopedWaiter?

    func observe() -> (TimeInterval, Bool, ScopedWaiter) {
        lock.withLock {
            let waiter = wake ?? ScopedWaiter()
            wake = waiter
            return (lastActivity, finished, waiter)
        }
    }

    func recordActivity() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        signalAndUnlock()
    }

    func expire(now: TimeInterval, idle: TimeInterval, absolute: TimeInterval) -> Bool {
        lock.lock()
        guard !finished, now - lastActivity >= idle || now - startedAt >= absolute else {
            lock.unlock()
            return false
        }
        finished = true
        signalAndUnlock()
        return true
    }

    func finish() {
        lock.lock()
        finished = true
        signalAndUnlock()
    }

    private func signalAndUnlock() {
        let waiter = wake
        wake = nil
        lock.unlock()
        waiter?.resume()
    }
}
