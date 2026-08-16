import XCTest
@testable import MacIntegration

final class MacIntegrationTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func storePath(_ root: URL) -> URL {
        root.appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("mac_integration_permissions.json")
    }

    private func write(_ text: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: path, options: .atomic)
    }

    func testDefaultsTableIsHonored() {
        // Read-capable surfaces default ON for read.
        XCTAssertTrue(MacIntegrationID.defaultPermission(for: MacIntegrationID.calendar).read)
        XCTAssertTrue(MacIntegrationID.defaultPermission(for: MacIntegrationID.spotlight).read)
        // Sensitive surfaces default OFF for write.
        XCTAssertFalse(MacIntegrationID.defaultPermission(for: MacIntegrationID.contacts).write)
        XCTAssertFalse(MacIntegrationID.defaultPermission(for: MacIntegrationID.mail).write)
        XCTAssertFalse(MacIntegrationID.defaultPermission(for: MacIntegrationID.messages).write)
        // Notifications + scheduler default ON for write.
        XCTAssertTrue(MacIntegrationID.defaultPermission(for: MacIntegrationID.notifyMac).write)
        XCTAssertTrue(MacIntegrationID.defaultPermission(for: MacIntegrationID.notifyMobile).write)
        XCTAssertTrue(MacIntegrationID.defaultPermission(for: MacIntegrationID.scheduler).write)
        // Axis support.
        XCTAssertFalse(MacIntegrationID.supportsWrite(MacIntegrationID.spotlight))
        XCTAssertFalse(MacIntegrationID.supportsRead(MacIntegrationID.notifyMac))
        XCTAssertFalse(MacIntegrationID.supportsRead(MacIntegrationID.notifyMobile))
        XCTAssertFalse(MacIntegrationID.supportsRead(MacIntegrationID.scheduler))
    }

    func testDefaultFallbackOnEmptyStore() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        // Default fallback works: read of calendar with nothing written ⇒ true.
        let allowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        XCTAssertTrue(allowed)
        let checked = try? await store.currentChecked()
        XCTAssertEqual(checked?[MacIntegrationID.notifyMobile]?.write, true)
    }

    func testSetThenAllowsReflectsWrite() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        try await store.set(integrationId: MacIntegrationID.calendar, read: false, write: false)
        let readAllowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        XCTAssertFalse(readAllowed)
        let writeAllowed = await store.allows(MacIntegrationID.calendar, mode: .write)
        XCTAssertFalse(writeAllowed)
    }

    func testExistingMalformedRootIsUnavailableAndDeniesDefaults() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write("[]", to: storePath(tmp))

        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        do {
            _ = try await store.currentChecked()
            XCTFail("expected invalid root to be unavailable")
        } catch {
            XCTAssertEqual(error as? MacIntegrationPermissionStoreError, .invalidRoot)
        }
        let calendarAllowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        let mobileNotifyAllowed = await store.allows(MacIntegrationID.notifyMobile, mode: .write)
        let closedProjection = await store.current()
        XCTAssertFalse(calendarAllowed)
        XCTAssertFalse(mobileNotifyAllowed)
        XCTAssertEqual(closedProjection[MacIntegrationID.calendar]?.read, false)
    }

    func testMalformedKnownRowsAndAxisTypesAreUnavailable() async throws {
        let fixtures: [(String, MacIntegrationPermissionStoreError)] = [
            (#"{"calendar":"yes"}"#, .invalidKnownEntry(MacIntegrationID.calendar)),
            (#"{"calendar":{"read":1,"write":false}}"#,
             .invalidKnownAxis(integrationID: MacIntegrationID.calendar, axis: "read")),
        ]

        for (json, expected) in fixtures {
            let tmp = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: tmp) }
            try write(json, to: storePath(tmp))
            let store = MacIntegrationPermissionStore(dataRoot: tmp)
            do {
                _ = try await store.currentChecked()
                XCTFail("expected malformed known permission to be unavailable")
            } catch {
                XCTAssertEqual(error as? MacIntegrationPermissionStoreError, expected)
            }
        }
    }

    func testUnreadableStoreIsUnavailable() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = storePath(tmp)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        do {
            _ = try await store.currentChecked()
            XCTFail("expected unreadable store to be unavailable")
        } catch {
            XCTAssertEqual(error as? MacIntegrationPermissionStoreError, .unreadableStore)
        }
        let allowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        XCTAssertFalse(allowed)
    }

    func testMutationRefusesCorruptStoreAndPreservesExactBytes() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = storePath(tmp)
        let damaged = Data(#"{"calendar":{"read":"true"}}"#.utf8)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try damaged.write(to: path, options: .atomic)

        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        do {
            try await store.set(integrationId: MacIntegrationID.calendar, read: false, write: false)
            XCTFail("expected mutation refusal")
        } catch {
            XCTAssertEqual(
                error as? MacIntegrationPermissionStoreError,
                .invalidKnownAxis(integrationID: MacIntegrationID.calendar, axis: "read")
            )
        }
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }

    func testValidRepairRestoresAvailabilityAndFutureMutation() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = storePath(tmp)
        try write("not-json", to: path)
        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        let corruptAllowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        XCTAssertFalse(corruptAllowed)

        try write(#"{"calendar":{"read":true,"write":false}}"#, to: path)
        let repairedAllowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        XCTAssertTrue(repairedAllowed)
        try await store.set(
            integrationId: MacIntegrationID.calendar,
            read: false,
            write: false
        )
        let mutatedAllowed = await store.allows(MacIntegrationID.calendar, mode: .read)
        XCTAssertFalse(mutatedAllowed)
    }

    func testSignedIOSMutationPersistsAxesAndProvenanceInOneGeneration() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        let result = try await store.setWithReceipt(
            integrationId: MacIntegrationID.mail,
            read: false,
            write: true,
            actionID: "action-123",
            surface: "ios_icloud",
            provenance: .signedIOS(clientID: "paired-client-1")
        )
        XCTAssertEqual(result, MacIntegrationPermission(read: false, write: true))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storePath(tmp))) as? [String: Any]
        )
        let mail = try XCTUnwrap(object[MacIntegrationID.mail] as? [String: Any])
        XCTAssertEqual(mail["read"] as? Bool, false)
        XCTAssertEqual(mail["write"] as? Bool, true)
        let receipts = try XCTUnwrap(object["_mutationReceipts"] as? [[String: Any]])
        let receipt = try XCTUnwrap(receipts.last)
        XCTAssertEqual(receipt["actionId"] as? String, "action-123")
        XCTAssertEqual(receipt["surface"] as? String, "ios_icloud")
        XCTAssertEqual((receipt["before"] as? [String: Any])?["read"] as? Bool, true)
        XCTAssertEqual((receipt["after"] as? [String: Any])?["write"] as? Bool, true)
        let provenance = try XCTUnwrap(receipt["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["kind"] as? String, "signed_ios")
        XCTAssertEqual(provenance["clientId"] as? String, "paired-client-1")
    }

    func testInvalidReceiptProvenanceLeavesPermissionBytesUnchanged() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        try await store.set(integrationId: MacIntegrationID.calendar, read: true, write: false)
        let before = try Data(contentsOf: storePath(tmp))

        do {
            _ = try await store.setWithReceipt(
                integrationId: MacIntegrationID.calendar,
                read: false,
                write: true,
                actionID: "",
                surface: "ios_icloud",
                provenance: .signedIOS(clientID: "paired-client-1")
            )
            XCTFail("expected invalid receipt refusal")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: storePath(tmp)), before)
    }

    func testRetriedRemoteActionCannotRevertANewerChoice() async throws {
        let tmp = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = MacIntegrationPermissionStore(dataRoot: tmp)
        _ = try await store.setWithReceipt(
            integrationId: MacIntegrationID.messages,
            read: true,
            write: true,
            actionID: "remote-action-1",
            surface: "ios_icloud",
            provenance: .signedIOS(clientID: "paired-client-1")
        )
        _ = try await store.setWithReceipt(
            integrationId: MacIntegrationID.messages,
            read: false,
            write: false,
            actionID: "local-action-2",
            surface: "mac_ui",
            provenance: .local()
        )
        let replay = try await store.setWithReceipt(
            integrationId: MacIntegrationID.messages,
            read: true,
            write: true,
            actionID: "remote-action-1",
            surface: "ios_icloud",
            provenance: .signedIOS(clientID: "paired-client-1")
        )
        XCTAssertEqual(replay, MacIntegrationPermission(read: false, write: false))
        do {
            _ = try await store.setWithReceipt(
                integrationId: MacIntegrationID.messages,
                read: false,
                write: true,
                actionID: "remote-action-1",
                surface: "ios_icloud",
                provenance: .signedIOS(clientID: "paired-client-1")
            )
            XCTFail("expected action-id payload mismatch refusal")
        } catch { }
        let recovered = try await store.currentChecked()[MacIntegrationID.messages]
        XCTAssertEqual(recovered, MacIntegrationPermission(read: false, write: false))
    }
}
