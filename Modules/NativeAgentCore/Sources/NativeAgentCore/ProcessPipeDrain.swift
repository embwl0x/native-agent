import Foundation
import Darwin
// Blueprint: | `Modules/NativeAgentCore/Sources/NativeAgentCore/ProcessPipeDrain.swift` | Nonblocking pipe reads and EOF settlement |

/// A child exiting does not imply EOF when another process still owns a pipe writer.
package final class ProcessPipeDrain: @unchecked Sendable {
    package enum End: Sendable { case eof, stopped, failed(String) }
    private let handle: FileHandle
    private let onData: @Sendable (Data) -> Void
    private let onEnd: @Sendable (End) -> Void
    private let queue = DispatchQueue(label: "NativeAgent.process.pipe")
    private let source: DispatchSourceRead
    private let completion = DispatchGroup()
    private var failure: String?
    private var ending: End = .stopped

    package var captureReadFailed: Bool { captureFailure != nil }
    package var captureFailure: String? { queue.sync { failure } }

    package init(handle: FileHandle, onData: @escaping @Sendable (Data) -> Void,
                 onEnd: @escaping @Sendable (End) -> Void = { _ in }) throws {
        self.handle = handle
        self.onData = onData
        self.onEnd = onEnd
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NSError(domain: "NativeAgent.ProcessPipe", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not configure subprocess pipe"])
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        completion.enter()
        source.setEventHandler { [self] in drain() }
        source.setCancelHandler { [self] in
            do { try handle.close() }
            catch {
                let detail = "Could not close subprocess pipe: \(error.localizedDescription)"
                if let failure { self.failure = failure + "; " + detail }
                else { failure = detail }
            }
            if let failure { onEnd(.failed(failure)) }
            else { onEnd(ending) }
            completion.leave()
            source.setEventHandler(handler: nil)
            source.setCancelHandler(handler: nil)
        }
        source.resume()
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Bound each callback so a continuous writer cannot prevent stop.
        for _ in 0..<64 {
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                onData(Data(bytes.prefix(count)))
            } else if count == 0 {
                ending = .eof
                source.cancel()
                return
            } else if errno != EINTR {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    failure = "Could not read subprocess pipe: \(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)"
                    source.cancel()
                }
                return
            }
        }
    }

    package func stop() {
        queue.async { [self] in
            guard !source.isCancelled else { return }
            drain()
            source.cancel()
        }
    }

    package func stopAndWait() {
        stop()
        completion.wait()
    }

    /// Join EOF or a read error on a process settlement queue, without closing a live pipe.
    package func waitForEOF() {
        completion.wait()
    }

    package func wait(until deadline: DispatchTime) -> Bool {
        completion.wait(timeout: deadline) == .success
    }

    package func wait() async {
        await withCheckedContinuation { continuation in
            completion.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}
