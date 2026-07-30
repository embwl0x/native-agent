import Testing
import Foundation
@testable import MacAssistantStatus
import NativeAgentCore
import PersistenceCore

// MARK: - Test helpers

private func trustLoader(macEnabled: Bool = true, notificationsAllowed: Bool? = nil) -> @Sendable () async -> [String: JSONValue] {
    var policy: [String: JSONValue] = ["enabled": .bool(macEnabled)]
    if let n = notificationsAllowed { policy["notifications_allowed"] = .bool(n) }
    let trust: [String: JSONValue] = ["macControlPolicy": .object(policy)]
    return { trust }
}

private func extractAccess(_ result: MacAssistantStatusResult, id: String) -> [String: JSONValue]? {
    for v in result.access {
        if case .object(let obj) = v, case .string(let s)? = obj["id"], s == id {
            return obj
        }
    }
    return nil
}

private func extractTemplate(_ result: MacAssistantStatusResult, id: String) -> [String: JSONValue]? {
    for v in result.watchTemplates {
        if case .object(let obj) = v, case .string(let s)? = obj["id"], s == id {
            return obj
        }
    }
    return nil
}

private func statusOf(_ obj: [String: JSONValue]?) -> String? {
    if case .string(let s)? = obj?["status"] { return s }
    return nil
}

// MARK: - Tests

@Test func macAssistantStatusComposesAccessItems() async throws {
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true, notificationsAllowed: true)
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "mac_control")) == "ready")
    #expect(statusOf(extractAccess(result, id: "mac_notifications")) == "ready")
}

@Test func macAssistantStatusMacDisabled() async throws {
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: false, notificationsAllowed: true)
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "mac_control")) == "needs_policy")
    #expect(result.blockedAccessCount > 0)
    #expect(result.status == "attention")
}

@Test func macAssistantStatusEmailProofGate() async throws {
    let verified = StaticConnectorProofProvider(proofs: [
        "email": ["verified": .bool(true)],
    ])
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        proofs: verified
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "gmail")) == "ready")

    let unverified = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        proofs: StaticConnectorProofProvider()
    )
    let result2 = try await unverified.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result2, id: "gmail")) == "needs_proof")
}

@Test func macAssistantStatusCalendarProofGate() async throws {
    let verified = StaticConnectorProofProvider(proofs: [
        "calendar": ["verified": .bool(true)],
    ])
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        proofs: verified
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "google_calendar")) == "ready")

    let unverified = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true)
    )
    let result2 = try await unverified.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result2, id: "google_calendar")) == "needs_proof")
}

@Test func macAssistantStatusDispatcherToolAvailability() async throws {
    let available = StaticDispatcherToolAvailabilityProvider(availableTools: ["mail_list_recent"])
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        dispatcherTools: available
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "local_mail")) == "probe_needed")

    let none = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true)
    )
    let result2 = try await none.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result2, id: "local_mail")) == "needs_setup")
}

@Test func macAssistantStatusLocalPIMProviderCanMarkReadyOrNeedsPermission() async throws {
    let local = StaticLocalPIMStatusProvider(statuses: [
        "local_calendar": ["status": .string("ready")],
        "local_reminders": [
            "status": .string("needs_permission"),
            "nextStep": .string("Grant Reminders access"),
        ],
    ])
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        localPIM: local
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "local_calendar")) == "ready")
    #expect(statusOf(extractAccess(result, id: "local_reminders")) == "needs_permission")
    #expect(statusOf(extractTemplate(result, id: "local_calendar_watch")) == "ready")
    #expect(statusOf(extractTemplate(result, id: "local_reminders_watch")) == "needs_permission")
}

@Test func macAssistantStatusMobilePushReady() async throws {
    let ready = StaticMobilePushStatusProvider(value: ["status": .string("ready")])
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        push: ready
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result, id: "iphone_push")) == "ready")

    let tokenOnly = StaticMobilePushStatusProvider(value: ["tokenConfigured": .bool(true)])
    let client2 = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        push: tokenOnly
    )
    let result2 = try await client2.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result2, id: "iphone_push")) == "ready")

    let none = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true)
    )
    let result3 = try await none.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractAccess(result3, id: "iphone_push")) == "needs_setup")
}

@Test func macAssistantStatusWatchTemplateStatusComposition() async throws {
    // gmail=ready + iphone_push=ready -> gmail_unread_digest=ready
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        proofs: StaticConnectorProofProvider(proofs: ["email": ["verified": .bool(true)]]),
        push: StaticMobilePushStatusProvider(value: ["status": .string("ready")])
    )
    let result = try await client.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractTemplate(result, id: "gmail_unread_digest")) == "ready")

    // gmail=needs_proof -> template falls to needs_proof
    let client2 = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true),
        push: StaticMobilePushStatusProvider(value: ["status": .string("ready")])
    )
    let result2 = try await client2.macAssistantStatus(lightweight: false)
    #expect(statusOf(extractTemplate(result2, id: "gmail_unread_digest")) == "needs_proof")
}

@Test func macAssistantStatusLightweightTruncation() async throws {
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true)
    )
    let result = try await client.macAssistantStatus(lightweight: true)
    #expect(result.access.count == 5)
    #expect(result.watchTemplates.count == 3)

    let allowed: Set<String> = ["id", "title", "status", "setupRoute", "nextStep"]
    for v in result.access {
        guard case .object(let obj) = v else { Issue.record("expected object"); continue }
        for k in obj.keys {
            #expect(allowed.contains(k), "unexpected lightweight access key \(k)")
        }
    }
}

@Test func macAssistantStatusFullVsLightweightSummary() async throws {
    let client = SwiftNativeMacAssistantStatusClient(
        loadTrustPolicy: trustLoader(macEnabled: true)
    )
    let full = try await client.macAssistantStatus(lightweight: false)
    let light = try await client.macAssistantStatus(lightweight: true)
    let expectedSummary = "Mac assistant watch setup is manifest-only here; no watcher jobs are created until scheduler.schedule_job is called."
    #expect(full.summary == expectedSummary)
    #expect(light.summary == expectedSummary)
    let expectedActions = ["scheduler.schedule_job", "scheduler.create_job", "scheduler.list_jobs", "scheduler.cancel_job"]
    #expect(full.schedulerActions == expectedActions)
    #expect(light.schedulerActions == expectedActions)
    #expect(full.createsJobs == false)
    #expect(light.createsJobs == false)
    guard case .object(let lazy) = full.lazyContract else {
        Issue.record("lazyContract not an object"); return
    }
    #expect(Set(lazy.keys) == ["chatInjection", "watchBodiesLoaded", "jobCreation", "providerProbe"])
}

@Test func makeMacAssistantStatusClientRoutesSwiftNative() async throws {
    let client = makeMacAssistantStatusClient(
        loadTrustPolicy: { [:] }
    )
    #expect(client is SwiftNativeMacAssistantStatusClient)
}
