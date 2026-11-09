import Foundation
import NativeAgentShared
// Blueprint: | `PanelFreshnessOwner.swift` | `PanelFreshnessOwner`: canonical panel receipts, ordered refresh admission and off-main face publication |

public actor PanelFreshnessOwner {
    public struct ReadOutcome: Sendable {
        public let failedEndpoints: [String]
        public let performedRead: Bool
        public let providerNeedsConnection: Bool

        public init(failedEndpoints: [String], performedRead: Bool = true, providerNeedsConnection: Bool = false) {
            self.failedEndpoints = failedEndpoints
            self.performedRead = performedRead
            self.providerNeedsConnection = providerNeedsConnection
        }
    }

    public struct ReadResult: Sendable {
        public let receipt: PanelRefreshStatus
        public let performedRead: Bool
        public let admitted: Bool
    }

    private let counts: CountsFeedProjection
    private var value = PanelFreshnessFace()
    private var reads: [String: LatestRead] = [:]
    private var active: [String: Set<UUID>] = [:]
    private let sidebarRead = LatestRead()
    private var detachedReads: [String: LatestRead] = [:]

    public init(counts: CountsFeedProjection) { self.counts = counts }

    public func refresh(panel id: String, operation: @Sendable () async -> ReadOutcome) async -> ReadResult {
        let read = reads[id] ?? LatestRead()
        reads[id] = read
        let identity = UUID()
        active[id, default: []].insert(identity)
        setReading(id)
        await counts.updatePanels(value)
        var admitted = false
        let receiptAndOutcome = await read.read({
            let outcome = await operation()
            return (Self.receipt(previous: value.panels[id]?.receipt, failures: outcome.failedEndpoints), outcome)
        }, publish: { result in
            let (receipt, outcome) = result
            admitted = true
            if outcome.performedRead {
                value.panels[id] = .init(receipt: receipt, isReading: true,
                                        staleNotice: Self.staleNotice(receipt, needsConnection: outcome.providerNeedsConnection))
            }
        })
        active[id]?.remove(identity)
        if active[id]?.isEmpty == true { active[id] = nil }
        setReading(id)
        await counts.updatePanels(value)
        return ReadResult(receipt: receiptAndOutcome.0, performedRead: receiptAndOutcome.1.performedRead, admitted: admitted)
    }

    public func refreshSidebar(operation: @Sendable () async -> [String]) async -> PanelRefreshStatus {
        let receipt = await sidebarRead.read({
            let failures = await operation()
            return Self.receipt(previous: value.sidebar, failures: failures)
        }, publish: { (status: PanelRefreshStatus) in value.sidebar = status })
        await counts.updatePanels(value)
        return receipt
    }

    public func refreshDetached(session id: String, operation: @Sendable () async -> [String]?) async {
        let read = detachedReads[id] ?? LatestRead()
        detachedReads[id] = read
        _ = await read.read({
            let failures = await operation()
            return failures.map { Self.receipt(previous: value.detached[id], failures: $0) }
        }, publish: { receipt in
            if let receipt { value.detached[id] = receipt }
        })
        await counts.updatePanels(value)
    }

    public func removeDetached(_ id: String) async {
        detachedReads.removeValue(forKey: id)?.write { value.detached[id] = nil }
        await counts.updatePanels(value)
    }

    public func detachedSessionIDs() -> Set<String> { Set(value.detached.keys) }

    private func setReading(_ id: String) {
        var panel = value.panels[id] ?? .init()
        panel.isReading = active[id]?.isEmpty == false
        value.panels[id] = panel
    }

    private static func receipt(previous: PanelRefreshStatus?, failures: [String]) -> PanelRefreshStatus {
        let date = Date()
        return PanelRefreshStatus(lastAttemptAt: date, lastSuccessAt: failures.isEmpty ? date : previous?.lastSuccessAt,
                                  failedEndpoints: failures)
    }

    private static func staleNotice(_ receipt: PanelRefreshStatus, needsConnection: Bool) -> String? {
        guard receipt.isStale else { return nil }
        guard let lastSuccess = receipt.lastSuccessAt else {
            return Set(receipt.failedEndpoints).isSubset(of: ["providers", "model catalog"]) && needsConnection
                ? "Nothing has loaded yet this session: no AI provider is connected. Connect one in Providers."
                : "Nothing has loaded yet this session: the last read failed."
        }
        let seconds = max(0, receipt.lastAttemptAt.timeIntervalSince(lastSuccess))
        guard let minutes = Int(exactly: floor(seconds / 60)) else {
            return "Showing retained data — its age is unavailable. Some information couldn't be refreshed."
        }
        let age: String
        if minutes < 1 { age = "moments ago" }
        else if minutes < 60 { age = "\(minutes)m ago" }
        else if minutes < 1_440 { age = "\(minutes / 60)h ago" }
        else { age = "\(minutes / 1_440)d ago" }
        return "Showing data from \(age) — some information couldn't be refreshed."
    }
}
