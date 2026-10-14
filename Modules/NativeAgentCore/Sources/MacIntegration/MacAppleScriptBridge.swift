import Foundation
import PersistenceCore

// MARK: - MacAppleScriptBridge
//
// W2 backend for NativeAgent's Mac Integration Phase 2: AppleScript bridges
// for Mail / Messages / Notes / Music. MacIntegration builds integration scripts;
// MacControl owns execution and the app bundle carries the TCC descriptors.
//
// All public methods are `async throws -> JSONValue`, take `[String: JSONValue]`
// input, and return a `{status: completed | denied | failed, ...}` envelope.
// The permission gate (Phase 1) is enforced upstream of this bridge by
// MacIntegrationPermissionStore — this layer focuses on executing the
// AppleScript and translating TCC denials into a structured envelope.
public enum MacAppleScriptBridge {}
