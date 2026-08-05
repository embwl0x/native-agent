import Foundation
import PersonaEngine

// MARK: - Hermetic persona-engine helper (test hermeticity)
//
// `SwiftNativePersonaEngine(root:)` defaults its `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (this repo's `data/` via the CWD walk-up). The engine resolves
// `<dataRoot>/memory/profile.json` AND `<dataRoot>/activity/events.jsonl` off
// that, so a bare construction makes `savePersonalityDoc` append real
// "<DOC>.md updated" rows to the user's live activity feed.
//
// Every construction of `SwiftNativePersonaEngine` in this target goes through
// this helper. Pass `dataRoot:` when the test already has its own temp data
// root in scope (the usual case here — the same `root` feeds TrustCenter and
// the artifact writer), otherwise a fresh temp dir is minted.
//
// Helpers do not cross target boundaries; this is the NativeAgentAppTests copy
// of the convention (see Modules/NativeAgentCore/Tests/*/Hermetic*Support.swift).
func hermeticPersona(root: URL, dataRoot: URL? = nil) -> SwiftNativePersonaEngine {
    SwiftNativePersonaEngine(root: root, dataRoot: dataRoot ?? hermeticPersonaDataRoot())
}

/// Fresh, unique temp data root for a hermetic persona engine.
func hermeticPersonaDataRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentAppTests-personaData-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
