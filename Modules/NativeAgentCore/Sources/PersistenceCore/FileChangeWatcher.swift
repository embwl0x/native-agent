import Darwin
import Dispatch
import Foundation

/// kqueue-backed append-file watcher. Missing files are watched through their
/// parent directories; rename/delete events re-arm the target vnode.
public final class FileChangeWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (URL) -> Void
    private struct Armed { let source: DispatchSourceFileSystemObject }
    private let paths: [URL]
    private let handler: Handler
    private let queue: DispatchQueue
    private var sources: [URL: Armed] = [:]
    private var stopped = false

    public init(paths: [URL], handler: @escaping Handler) {
        self.paths = Array(Set(paths.map(\.standardizedFileURL)))
        self.handler = handler
        self.queue = DispatchQueue(label: "com.nativeagent.persistence.file-watcher", qos: .utility)
        // Return only after the vnode sources are armed. An asynchronous first
        // arm leaves a startup window where a CLI can create/replace the file
        // before any source exists, and that edge would remain invisible until
        // a later write.
        self.queue.sync { self.armAll() }
    }

    public func cancel() {
        queue.async { [self] in
            guard !stopped else { return }
            self.stopped = true
            let old = Array(self.sources.values); self.sources.removeAll()
            old.forEach { $0.source.cancel() }
        }
    }

    deinit { sources.values.forEach { $0.source.cancel() } }

    private func armAll() { guard !stopped else { return }; paths.forEach(arm) }

    private func arm(_ path: URL) {
        guard !stopped else { return }
        sources.removeValue(forKey: path)?.source.cancel()
        let fd = open(path.path, O_EVTONLY)
        if fd >= 0 {
            install(
                fd: fd,
                targetPath: path,
                directory: false,
                mask: [.write, .extend, .rename, .delete, .revoke]
            )
            return
        }
        let parent = path.deletingLastPathComponent()
        let parentFD = open(parent.path, O_EVTONLY)
        guard parentFD >= 0 else { return }
        install(
            fd: parentFD,
            targetPath: path,
            directory: true,
            mask: [.write, .rename, .delete, .revoke]
        )
        // The target can appear after open(target) failed but before the parent
        // vnode source was installed. A directory event for that creation may
        // already have been delivered by then, so close the race with an
        // immediate post-arm check and move onto the target vnode ourselves.
        if FileManager.default.fileExists(atPath: path.path) {
            arm(path)
            handler(path)
        }
    }

    private func install(
        fd: Int32,
        targetPath: URL,
        directory: Bool,
        mask: DispatchSource.FileSystemEvent
    ) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !self.stopped else { return }
            let event = source.data
            if directory {
                if FileManager.default.fileExists(atPath: targetPath.path) {
                    // Arm the new inode before publishing the edge. If a
                    // second atomic replacement lands while the consumer is
                    // reading the first edge, the newly armed vnode observes
                    // it instead of leaving a re-arm loss window.
                    self.arm(targetPath)
                    self.handler(targetPath)
                } else if event.contains(.rename)
                            || event.contains(.delete)
                            || event.contains(.revoke) {
                    self.arm(targetPath)
                }
            } else {
                if event.contains(.rename) || event.contains(.delete) || event.contains(.revoke) {
                    self.arm(targetPath)
                }
                self.handler(targetPath)
            }
        }
        sources[targetPath] = Armed(source: source)
        source.resume()
    }
}
