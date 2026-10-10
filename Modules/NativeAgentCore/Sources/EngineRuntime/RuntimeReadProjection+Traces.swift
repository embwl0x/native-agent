import Foundation

/// A caller asking for only trace rows must not receive a success-shaped
/// empty array when the canonical evidence feed was damaged or only partially
/// readable. Mounted timeline consumers use `CapabilityTraceFeed.State`
/// directly and can render the richer state.
public enum RuntimeReadError: LocalizedError, Equatable {
    case traceEvidencePartial(rejectedRows: Int)
    case traceEvidenceUnavailable(String)
    case unreadableFeed(String)

    public var errorDescription: String? {
        switch self {
        case .traceEvidencePartial(let rejectedRows):
            return "Trace evidence is partial: \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows") were withheld."
        case .traceEvidenceUnavailable(let detail):
            return "Trace evidence is unavailable: \(detail)"
        case .unreadableFeed(let detail):
            return detail
        }
    }
}

extension RuntimeReadProjection {
    public static func getTraces(dataRoot: URL) async throws -> [RuntimeTrace] {
        switch CapabilityTraceFeed.read(dataRoot: dataRoot) {
        case .current(let traces):
            return traces
        case .sourceAbsent, .empty:
            // No trace source and a successfully read empty ledger are both
            // legitimate empty histories. They remain distinct to consumers
            // that request the stateful feed above.
            return []
        case .partial(_, let rejectedRows):
            throw RuntimeReadError.traceEvidencePartial(rejectedRows: rejectedRows)
        case .unavailable(let detail):
            throw RuntimeReadError.traceEvidenceUnavailable(detail)
        }
    }
}
