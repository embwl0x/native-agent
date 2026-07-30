import XCTest
@testable import NativeAgentMobile

@MainActor
final class CloudKitPairingBoundaryTests: XCTestCase {
    private let suppressionKey = "mobile.pairing.ignoredCloudKitSecretHash"

    func testCloudKitPairingRejectsNonCanonicalSecretLengths() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        UserDefaults.standard.removeObject(forKey: suppressionKey)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        XCTAssertFalse(store.applyCloudKitPairingSecret(Data(repeating: 1, count: 31)))
        XCTAssertEqual(store.iCloudPairingSecret, previousSecret)

        XCTAssertFalse(store.applyCloudKitPairingSecret(Data(repeating: 1, count: 33)))
        XCTAssertEqual(store.iCloudPairingSecret, previousSecret)
    }

    func testCloudKitPairingChangesPublishedStateOnlyAfterKeychainCommit() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        UserDefaults.standard.removeObject(forKey: suppressionKey)
        let secret = Data(repeating: 0x5A, count: 32)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        let applied = store.applyCloudKitPairingSecret(secret)
        if applied {
            XCTAssertEqual(store.iCloudPairingSecret, secret)
            XCTAssertTrue(store.isICloudPaired)
            XCTAssertTrue(store.isPaired)
        } else {
            // Unsigned simulator test hosts cannot write this app's Keychain
            // item. The transaction must leave published state unchanged.
            XCTAssertEqual(store.iCloudPairingSecret, previousSecret)
            XCTAssertEqual(store.isICloudPaired, previousPaired)
        }
    }

    func testClearIgnoresSameSecretButAllowsRotatedSecret() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        let oldSecret = Data(repeating: 0x41, count: 32)
        let rotatedSecret = Data(repeating: 0x42, count: 32)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        UserDefaults.standard.removeObject(forKey: suppressionKey)
        store.iCloudPairingSecret = oldSecret
        store.isICloudPaired = true
        store.clearPairing()

        XCTAssertFalse(store.shouldAcceptCloudKitPairingSecret(oldSecret))
        XCTAssertTrue(store.shouldAcceptCloudKitPairingSecret(rotatedSecret))
    }

    private func restoreSuppression(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: suppressionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: suppressionKey)
        }
    }
}
