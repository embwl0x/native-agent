import Foundation

// Blueprint: | `NativePrivateFile.swift` | `NativePrivateFile.write`: atomic private-file replacement with 0600 at creation, without a chmod exposure window |

public enum NativePrivateFile {
    /// Set 0600 at creation so atomic replacement has no chmod-after-write exposure window.
    @discardableResult
    public static func write(_ data: Data, to destination: URL) -> Bool {
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: destination)
            return true
        } catch { return false }
    }
}
