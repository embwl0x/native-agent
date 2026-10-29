import TurnTrace
import Foundation
import PersistenceCore
// Blueprint: | `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; asynchronous timeline over canonical turn evidence and standalone ledger rows |

/// Read model for canonical turn evidence and standalone traces in Capabilities.
/// Missing, empty, partially malformed, and unreadable evidence deliberately
/// remain distinct so the timeline never turns a failed read into "No traces".
public enum CapabilityTraceFeed {
    public static let maximumRows = 200
    public static let maximumReadBytes = 1_048_576

    public enum State: Equatable {
        case current([RuntimeTrace])
        case partial([RuntimeTrace], rejectedRows: Int)
        case sourceAbsent
        case empty
        case unavailable(String)

        public var traces: [RuntimeTrace] {
            switch self {
            case .current(let traces), .partial(let traces, _): traces
            case .sourceAbsent, .empty, .unavailable: []
            }
        }
    }

    public static func read(
        dataRoot root: URL,
        limit: Int = CapabilityTraceFeed.maximumRows,
        maximumReadBytes: Int = CapabilityTraceFeed.maximumReadBytes
    ) async -> State {
        guard limit > 0, maximumReadBytes > 0 else { return .empty }
        do {
            let evidence = try await TurnTraceRecentReader(dataRootOverride: root)
                .traceEvidence(maximumReadBytes: maximumReadBytes)
            if evidence.sourceAbsent { return .sourceAbsent }
            var decoded: [RuntimeTrace] = []
            var rejectedRows = evidence.report.malformedLineCount
            for row in evidence.rows {
                guard let fields = row.objectValue,
                      let id = fields["id"]?.stringValue,
                      let kind = fields["kind"]?.stringValue,
                      let title = fields["title"]?.stringValue,
                      fields["status"] == nil || fields["status"] == .null || fields["status"]?.stringValue != nil,
                      fields["createdAt"] == nil || fields["createdAt"] == .null || fields["createdAt"]?.stringValue != nil
                else { rejectedRows += 1; continue }
                decoded.append(RuntimeTrace(id: id, kind: kind, title: title,
                    status: fields["status"]?.stringValue, createdAt: fields["createdAt"]?.stringValue))
            }

            let traces = Array(decoded.suffix(limit).reversed())
            if traces.isEmpty, rejectedRows > 0 {
                return .unavailable("trace feed contains \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows") and no readable traces")
            }
            if traces.isEmpty { return .empty }
            return rejectedRows == 0 ? .current(traces) : .partial(traces, rejectedRows: rejectedRows)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
