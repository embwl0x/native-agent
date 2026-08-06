// Wave 4 (de-mission phase 2) — the trust-policy DICT lane read-both seam.
//
// Split out of DeMissionWave4CrossDeviceSeamTests.swift because that file must
// NOT import TrustCenter: TrustCenter also vends a `TrustPolicy`, and the app
// module declares a struct named `NativeAgentApp`, so the collision cannot be
// resolved by module-qualifying the type.

import Foundation
import Testing

import NativeAgentCore
import PersistenceCore
import TrustCenter

@Test("4a dict: the normalize seam folds workshopPolicy onto the wire key")
func wave4TrustPolicyFoldKeepsWireKey() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wave4-trust-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("trust", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    // A saved policy written by a FUTURE build: only the new spelling on disk.
    let saved = #"{"permissionLevel":"balanced","workshopPolicy":{"enabled":false}}"#
    try Data(saved.utf8).write(
        to: root.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )

    let merged = await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicy()
    // Canonical result lives under the OLD key — every gate downstream keeps
    // reading exactly one spelling, and the normalized policy a 0.3.7 reader
    // sees is shaped the way it has always been.
    guard case .object(let block)? = merged[WorkshopPolicyBlockVocabulary.wireKey] else {
        Issue.record("normalized policy lost the workshop policy block entirely")
        return
    }
    #expect(block["enabled"] == .bool(false))
    #expect(merged[WorkshopPolicyBlockVocabulary.futureKey] == nil)
}
