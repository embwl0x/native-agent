import XCTest
@testable import MacIntegration

final class MacIntegrationOperatorOverrideTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func path(_ root: URL) -> URL {
        root.appendingPathComponent("security/mac_integration_permissions.json")
    }

    private func document(_ root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path(root))) as? [String: Any])
    }

    private func write(_ document: [String: Any], root: URL) throws {
        try FileManager.default.createDirectory(at: path(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document).write(to: path(root), options: .atomic)
    }

    func testExplicitOffWinsOverFullMacWhileUntouchedDefaultsAndReadStayAvailable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacIntegrationPermissionStore(dataRoot: root)
        let fresh = await store.allows("mail", mode: .write, fullMacAdmitted: true)
        XCTAssertTrue(fresh)
        for id in ["mail", "messages", "contacts"] {
            // OFF is intentional even when the stored default was already OFF.
            try await store.set(integrationId: id, read: true, write: false)
            let write = await store.allows(id, mode: .write, fullMacAdmitted: true)
            let read = await store.allows(id, mode: .read, fullMacAdmitted: true)
            XCTAssertFalse(write)
            XCTAssertTrue(read)
        }
        let unrelated = await store.allows("calendar", mode: .write, fullMacAdmitted: true)
        XCTAssertTrue(unrelated)
    }

    func testAgentCannotRegrantOperatorOffButExplicitSignedOperatorCan() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacIntegrationPermissionStore(dataRoot: root)
        try await store.set(integrationId: "mail", read: true, write: false)
        let before = try Data(contentsOf: path(root))
        for additive in [false, true] {
            do {
                _ = try await store.setWithReceipt(integrationId: "mail", read: false, write: true,
                    actionID: UUID().uuidString, surface: "chat", provenance: .agent(interactionID: "card"),
                    onlyAddingAxes: additive)
                XCTFail("agent must not override an operator revocation")
            } catch {
                XCTAssertEqual((error as NSError).code, -4)
            }
            XCTAssertEqual(try Data(contentsOf: path(root)), before)
        }
        _ = try await store.setWithReceipt(integrationId: "mail", read: false, write: true,
            actionID: "human-grant", surface: "ios_icloud", provenance: .signedIOS(clientID: "paired"),
            onlyAddingAxes: true)
        let write = await store.allows("mail", mode: .write, fullMacAdmitted: true)
        let read = await store.allows("mail", mode: .read)
        XCTAssertTrue(write)
        XCTAssertTrue(read)
    }

    func testAdditiveReadCardsNeitherInventNorClearWriteRevocation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacIntegrationPermissionStore(dataRoot: root)
        _ = try await store.setWithReceipt(integrationId: "mail", read: true, write: false,
            actionID: "read-only", surface: "chat", provenance: .local(), onlyAddingAxes: true)
        let untouched = await store.allows("mail", mode: .write, fullMacAdmitted: true)
        XCTAssertTrue(untouched)
        try await store.set(integrationId: "mail", read: false, write: false)
        _ = try await store.setWithReceipt(integrationId: "mail", read: true, write: false,
            actionID: "read-again", surface: "chat", provenance: .local(), onlyAddingAxes: true)
        let off = await store.allows("mail", mode: .write, fullMacAdmitted: true)
        let read = await store.allows("mail", mode: .read)
        XCTAssertFalse(off)
        XCTAssertTrue(read)
    }

    func testLegacyRevocationMigratesBeforeReceiptRotationWithoutReadSideWrites() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacIntegrationPermissionStore(dataRoot: root)
        try await store.set(integrationId: "mail", read: true, write: true)
        try await store.set(integrationId: "mail", read: true, write: false)
        var legacy = try document(root)
        legacy.removeValue(forKey: "_operatorOverrides")
        var receipts = try XCTUnwrap(legacy["_mutationReceipts"] as? [[String: Any]])
        let unrelated: [String: Any] = [
            "kind": "mac_integration_permission_mutation.v1", "actionId": "filler", "surface": "mac_ui",
            "integrationId": "calendar", "before": ["read": true, "write": false],
            "after": ["read": true, "write": false],
            "provenance": ["kind": "local", "decidedBy": "mac_operator"], "recordedAt": "2026-09-21T22:41:20Z"
        ]
        // Both original receipts will leave the bounded journal next mutation.
        for index in 0..<500 {
            var row = unrelated
            row["actionId"] = "filler-\(index)"
            receipts.append(row)
        }
        legacy["_mutationReceipts"] = receipts
        try write(legacy, root: root)
        let before = try Data(contentsOf: path(root))
        let revoked = await store.allows("mail", mode: .write, fullMacAdmitted: true)
        XCTAssertFalse(revoked)
        XCTAssertEqual(try Data(contentsOf: path(root)), before)
        let untouched = await store.allows("calendar", mode: .write, fullMacAdmitted: true)
        XCTAssertTrue(untouched)
        try await store.set(integrationId: "music", read: true, write: true)
        let migrated = try document(root)
        XCTAssertEqual((migrated["_mutationReceipts"] as? [[String: Any]])?.count, 500)
        let reopened = MacIntegrationPermissionStore(dataRoot: root)
        let stillOff = await reopened.allows("mail", mode: .write, fullMacAdmitted: true)
        XCTAssertFalse(stillOff)
    }

    func testMalformedOverrideAuthorityFailsClosedAndCannotBeOverwritten() async throws {
        let fixtures: [Any] = [NSNull(), ["mail": ["write": "false"]], ["spotlight": ["write": false]], ["mail": ["send": false]]]
        for metadata in fixtures {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            try write(["_operatorOverrides": metadata], root: root)
            let before = try Data(contentsOf: path(root))
            let store = MacIntegrationPermissionStore(dataRoot: root)
            let allowed = await store.allows("mail", mode: .write, fullMacAdmitted: true)
            XCTAssertFalse(allowed)
            do {
                try await store.set(integrationId: "mail", read: true, write: true)
                XCTFail("damaged authority must remain unavailable")
            } catch {
                XCTAssertEqual(error as? MacIntegrationPermissionStoreError, .malformedStore)
            }
            XCTAssertEqual(try Data(contentsOf: path(root)), before)
        }
    }
}
