// Wave 5 (de-mission phase 2) — TrustCenter half.
//
// 5b: `SwiftNativeSecurityCenter.fullMacYoloLocalSurfaces` is now built from
//     `WorkshopSurfaceVocabulary.gateSpellings` instead of an open-coded list.
//     Dropping a spelling here makes full-mac yolo quietly stop elevating
//     Workshop builder steps on a 0.3.x-spelled turn — a silent demotion, not
//     an error — so the legacy spellings are pinned explicitly.
//
// 5c: the Apple Shortcuts connector's `start_mission` action. See the comment
//     on the last test for what is (and is not) wired.

import Testing
import Foundation

import NativeAgentCore
@testable import TrustCenter

@Test("5b full-mac yolo: legacy missions/mission surfaces are still local-eligible")
func wave5FullMacYoloLocalSurfacesAcceptLegacySpellings() {
    for spelling in ["workshop", "missions", "mission"] {
        #expect(SwiftNativeSecurityCenter.fullMacYoloLocalSurfaces.contains(spelling))
    }
    // Every app-owned local operator surface is explicit. New action surfaces
    // must join this set rather than infer authority from a caller string.
    for other in [
        "chat", "desk", "codex-bridge", "claude-bridge",
        "connector_action", "nextgen_action", "mcp_ui", "native_actions",
    ] {
        #expect(SwiftNativeSecurityCenter.fullMacYoloLocalSurfaces.contains(other))
    }
    #expect(SwiftNativeSecurityCenter.fullMacYoloLocalSurfaces.count == 11)
    // Negative controls: remote surfaces must NOT leak into the LOCAL set —
    // they require concrete authenticated origin evidence through the remote
    // authority path instead.
    for remote in ["telegram", "slack", "ios", "icloud", "remote"] {
        #expect(!SwiftNativeSecurityCenter.fullMacYoloLocalSurfaces.contains(remote))
    }
}

@Test("5c: start_mission and start_execution name the SAME connector action")
func wave5ConnectorStartActionVocabulary() {
    // `data/connectors/registry.json` is LIVE persisted data and still carries
    // `start_mission` on the `shortcuts` connector. This is the single declared
    // place that equivalence lives, so any FUTURE reader that dispatches on a
    // connector action name has one function to call instead of an open-coded
    // string compare.
    //
    // Load-bearing today? No — and deliberately not faked into looking so.
    // Verified 2026-08-06 across Sources/, Modules/, iOS/ and script/: nothing
    // compares, matches, or dispatches on the per-connector `actions` array.
    // `ConnectorRecord.actions` (Sources/NativeAgentApp/Models/
    // DreamReleaseModels.swift:83,101) is decoded, carried through the model,
    // re-encoded into the iCloud `connectors.json` snapshot, and never branched
    // on; the connector-action dispatcher
    // (NativeClient+ConnectorActions.swift:53) matches against the STATIC
    // `connectorActionDescriptors()` table, which contains no Workshop-named
    // action at all. The only writer of an `actions` array is the blank-slate
    // seed `defaultConnectorCatalog()` (NativeClient+LocalAPI.swift:192-251),
    // and it already seeds `shortcuts` with `["run"]` — so a fresh install
    // never produces either spelling.
    #expect(WorkshopStartConnectorAction.matches("start_mission", "start_execution"))
    #expect(WorkshopStartConnectorAction.canonicalAction("start_mission") == "start_execution")
    #expect(WorkshopStartConnectorAction.canonicalAction(" start_mission ") == "start_execution")
    #expect(WorkshopStartConnectorAction.canonicalAction("start_execution") == "start_execution")
    // Negative controls: every other connector action passes through untouched
    // and must not collide.
    for other in ["run_doctor", "send_chat", "get_status", "run"] {
        #expect(WorkshopStartConnectorAction.canonicalAction(other) == other)
        #expect(!WorkshopStartConnectorAction.matches(other, "start_execution"))
    }
}
