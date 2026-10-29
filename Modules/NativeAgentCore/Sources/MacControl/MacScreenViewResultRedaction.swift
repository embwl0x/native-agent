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
/// `mac_view` returns a base64 PNG of the screen. That is correct for the LIVE
/// model call — it is the spatial backdrop the whole organ exists to provide —
/// and wrong for everything downstream of it. The generic trace/persistence
/// preview sinks redact injection-SHAPED results only, so a full screenshot of
/// whatever User had open (a banking page, a private message, an authenticator)
/// was riding into the turn trace and the persisted transcript, which syncs.
///
/// This strips the pixels at those sinks and leaves the audit trail: how big it
/// was, what it hashed to, and what its pixel size was (already in the result).
public enum MacScreenViewResultRedaction {
    /// Every name `mac_view` answers to across the tool/registry/action layers.
    ///
    /// `mac_wake` uses the same top-level view keys, source redaction and image stripping.
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
    /// Idempotent: an already-stripped result has no `image` string left, so a
    /// sink can call this without knowing whether an upstream sink did.
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
