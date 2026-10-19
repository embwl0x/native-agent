import Foundation
import NativeAgentShared

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
