import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(ScreenCaptureKit) && os(macOS)
import ScreenCaptureKit
#endif
#if canImport(AppKit)
import AppKit
import ApplicationServices
import UserNotifications
import Experiences
import CryptoKit
import os
#endif
// Blueprint: | `MacScreenViewResultRedaction.swift` | Persisted result previews omit image payloads |
/// Screenshots belong in the live model call but not trace, persistence or sync; those sinks retain only size, hash and pixel dimensions.
public enum MacScreenViewResultRedaction {
    /// All view names and mac_wake share top-level image stripping and text redaction.
    public static let viewToolNames: Set<String> = [
        "mac_view", "mac.view", "view",
        "mac_attention", "mac.attention", "attention",
        "mac_wake", "mac.wake", "wake",
    ]
    public static func carriesImage(tool: String) -> Bool {
        viewToolNames.contains(
            tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
    /// Idempotent stripping lets each sink enforce redaction without tracking upstream work.
    public static func redacted(tool: String, result: JSONValue) -> JSONValue {
        guard carriesImage(tool: tool) else { return result }
        guard case .object(var object) = result else { return result }
        guard case .string(let base64)? = object["image"], !base64.isEmpty else { return result }
        object.removeValue(forKey: "image")
        object["image_redacted"] = .bool(true)
        if object["image_bytes"] == nil || object["image_bytes"] == .null {
            let bytes = Data(base64Encoded: base64)?.count ?? base64.utf8.count
            object["image_bytes"] = .int(Int64(bytes))
        }
        if let digest = MacInjectionArgRedaction.sha256(base64) {
            object["image_sha256"] = .string(digest)
        }
        return .object(object)
    }
}
