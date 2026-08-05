import Foundation
import PersonaEngine

// MARK: - Hermetic persona-engine helper (test hermeticity)
//
// `SwiftNativePersonaEngine(root:)` defaults its `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (the repo's `data/` via the CWD walk-up, or
// ~/Library/Application Support/NativeAgent). The engine's `dataRoot` is what
// `<dataRoot>/memory/profile.json` and — critically —
// `<dataRoot>/activity/events.jsonl` resolve off. `PersonaEngineCheck.run(
// repair: true)` SAVES persona docs, so a bare construction here appends
// phantom "<DOC>.md updated" activity rows into the user's LIVE feed on every
// suite run.
//
// Every construction of `SwiftNativePersonaEngine` in this target goes through
// this helper. `dataRoot` defaults to a fresh, unique temp dir SIBLING of the
// persona root (never inside it, so persona-doc listings stay unpolluted);
// pass `dataRoot:` explicitly when the test asserts on dataRoot-derived output.
//
// Helpers do not cross target boundaries; this file is the DoctorChecksTests
// copy of the same convention.
func hermeticPersona(root: URL, dataRoot: URL? = nil) -> SwiftNativePersonaEngine {
    SwiftNativePersonaEngine(root: root, dataRoot: dataRoot ?? hermeticPersonaDataRoot())
}

/// Fresh, unique temp data root for a hermetic persona engine.
func hermeticPersonaDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoctorChecksTests-personaData-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
