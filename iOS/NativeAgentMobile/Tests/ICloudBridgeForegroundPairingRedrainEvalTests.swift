import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.bridge.foregroundPairingRedrain`.
///
/// A foreground pairing retry can make an already-downloaded signed message
/// deliverable. The bridge must re-drain immediately after that durable commit.
final class ICloudBridgeForegroundPairingRedrainEvalTests: XCTestCase {
    func test_foregroundPairingCommitRedrainsOnlyAfterTheStoreIsPaired() throws {
        let source = try MobileEvalSources.mobileSource("iCloudBridge.swift")
        let handler = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "cloudKitAppDidBecomeActive",
                keyword: "@objc private nonisolated func",
                in: source
            )
        )

        XCTAssertTrue(handler.contains("if self.pairingStore?.isPaired != true"))
        XCTAssertTrue(handler.contains("let pairingApplied = await transport.drainPairing()"))
        XCTAssertTrue(handler.contains("guard pairingApplied, self.pairingStore?.isPaired == true else { return }"))
        XCTAssertTrue(handler.contains("await self.drainDeviceTransport()"))

        let pairingDrain = try XCTUnwrap(handler.range(of: "await transport.drainPairing()"))
        let redrain = try XCTUnwrap(handler.range(of: "await self.drainDeviceTransport()"))
        XCTAssertLessThan(pairingDrain.lowerBound, redrain.lowerBound)
    }
}
