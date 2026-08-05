import Foundation
import PersonaEngine

// MARK: - Hermetic persona-engine helper (test hermeticity)
//
// `SwiftNativePersonaEngine(root:)` defaults its `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (the repo's `data/` via the CWD walk-up, or
// ~/Library/Application Support/NativeAgent). The engine's `dataRoot` is what
// `<dataRoot>/memory/profile.json` and — critically —
// `<dataRoot>/activity/events.jsonl` resolve off, so a bare construction here
// makes `savePersonalityDoc` append phantom "<DOC>.md updated" activity rows
// into the user's LIVE feed on every suite run (739 such rows accumulated
// before this sweep), and makes persona compilation READ the user's real
// profile.json (machine-dependent test outcomes).
//
// Every construction of `SwiftNativePersonaEngine` in this target goes through
// this helper. `dataRoot` defaults to a fresh, unique temp dir SIBLING of the
// persona root (never inside it, so persona-doc listings stay unpolluted);
// pass `dataRoot:` explicitly when the test asserts on dataRoot-derived output
// and already has its own data root in scope.
//
// Same class as the `hermeticTrust()` helper in HermeticTrustSupport.swift.
func hermeticPersona(root: URL, dataRoot: URL? = nil) -> SwiftNativePersonaEngine {
    SwiftNativePersonaEngine(root: root, dataRoot: dataRoot ?? hermeticPersonaDataRoot())
}

/// Fresh, unique temp data root for a hermetic persona engine.
func hermeticPersonaDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChatOrchTests-personaData-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
