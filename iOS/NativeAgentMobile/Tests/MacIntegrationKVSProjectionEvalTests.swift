import Foundation
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.sync / ios.macIntegrationPermissions.kvsProjection`.
@MainActor
final class MacIntegrationKVSProjectionEvalTests: XCTestCase {
    func test_validRowsSurviveWhileEveryMalformedKVSRowIsNamedAndFailsClosed() throws {
        let sync = MacIntegrationPermissionsSync(
            projectionLoader: {
                [
                    "calendar": ["read": true, "write": false],
                    "contacts": ["read": NSNumber(value: 1)],
                    "mail": [String: Any](),
                    "notify_mac": "not a dictionary",
                ]
            },
            observesExternalChanges: false
        )

        XCTAssertEqual(sync.permissions["calendar"], ["read": true, "write": false])
        XCTAssertNil(sync.permissions["contacts"])
        XCTAssertNil(sync.permissions["mail"])
        XCTAssertNil(sync.permissions["notify_mac"])

        let error = try XCTUnwrap(sync.projectionError)
        XCTAssertTrue(error.contains("3 malformed rows"))
        for id in ["contacts", "mail", "notify_mac"] {
            XCTAssertTrue(error.contains(id), "Malformed KVS row \(id) must be named for recovery")
        }
        XCTAssertFalse(sync.get(id: "calendar", mode: "read"), "A partially malformed authority projection must fail closed")
    }

    func test_iOSReaderAndMacWriterUseTheSameKVSKey() throws {
        let macWriter = try MobileEvalSources.repoFile("Sources/NativeAgentApp/MacIntegrationICloudBridge.swift")
        let keys = MobileEvalSources.matches(#"static let kvsKey\s*=\s*"([^"]+)""#, in: macWriter)

        XCTAssertEqual(keys, [MacIntegrationPermissionsSync.kvsKey])
    }
}
