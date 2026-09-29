import Foundation

// Local errors for Swift-native app routes. Retired-route callers either use a
// native implementation or throw an explicit notImplemented envelope.
public enum DaemonError: Error, LocalizedError, Sendable {
    case notFound(String)
    case swiftNativeNotImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "Not found: \(path)"
        case .swiftNativeNotImplemented(let what):
            return "Swift-native impl for \(what) is not built yet."
        }
    }
}
