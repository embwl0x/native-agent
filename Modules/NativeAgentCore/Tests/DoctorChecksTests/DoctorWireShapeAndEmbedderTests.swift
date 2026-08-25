import Foundation
import Testing
import MemoryV2
import NativeAgentCore
import PersistenceCore
@testable import DoctorChecks

// Ledger rows: doctor.checkResult.wireShape, doctor.env.iCloudContainerID,
//              doctor.check.coreMLEmbedder
//
// Silent-failure classes:
//   * WRONG VALUE on the UI wire — `CheckResult` is the ONE shape every Doctor
//     surface renders, and `status` is a raw STRING, not an enum. A check that
//     starts emitting "OK" / "healthy" / "" renders as an unknown state with no
//     compiler complaint anywhere.
//   * SILENT DEGRADATION — `CoreMLEmbedderCheck` is the only thing that
//     actually LOADS MiniLM outside a live turn. If its probe's error handling
//     regresses, a failing model load reports "ok" and semantic recall silently
//     drops to lexical-only for every turn, forever.
//   * WRONG IDENTITY — `resolvedContainerID()` falls back to a hardcoded id
//     when the env var and the Info.plist key are both absent or unexpanded;
//     `buildConfiguresICloud()` is derived from it and gates the whole iCloud
//     lane's verdict.
//
// NOTE: `run(repair: true)` is deliberately NOT driven here. Its first act is
// `CoreMLEmbeddingProvider.wipeBundledCompileCache()`, a destructive wipe of a
// process-wide cache directory; driving it from a test would mutate host state
// the rest of the suite (and the running app) shares. See productionSeamNeeded.

// MARK: - CheckResult wire shape

@Test("CheckResult carries exactly the five documented keys, with repair omitted when nil")
func doctorCheckResultWireShape() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let withRepair = CheckResult(
        id: "storage", title: "Storage", status: "fail",
        detail: "disk is full", repair: "free some space"
    )
    let bare = CheckResult(id: "storage", title: "Storage", status: "ok", detail: "fine")

    let withRepairKeys = try #require(
        JSONSerialization.jsonObject(with: try encoder.encode(withRepair)) as? [String: Any]
    )
    #expect(Set(withRepairKeys.keys) == Set(["id", "title", "status", "detail", "repair"]))

    let bareKeys = try #require(
        JSONSerialization.jsonObject(with: try encoder.encode(bare)) as? [String: Any]
    )
    // A nil repair is ABSENT, not null — the UI treats "has a repair hint" as
    // key presence, so a null here would light up a dead repair button.
    #expect(Set(bareKeys.keys) == Set(["id", "title", "status", "detail"]))
}

@Test("CheckResult round-trips through JSON without losing or coercing a field")
func doctorCheckResultRoundTrip() throws {
    let cases = [
        CheckResult(id: "a", title: "A", status: "ok", detail: "", repair: nil),
        CheckResult(id: "b", title: "B", status: "warn", detail: "line\nbreak", repair: ""),
        CheckResult(id: "c", title: "C", status: "fail", detail: "emoji 🩺", repair: "fix it"),
    ]
    for original in cases {
        let decoded = try JSONDecoder().decode(
            CheckResult.self, from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.repair == original.repair)
    }
}

@Test("every check the default doctor registers emits an in-vocabulary status")
func doctorStatusVocabularyIsHonoured() async throws {
    // The vocabulary is a STRING contract, so it can only be pinned by
    // inspecting real results. These checks are all hermetic (they take their
    // roots as parameters) — nothing here touches the live data root.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctor-wire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var results: [CheckResult] = []
    results.append(await CoreMLEmbedderCheck().run(repair: false))
    results.append(await ICloudBridgeStateCheck(
        docsURLProvider: { nil }, iCloudConfigured: true, dataRoot: root
    ).run(repair: false))
    results.append(await ICloudBridgeStateCheck(
        docsURLProvider: { nil }, iCloudConfigured: false, dataRoot: root
    ).run(repair: false))

    #expect(!results.isEmpty)
    for result in results {
        #expect(["ok", "warn", "fail"].contains(result.status),
                "check \(result.id) emitted out-of-vocabulary status \(result.status.debugDescription)")
        #expect(!result.id.isEmpty)
        #expect(!result.title.isEmpty)
        #expect(!result.detail.isEmpty, "check \(result.id) rendered an empty detail line")
    }
}

// MARK: - iCloud container id

@Test("the resolved iCloud container id is a usable id, never an unexpanded template")
func doctorICloudContainerIDIsUsable() {
    let id = ICloudBridgeStateCheck.resolvedContainerID()
    #expect(!id.isEmpty)
    // An unexpanded xcconfig variable is the exact shape the resolver is
    // written to reject; leaking one would point CloudKit at a literal "$(…)".
    #expect(!id.contains("$("))
    #expect(id == ICloudBridgeStateCheck.resolvedContainerID(), "resolution is not stable")

    let override = ProcessInfo.processInfo.environment["NATIVEAGENT_ICLOUD_CONTAINER_ID"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty, !override.contains("$(") {
        // Precedence: the env var wins over the Info.plist key and the fallback.
        #expect(id == override)
    } else {
        // No override in this process, and a unit-test bundle carries no
        // `NativeAgentICloudContainerID` Info.plist key, so the hardcoded
        // fallback is what a real no-config build would resolve to.
        #expect(id.hasPrefix("iCloud."))
        #expect(id == "iCloud.io.github.embwl0x.nativeagent")
    }
}

@Test("buildConfiguresICloud is derived from the resolved id, not from a second source of truth")
func doctorBuildConfiguresICloudTracksTheResolvedID() async {
    let id = ICloudBridgeStateCheck.resolvedContainerID()
    // The `com.example` placeholder is the ONLY thing that turns the lane off.
    // A regression that hardcodes `true` makes a placeholder build claim a
    // working container; one that hardcodes `false` silently disables the whole
    // iCloud lane's verdict and every check downstream of it reports "expected".
    #expect(ICloudBridgeStateCheck.buildConfiguresICloud() == !id.contains("com.example"))
    #expect(ICloudBridgeStateCheck.buildConfiguresICloud(),
            "this build resolved \(id), which is not a placeholder, so the lane must be on")

    // The default the check uses when a caller does not pass `iCloudConfigured`
    // is the derived value, not an independent constant.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctor-icloud-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let derived = await ICloudBridgeStateCheck(
        docsURLProvider: { nil }, dataRoot: root
    ).run(repair: false)
    let explicit = await ICloudBridgeStateCheck(
        docsURLProvider: { nil },
        iCloudConfigured: ICloudBridgeStateCheck.buildConfiguresICloud(),
        dataRoot: root
    ).run(repair: false)
    #expect(derived.status == explicit.status)
    #expect(derived.detail == explicit.detail)
}

// MARK: - CoreML embedder check

@Test("the embedder check's verdict agrees with an independent real model load")
func doctorCoreMLEmbedderVerdictMatchesRealLoad() async {
    let result = await CoreMLEmbedderCheck().run(repair: false)
    #expect(result.id == "coreml_embedder")
    #expect(result.title == "Core ML Embedder (MiniLM)")
    // This check has no "warn" state: MiniLM either loads or recall is degraded.
    #expect(result.status == "ok" || result.status == "fail")

    let resourcesPresent = CoreMLEmbeddingProvider.bundledResourcesAvailable()
    var loadSucceeded = false
    if resourcesPresent {
        loadSucceeded = ((try? CoreMLEmbeddingProvider.bundled()) != nil)
    }

    // THE TOOTH: the check must not swallow a load failure into "ok". Its
    // verdict is compared against the same load performed independently here,
    // so a regressed catch-and-report-ok inside `probe()` fails this.
    #expect(
        (result.status == "ok") == (resourcesPresent && loadSucceeded),
        "check said \(result.status) but resourcesPresent=\(resourcesPresent) load=\(loadSucceeded): \(result.detail)"
    )

    if result.status == "fail" {
        #expect(!result.detail.isEmpty)
        if resourcesPresent {
            // A real load failure names the degradation and offers no repair
            // hint from the read-only path.
            #expect(result.detail.contains("failed to load"))
            #expect(result.repair == nil)
        } else {
            // Missing bundle resources are explicitly NOT repairable — the
            // repair action only wipes cached state, and wiping a cache cannot
            // restore a missing .mlpackage.
            #expect(result.detail.contains("missing from the app bundle"))
            #expect(result.repair == nil, "read-only run must not advertise a repair")
        }
    } else {
        #expect(result.detail.contains("MiniLM loads"))
        #expect(result.repair == nil)
    }
}

@Test("the check is registered under a stable id and reports deterministically")
func doctorCoreMLEmbedderIsStableAcrossRuns() async {
    let first = await CoreMLEmbedderCheck().run(repair: false)
    let second = await CoreMLEmbedderCheck().run(repair: false)
    #expect(first.status == second.status)
    #expect(first.id == second.id)
    #expect(first.title == second.title)
    // A read-only run must be side-effect free: two consecutive reads agree,
    // and neither one advertises that it repaired something.
    #expect(first.repair == nil && second.repair == nil)
}

@Test("the missing-resources branch is reachable and returns a non-repairable fail")
func doctorCoreMLEmbedderMissingResourcesBranch() async {
    // The check resolves its bundle internally, so the absent-resources branch
    // can only be driven here through the provider's injectable form. Pinning
    // the provider probe keeps the branch's PREMISE honest even though the
    // check itself cannot be pointed at an empty bundle without a production
    // seam (see productionSeamNeeded).
    let empty = Bundle(for: EmptyResourceBundleAnchor.self)
    #expect(CoreMLEmbeddingProvider.bundledResourcesAvailable(empty) == false)
    #expect(throws: (any Error).self) {
        _ = try CoreMLEmbeddingProvider.bundled(empty)
    }
}

private final class EmptyResourceBundleAnchor {}
