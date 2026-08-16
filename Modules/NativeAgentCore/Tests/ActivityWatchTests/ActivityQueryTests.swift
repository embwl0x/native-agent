import Foundation
import PersistenceCore
import Testing
@testable import ActivityWatch

private func queryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityQueryTests-\(UUID().uuidString)", isDirectory: true)
}

@Test("QUERY PRIVACY: capture consent does not imply model access consent")
func modelAccessIsSeparateConsent() async throws {
    let root = queryRoot()
    try ActivityPolicyStore(dataRoot: root).save(ActivityPolicy(captureEnabled: true))
    let service = ActivityQueryService(dataRoot: root)
    await #expect(throws: ActivityQueryService.QueryError.modelAccessDisabled) {
        try await service.run(.init(from: 1_700_000_000, to: 1_700_000_100))
    }
}

@Test("QUERY BOUNDS: non-finite and oversized windows are refused before store work")
func queryRangeIsBounded() async throws {
    let root = queryRoot()
    try ActivityPolicyStore(dataRoot: root).save(ActivityPolicy(
        captureEnabled: true,
        allowModelAccess: true
    ))
    let service = ActivityQueryService(dataRoot: root)
    await #expect(throws: ActivityQueryService.QueryError.self) {
        try await service.run(.init(from: .nan, to: 1_700_000_100))
    }
    await #expect(throws: ActivityQueryService.QueryError.self) {
        try await service.run(.init(
            from: 1_700_000_000,
            to: 1_700_000_000 + ActivityQueryService.maximumRangeSeconds + 1
        ))
    }
}

@Test("QUERY PARSING: extreme numeric instants are rejected")
func extremeInstantsAreRejected() {
    #expect(ActivityQueryService.parseInstant("nan", timezone: .current) == nil)
    #expect(ActivityQueryService.parseInstant("1e100", timezone: .current) == nil)
    #expect(ActivityQueryService.parseInstant("-1", timezone: .current) == nil)
}
