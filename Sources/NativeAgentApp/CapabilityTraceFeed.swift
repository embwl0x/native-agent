import Foundation
import PersistenceCore

/// Read model for the exact durable trace ledger presented in Capabilities.
/// Missing, empty, partially malformed, and unreadable evidence deliberately
/// remain distinct so the timeline never turns a failed read into "No traces".
enum CapabilityTraceFeed {
    static let relativePath = "traces/events.jsonl"
    static let maximumRows = 200
    static let maximumReadBytes = 1_048_576

    enum State: Equatable {
        case current([RuntimeTrace])
        case partial([RuntimeTrace], rejectedRows: Int)
        case sourceAbsent
        case empty
        case unavailable(String)

        var traces: [RuntimeTrace] {
            switch self {
            case .current(let traces), .partial(let traces, _): traces
            case .sourceAbsent, .empty, .unavailable: []
            }
        }
    }

    static func path(in root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func read(
        dataRoot root: URL,
        limit: Int = CapabilityTraceFeed.maximumRows,
        maximumReadBytes: Int = CapabilityTraceFeed.maximumReadBytes
    ) -> State {
        guard limit > 0, maximumReadBytes > 0 else { return .empty }
        let path = path(in: root)
        guard FileManager.default.fileExists(atPath: path.path) else { return .sourceAbsent }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
                return .unavailable("trace feed size is unavailable")
            }
            guard fileSize > 0 else { return .empty }

            let byteLimit = UInt64(maximumReadBytes)
            let bytesToRead = min(fileSize, byteLimit)
            let droppedPrefix = fileSize > bytesToRead
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            if droppedPrefix {
                try handle.seek(toOffset: fileSize - bytesToRead)
            }
            let data = handle.readData(ofLength: Int(bytesToRead))
            guard let text = String(data: data, encoding: .utf8) else {
                return .unavailable("trace feed is not valid UTF-8")
            }

            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            if droppedPrefix, !lines.isEmpty { lines.removeFirst() }

            let decoder = JSONDecoder.nativeAgent
            var decoded: [(index: Int, trace: RuntimeTrace)] = []
            var rejectedRows = 0
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      let trace = try? decoder.decode(RuntimeTrace.self, from: data)
                else {
                    rejectedRows += 1
                    continue
                }
                decoded.append((index, trace))
            }

            let traces = decoded.suffix(limit).sorted {
                let lhsDate = $0.trace.createdAt ?? ""
                let rhsDate = $1.trace.createdAt ?? ""
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.index > $1.index
            }.map(\.trace)
            if traces.isEmpty {
                return rejectedRows == 0
                    ? .empty
                    : .unavailable("trace feed contains \(rejectedRows) malformed \(rejectedRows == 1 ? "row" : "rows") and no readable traces")
            }
            return rejectedRows == 0 ? .current(traces) : .partial(traces, rejectedRows: rejectedRows)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
