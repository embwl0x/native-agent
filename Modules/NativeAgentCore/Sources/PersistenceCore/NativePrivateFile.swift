import Foundation

public enum NativePrivateFile {
    /// Atomically replaces one private discovery/credential file with mode
    /// 0600 set at creation, so no chmod-after-write exposure window exists.
    @discardableResult
    public static func write(_ data: Data, to destination: URL) -> Bool {
        let destinationPath = destination.path
        let temporaryPath = destinationPath + ".tmp"
        _ = temporaryPath.withCString { Darwin.unlink($0) }

        let descriptor = temporaryPath.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else { return false }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let wrote = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard wrote > 0 else { return false }
                offset += wrote
            }
            return true
        }
        // temp+rename is only atomic against a CRASH. Against power loss the
        // rename can reach the directory while the temp file's data is still
        // in the page cache, publishing a torn/empty file at the destination —
        // exactly the input that makes a durable journal unreadable. fsync the
        // bytes before they are published; a failed fsync is a failed write.
        let synced = wroteAll && Darwin.fsync(descriptor) == 0
        Darwin.close(descriptor)
        guard synced else {
            _ = temporaryPath.withCString { Darwin.unlink($0) }
            return false
        }
        let renamed = temporaryPath.withCString { source in
            destinationPath.withCString { Darwin.rename(source, $0) }
        }
        if renamed != 0 {
            _ = temporaryPath.withCString { Darwin.unlink($0) }
            return false
        }
        return true
    }
}
