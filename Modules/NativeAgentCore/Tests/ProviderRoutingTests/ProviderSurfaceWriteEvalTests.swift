import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore
import PersistenceCore

// MARK: - Ledger rows
//   providers.saveSurfacePreference (REPORTS-ONLY — the raw-pin path used by
//     the Mac picker's seedMissingControls contract had no test for the
//     seedMissingControls=true / overwriteExisting=false combination, and
//     nothing proved it validates active-state before publishing a pin)
//   providers.saveModelConfig      (REPORTS-ONLY — the JSONValue-envelope entry
//     point behind BOTH command surfaces, Telegram provider ops and the chat
//     `model` command. Its only test asserts it throws on corrupt bytes.
//     Untested until now: inferProvider silently pinning a PROVIDER the user
//     never named, and the snake_case/camelCase key aliases where one wrong
//     spelling drops that field while the rest of the save commits.)
//
// All roots are fresh temp dirs; both picker paths are pinned explicitly.

private struct SurfaceWritePaths {
    let root: URL
    let surfaces: URL
    let active: URL
}

private func makeSurfaceWritePaths(
    surfacesBody: String = "{}",
    activeBody: String = "{}"
) throws -> SurfaceWritePaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderSurfaceWriteEval-\(UUID().uuidString)", isDirectory: true)
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    let surfaces = providers.appendingPathComponent("surfaces.json")
    let active = providers.appendingPathComponent("active.json")
    try Data(surfacesBody.utf8).write(to: surfaces)
    try Data(activeBody.utf8).write(to: active)
    return SurfaceWritePaths(root: root, surfaces: surfaces, active: active)
}

private func makeSurfaceWriteRouting(_ paths: SurfaceWritePaths) -> SwiftNativeProviderRouting {
    SwiftNativeProviderRouting(
        dataRoot: paths.root,
        surfacesPathOverride: paths.surfaces,
        activeProviderPathOverride: paths.active
    )
}

private func readObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Suite("Provider surface writes: saveSurfacePreference / saveModelConfig")
struct ProviderSurfaceWriteEvalTests {

    // MARK: providers.saveSurfacePreference

    /// Envelope: the raw-pin path validates ACTIVE state before publishing a
    /// model pin. With active.json corrupt the call throws and surfaces.json
    /// stays BYTE-IDENTICAL — a pin must never be published on top of a picker
    /// pair that cannot be read back.
    @Test func saveSurfacePreference_failsClosedOnCorruptActiveState() async throws {
        let paths = try makeSurfaceWritePaths(
            surfacesBody: #"{"chat":{"model":"claude-opus-4-8"}}"#,
            activeBody: "[]"  // valid JSON, wrong SHAPE — the checked read rejects it
        )
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let before = try Data(contentsOf: paths.surfaces)
        let routing = makeSurfaceWriteRouting(paths)

        await #expect(throws: (any Error).self) {
            try await routing.saveSurfacePreference(
                surface: "chat",
                model: "gpt-5.5",
                reasoningEffort: nil,
                serviceTier: nil
            )
        }
        #expect(try Data(contentsOf: paths.surfaces) == before,
                "a rejected pin must leave surfaces.json byte-identical")
    }

    /// Envelope for the Mac picker's documented seed contract, both branches:
    ///   (a) an EXISTING entry with overwriteExisting=false is left alone
    ///       entirely — byte-identical, user pin and controls untouched;
    ///   (b) a MISSING entry is seeded with the model plus exactly the two
    ///       control keys, so the picker never renders a half-populated row.
    @Test func seedMissingControls_seedsOnlyAbsentSurfaces_andNeverEditsAnExistingPin() async throws {
        let paths = try makeSurfaceWritePaths(
            surfacesBody: #"{"chat":{"model":"claude-opus-4-8"}}"#
        )
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let before = try Data(contentsOf: paths.surfaces)
        let routing = makeSurfaceWriteRouting(paths)

        // (a) existing entry — seed must be a no-op even though the entry is
        //     missing both control keys.
        try await routing.saveSurfacePreference(
            surface: "chat",
            model: "gpt-5.5",
            reasoningEffort: "max",
            serviceTier: "priority",
            seedMissingControls: true,
            overwriteExisting: false
        )
        #expect(try Data(contentsOf: paths.surfaces) == before,
                "overwriteExisting=false must leave an existing pin byte-identical")

        // (b) absent entry — seeded with model + BOTH controls.
        try await routing.saveSurfacePreference(
            surface: "telegram",
            model: "gpt-5.5",
            reasoningEffort: nil,
            serviceTier: nil,
            seedMissingControls: true,
            overwriteExisting: false
        )
        let after = try readObject(paths.surfaces)
        let telegram = try #require(after["telegram"] as? [String: Any])
        #expect(telegram["model"] as? String == "gpt-5.5")
        #expect(telegram["reasoningEffort"] as? String == "medium")
        #expect(telegram["serviceTier"] as? String == "default")
        // The pre-existing surface still holds its own pin.
        let chat = try #require(after["chat"] as? [String: Any])
        #expect(chat["model"] as? String == "claude-opus-4-8")
        #expect(chat["reasoningEffort"] == nil, "seeding telegram must not touch chat")
    }

    // MARK: providers.saveModelConfig

    /// Envelope: `inferProvider: true` is a TWO-FILE commit — the model pin and
    /// the inferred active-provider row land together. The Telegram ops path
    /// sets this unconditionally whenever a model is supplied, so this is the
    /// mechanism by which a provider the user never named gets pinned.
    @Test func saveModelConfig_inferProvider_writesBothTheModelPinAndTheActiveRow() async throws {
        let paths = try makeSurfaceWritePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let routing = makeSurfaceWriteRouting(paths)

        _ = try await routing.saveModelConfig(.object([
            "surface": .string("chat"),
            "model": .string("claude-opus-4-8"),
            "inferProvider": .bool(true),
        ]))

        let surfaces = try readObject(paths.surfaces)
        let active = try readObject(paths.active)
        #expect((surfaces["chat"] as? [String: Any])?["model"] as? String == "claude-opus-4-8")
        // Not an exact-value pin plucked from air: the inferred id IS the
        // router's own model→provider answer, so the two seams must agree.
        let inferred = try #require(routing.inferProviderForModel("claude-opus-4-8"))
        #expect(active["chat"] as? String == inferred,
                "inferProvider must publish the SAME provider the router infers")
        #expect(await routing.activeProvidersForSurfaces()["chat"] == inferred)
    }

    /// The other half of that envelope: WITHOUT `inferProvider`, active.json is
    /// left byte-identical. A model pick must not move the provider pin behind
    /// the user's back.
    @Test func saveModelConfig_withoutInferProvider_leavesActiveProvidersUntouched() async throws {
        let paths = try makeSurfaceWritePaths(activeBody: #"{"chat":"openai_oauth_direct"}"#)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let before = try Data(contentsOf: paths.active)
        let routing = makeSurfaceWriteRouting(paths)

        _ = try await routing.saveModelConfig(.object([
            "surface": .string("chat"),
            "model": .string("claude-opus-4-8"),
        ]))

        #expect((try readObject(paths.surfaces)["chat"] as? [String: Any])?["model"] as? String
                == "claude-opus-4-8")
        #expect(try Data(contentsOf: paths.active) == before,
                "a bare model pick must not rewrite the active-provider pin")
    }

    /// Envelope: the snake_case and camelCase spellings of the execution
    /// controls are ALIASES — same field, same landed value. A caller that
    /// spells one field the "wrong" way must not have that field silently
    /// dropped while the rest of the envelope commits. Written on two
    /// DIFFERENT surfaces with MISMATCHED spellings so a test that used one
    /// spelling for both write and read could not pass vacuously.
    @Test func saveModelConfig_snakeCaseAndCamelCaseControlKeysAreAliases() async throws {
        let paths = try makeSurfaceWritePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let routing = makeSurfaceWriteRouting(paths)

        _ = try await routing.saveModelConfig(.object([
            "surface": .string("chat"),
            "model": .string("gpt-5.5"),
            "reasoning_effort": .string("high"),
            "service_tier": .string("priority"),
        ]))
        _ = try await routing.saveModelConfig(.object([
            "surface": .string("telegram"),
            "model": .string("gpt-5.5"),
            "reasoningEffort": .string("high"),
            "serviceTier": .string("priority"),
        ]))

        let surfaces = try readObject(paths.surfaces)
        let snake = try #require(surfaces["chat"] as? [String: Any])
        let camel = try #require(surfaces["telegram"] as? [String: Any])
        #expect(snake["reasoningEffort"] as? String == "high")
        #expect(snake["serviceTier"] as? String == "priority")
        #expect(
            (snake["reasoningEffort"] as? String) == (camel["reasoningEffort"] as? String),
            "reasoning_effort and reasoningEffort must land the same value"
        )
        #expect(
            (snake["serviceTier"] as? String) == (camel["serviceTier"] as? String),
            "service_tier and serviceTier must land the same value"
        )

        // And the same values round-trip back through the read path.
        let prefs = try await routing.computeModelPreferences()
        #expect(prefs["chat"]?.reasoningEffort == "high")
        #expect(prefs["telegram"]?.reasoningEffort == "high")
    }

    /// Envelope: the 0.3.x `missions` spelling arriving on a COMMAND surface
    /// writes the CANONICAL `workshop` key — and never leaves the file
    /// carrying two entries that disagree about the same surface.
    @Test func saveModelConfig_legacyMissionsSpellingWritesTheCanonicalWorkshopKey() async throws {
        let paths = try makeSurfaceWritePaths(
            surfacesBody: #"{"missions":{"model":"claude-opus-4-8"}}"#
        )
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let routing = makeSurfaceWriteRouting(paths)

        _ = try await routing.saveModelConfig(.object([
            "surface": .string("missions"),
            "model": .string("gpt-5.5"),
        ]))

        let surfaces = try readObject(paths.surfaces)
        #expect((surfaces["workshop"] as? [String: Any])?["model"] as? String == "gpt-5.5")
        #expect(surfaces["missions"] == nil,
                "the legacy key must be retired by the write that replaces it")
    }

    /// Envelope: an unknown surface is REJECTED — the envelope entry point is
    /// reachable from Telegram and the chat command line, so an unregistered
    /// surface string must not create a picker key nothing serves.
    @Test func saveModelConfig_rejectsAnUnregisteredSurface() async throws {
        let paths = try makeSurfaceWritePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let before = try Data(contentsOf: paths.surfaces)
        let routing = makeSurfaceWriteRouting(paths)

        await #expect(throws: (any Error).self) {
            _ = try await routing.saveModelConfig(.object([
                "surface": .string("cognition_cue"),  // a real live orphan pin key
                "model": .string("gpt-5.5"),
            ]))
        }
        await #expect(throws: (any Error).self) {
            _ = try await routing.saveModelConfig(.object([
                "model": .string("gpt-5.5"),  // no surface at all
            ]))
        }
        #expect(try Data(contentsOf: paths.surfaces) == before)
    }
}
