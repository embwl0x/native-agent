import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Dictionary helpers

extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(_ key: String) -> String? {
        if case .string(let s) = self[key] ?? .null { return s }
        return nil
    }
}
