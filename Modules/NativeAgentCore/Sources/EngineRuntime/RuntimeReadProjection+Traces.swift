import Foundation

extension RuntimeReadProjection {
    public static func getTraces<Failure: Error>(
        dataRoot: URL,
        partial: (Int) -> Failure,
        unavailable: (String) -> Failure
    ) async throws -> [RuntimeTrace] {
        switch CapabilityTraceFeed.read(dataRoot: dataRoot) {
        case .current(let traces):
            return traces
        case .sourceAbsent, .empty:
            // No trace source and a successfully read empty ledger are both
            // legitimate empty histories. They remain distinct to consumers
            // that request the stateful feed above.
            return []
        case .partial(_, let rejectedRows):
            throw partial(rejectedRows)
        case .unavailable(let detail):
            throw unavailable(detail)
        }
    }
}
