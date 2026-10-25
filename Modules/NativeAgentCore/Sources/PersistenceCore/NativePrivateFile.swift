import Foundation

// Blueprint: | `NativePrivateFile.swift` | `NativePrivateFile.write`: atomic private-file replacement with 0600 at creation, without a chmod exposure window |

public enum NativePrivateFile {
    /// Atomically replaces one private discovery/credential file with mode
    /// 0600 set at creation, so no chmod-after-write exposure window exists.
    @discardableResult
    public static func write(_ data: Data, to destination: URL) -> Bool {
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: destination)
            return true
        } catch { return false }
    }
}
