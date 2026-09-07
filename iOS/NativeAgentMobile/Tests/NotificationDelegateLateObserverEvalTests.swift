import Foundation
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.sync / ios.app.notificationDelegate`.
@MainActor
final class NotificationDelegateLateObserverEvalTests: XCTestCase {
    private let openActivityKey = "NativeAgentMobile.pendingOpenActivityFromNotification"
    private let pendingScreenKey = "NativeAgentMobile.pendingNotificationScreen"
    private var savedValues: [(String, Any?)] = []

    override func setUp() {
        super.setUp()
        savedValues = [openActivityKey, pendingScreenKey].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        UserDefaults.standard.removeObject(forKey: openActivityKey)
        UserDefaults.standard.removeObject(forKey: pendingScreenKey)
    }

    override func tearDown() {
        for (key, value) in savedValues {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func test_lateObserverFallsBackToThePersistedTapIntent() async throws {
        let center = NotificationCenter()
        let immediatePost = expectation(description: "immediate observer receives the delegate post")
        let immediateObserver = center.addObserver(
            forName: .nativeagentOpenActivity,
            object: nil,
            queue: nil
        ) { note in
            XCTAssertEqual(note.userInfo?["screen"] as? String, "skills")
            immediatePost.fulfill()
        }
        defer { center.removeObserver(immediateObserver) }

        NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: "skills")
        center.post(
            name: .nativeagentOpenActivity,
            object: nil,
            userInfo: ["screen": "skills"]
        )
        await fulfillment(of: [immediatePost], timeout: 0.1)

        // This models a cold launch where ContentView installs its observer
        // after the delegate's ephemeral post has already completed.
        try await Task.sleep(nanoseconds: 400_000_000)
        let lateObserver = center.addObserver(
            forName: .nativeagentOpenActivity,
            object: nil,
            queue: nil
        ) { _ in }
        defer { center.removeObserver(lateObserver) }

        XCTAssertEqual(
            NativeAgentNotificationLaunchIntent.consumePendingScreen(),
            "skills",
            "a late ContentView mount must read the persisted intent, not rely on replaying NotificationCenter"
        )
    }

    func test_contentViewConsumesThePersistedIntentOnAppearance() throws {
        let source = try MobileEvalSources.mobileSource("ContentView.swift")
        let appSource = try MobileEvalSources.mobileSource("MobilePushNotifications.swift")
        let consumer = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "consumePendingNotificationOpenIfNeeded()",
                keyword: "private func",
                in: source
            )
        )

        XCTAssertTrue(source.contains(".onAppear {\n            consumePendingNotificationOpenIfNeeded()"))
        XCTAssertTrue(consumer.contains("NativeAgentNotificationLaunchIntent.consumePendingScreen()"))
        XCTAssertTrue(consumer.contains("openActivityFromNotification(screen: screen)"))

        let delegate = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "NativeAgentNotificationDelegate",
                keyword: "final class",
                in: appSource
            )
        )
        let persisted = try XCTUnwrap(delegate.range(of: "markOpenActivityPending"))
        let ephemeralPost = try XCTUnwrap(delegate.range(of: "NotificationCenter.default.post"))
        XCTAssertLessThan(persisted.lowerBound, ephemeralPost.lowerBound)
        XCTAssertFalse(delegate.contains("Task.sleep"))
    }
}
