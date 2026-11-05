import Foundation
// Blueprint: | `TranscriptRow.swift` | The row a conversation's face is built from, the same on the Mac and the iPhone, and its groups: tool runs, mirrored cards, replies, quiet gaps, and the reply that hosts a run's cards |

/// One transcript row as both devices hold it: the Mac's own rows and the records the phone receives are the same row.
public protocol TranscriptRow: Sendable, Equatable {
    var id: String { get }
    var role: String { get }
    var content: String { get }
    var createdAt: String { get }
    var runId: String? { get }
    var source: String? { get }
    var metadata: ChatMessageMetadata? { get }
}

extension ChatMessageRecord: TranscriptRow {}

/// Consecutive tool rows fold as one run; a mirrored card is its own run; every other row is its own group. `gapAbove` marks an hour of
/// quiet before the group.
public struct TranscriptGroup<Row: TranscriptRow>: Identifiable, Sendable {
    public var id: String
    public var messages: [Row]
    public var isToolGroup: Bool
    public var gapAbove: Date?

    public init(id: String, messages: [Row], isToolGroup: Bool, gapAbove: Date? = nil) {
        (self.id, self.messages, self.isToolGroup, self.gapAbove) = (id, messages, isToolGroup, gapAbove)
    }
}

public enum TranscriptGrouping {
    public static let quietGap: TimeInterval = 60 * 60

    public static func groups<Row: TranscriptRow>(_ rows: some Sequence<Row>) -> [TranscriptGroup<Row>] {
        var result: [TranscriptGroup<Row>] = []
        var toolRun: [Row] = []
        func flushTools() {
            guard let first = toolRun.first else { return }
            // The run keeps its first tool's identity as it grows.
            result.append(TranscriptGroup(id: "toolrun-" + first.id, messages: toolRun, isToolGroup: true))
            toolRun = []
        }
        for row in rows {
            // Tool-summary system rows are memory aids, never bubbles.
            if row.role == "system" && row.content.hasPrefix("[tool:") { continue }
            if row.metadata?.interactionMirror != nil {
                flushTools()
                result.append(TranscriptGroup(id: row.id, messages: [row], isToolGroup: true))
            } else if row.role == "tool" {
                toolRun.append(row)
            } else {
                flushTools()
                result.append(TranscriptGroup(id: row.id, messages: [row], isToolGroup: false))
            }
        }
        flushTools()
        var previous: Date?
        for index in result.indices {
            let group = result[index]
            if let first = group.messages.first.flatMap({ UserDisplayFormatters.parseISOTimestamp($0.createdAt) }), let previous,
               first.timeIntervalSince(previous) > quietGap {
                result[index].gapAbove = first
            }
            previous = group.messages.last.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) } ?? previous
        }
        return result
    }

    /// Cards persist on tool rows and mount under the next readable reply: reply id → the run's rows whose cards it hosts.
    public static func cardHosts<Row: TranscriptRow>(_ groups: some RandomAccessCollection<TranscriptGroup<Row>>) -> [String: [String]] {
        var hosts: [String: [String]] = [:]
        var index = groups.startIndex
        while index != groups.endIndex {
            let next = groups.index(after: index)
            defer { index = next }
            guard groups[index].isToolGroup, next != groups.endIndex else { continue }
            let following = groups[next]
            guard !following.isToolGroup, let reply = following.messages.first, reply.role == "assistant",
                  readableText(reply.content).contains(where: { !$0.isWhitespace }) else { continue }
            hosts[reply.id, default: []] += groups[index].messages.filter { $0.metadata?.interactionMirror == nil }.map(\.id)
        }
        return hosts
    }

    /// A reply's words without its protocol `<tool_use …>` markers, which draw nothing.
    public static func readableText(_ content: String) -> String {
        guard content.contains("<tool_use") else { return content }
        var visible = ""
        var rest = Substring(content)
        while let open = rest.range(of: "<tool_use") {
            visible += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "</tool_use>") {
                rest = after[close.upperBound...]
            } else if let end = after.range(of: ">") {
                rest = after[end.upperBound...]
            } else {
                rest = after[after.endIndex...]
            }
        }
        visible += rest
        return visible
    }
}
