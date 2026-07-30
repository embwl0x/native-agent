import Foundation
import AppKit
import PersistenceCore

// MARK: - MacAppleScriptBridge
//
// W2 backend for NativeAgent's Mac Integration Phase 2: AppleScript bridges
// for Mail / Messages / Notes / Music. Lives app-side because NSAppleScript
// is an AppKit dependency and the app target carries the TCC permission
// descriptors (NSAppleEventsUsageDescription in the app bundle's Info.plist).
//
// All public methods are `async throws -> JSONValue`, take `[String: JSONValue]`
// input, and return a `{status: completed | denied | failed, ...}` envelope.
// The permission gate (Phase 1) is enforced upstream of this bridge by
// MacIntegrationPermissionStore — this layer focuses on executing the
// AppleScript and translating TCC denials into a structured envelope.
public enum MacAppleScriptBridge {}
