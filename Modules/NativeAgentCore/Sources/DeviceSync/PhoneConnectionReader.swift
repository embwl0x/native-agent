import Foundation
import NativeAgentShared

// Blueprint: | `PhoneConnectionReader.swift` | `PhoneConnectionReader`: weak on-demand reader of the running bridge's one phone-connection assessment |

/// Read the bridge weakly on demand so Doctor and Connectors share one connection assessment.
@MainActor
public enum PhoneConnectionReader {
    private static var readers: [String: @MainActor () -> NAPhoneConnection?] = [:]

    public static func register(dataRoot: URL, read: @escaping @MainActor () -> NAPhoneConnection?) {
        readers[dataRoot.standardizedFileURL.path] = read
    }

    public static func connection(dataRoot: URL) -> NAPhoneConnection? {
        readers[dataRoot.standardizedFileURL.path]?()
    }
}
