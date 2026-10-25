import Foundation
import NativeAgentShared

// Blueprint: | `PhoneConnectionReader.swift` | `PhoneConnectionReader`: weak on-demand reader of the running bridge's one phone-connection assessment |

/// The bridge installs a weak reader of its one phone-connection assessment;
/// Doctor reads it on demand, so her reading and the Connectors › iPhone tab
/// are the same three facts.
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
