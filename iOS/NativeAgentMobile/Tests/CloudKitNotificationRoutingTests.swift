import Testing
@testable import NativeAgentMobile

struct CloudKitNotificationRoutingTests {
    @Test
    func visualCloudKitSubscriptionSuppressesLocalDuplicate() {
        #expect(
            NativeAgentCloudKitNotificationRouting.shouldScheduleLocalCopy(
                transportPresentsVisualNotification: true
            ) == false
        )
    }

    @Test
    func localFallbackRemainsWhenVisualSubscriptionIsUnavailable() {
        #expect(
            NativeAgentCloudKitNotificationRouting.shouldScheduleLocalCopy(
                transportPresentsVisualNotification: false
            )
        )
    }
}
