import Foundation
import Darwin

/// Nonblocking readers keep EOF inside the subprocess deadline. A child
/// exiting does not imply EOF when descendants still own pipe writers.
package final class ProcessPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let onData: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "NativeAgent.process.pipe")
    private let source: DispatchSourceRead
    private let completion = DispatchGroup()

    package init(handle: FileHandle, onData: @escaping @Sendable (Data) -> Void) throws {
        self.handle = handle
        self.onData = onData
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NSError(domain: "NativeAgent.ProcessPipe", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not configure subprocess pipe"])
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        completion.enter()
        source.setEventHandler { [self] in drain() }
        source.setCancelHandler { [self] in
            try? handle.close()
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
                source.cancel()
                return
            } else if errno != EINTR {
                if errno != EAGAIN && errno != EWOULDBLOCK { source.cancel() }
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

    package func wait() async {
        await withCheckedContinuation { continuation in
            completion.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}
