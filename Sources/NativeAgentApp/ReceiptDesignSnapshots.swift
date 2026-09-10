#if DEBUG
import Foundation
import SwiftUI
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// Production receipt views fed by real stream event shapes; never dispatches tools.
@MainActor
enum ReceiptDesignSnapshots {
    static func render(to directory: URL) throws {
        let directory = directory.appendingPathComponent("production")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = try samples()
        for scheme in [ColorScheme.light, .dark] {
            for compact in [false, true] {
                for expanded in [false, true] {
                    // Expansion uses the same vertical transcript. Split evidence
                    // into consecutive pages when the open detail needs room.
                    let pages = expanded ? [Array(samples.prefix(4)), Array(samples.dropFirst(4))] : [samples]
                    for (page, rows) in pages.enumerated() {
                        try BotsShelfSnapshots.write(ReceiptTranscript(samples: rows,
                            expanded: expanded && page == 0)
                            .environment(\.dynamicTypeSize, compact ? .accessibility5 : .large),
                            name: "\(expanded ? "expanded" : "collapsed")-\(scheme == .dark ? "dark" : "light")-\(compact ? "1024-largest" : "1280")-\(page + 1)",
                            size: CGSize(width: compact ? 1024 : 1280, height: compact ? 700 : 800),
                            scheme: scheme, directory: directory, scale: 1)
                    }
                }
            }
        }
    }

    static func samples() throws -> [ReceiptSample] {
        func sample(_ name: String, _ input: String, _ output: String?) throws -> ReceiptSample {
            ReceiptSample(call: .toolUse(name: name, input: try JSONValue.parse(Data(input.utf8))),
                result: try output.map { .toolResult(name: name, output: try JSONValue.parse(Data($0.utf8))) })
        }
        return try [
            sample("read_file", #"{"path":"notes.txt"}"#, #""Meeting: Thursday at 10.""#),
            sample("write_file", #"{"path":"notes.txt","content":"Updated"}"#,
                #"{"status":"failed","error":"tool denied: fileAccess=read_only blocks write_file","reason":"tool denied: fileAccess=read_only blocks write_file"}"#),
            sample("desk_breakdown", #"{"parent":"1","children":[{"title":"Draft"},{"title":"Review"}]}"#,
                #"{"status":"partial","reason":"creating child 2 'Review': storage unavailable","parent":"1","created":["1.1 Draft"]}"#),
            sample("mcp__notes__search", #"{"query":"meeting"}"#,
                #"{"status":"failed","error":"streamClosed","reason":"streamClosed"}"#),
            sample("read", #"{"path":"report.pdf"}"#, nil),
            sample("mcp__archive__x17", #"{"id":"A17"}"#,
                #"{"content":[{"type":"text","text":"Receipt A17"}],"isError":false}"#),
            sample("read_file", #"{"path":"report.txt"}"#,
                #"{"ok":false,"status":"failed","error_code":"read_failed","reason":"Could not read the file: Input/output error."}"#),
        ]
    }
}

struct ReceiptSample {
    let call: TurnStreamEvent
    let result: TurnStreamEvent?

    var name: String {
        guard case .toolUse(let name, _) = call else { return "unknown" }
        return name
    }
    var input: JSONValue {
        guard case .toolUse(_, let input) = call else { return .null }
        return input
    }
    var output: JSONValue? {
        guard case .toolResult(_, let output) = result else { return nil }
        return output
    }
    func message() throws -> ChatMessage {
        var metadata: [String: JSONValue] = [
            "kind": .string("tool_use"), "toolName": .string(name),
            "inputJSON": .string(try input.serialize(pretty: false)),
        ]
        if let output {
            metadata["resultSummary"] = .string(try output.serialize(pretty: false))
            metadata["ok"] = .bool(ChatToolOutcome.exactResultClass(output) != .failed)
        }
        let row = JSONValue.object(["role": .string("tool"), "metadata": .object(metadata)])
        return try JSONDecoder().decode(ChatMessage.self, from: Data(try row.serialize(pretty: false).utf8))
    }
}

private struct ReceiptTranscript: View {
    let samples: [ReceiptSample]
    let expanded: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("The agent · Results so far").font(.headline).padding(.bottom, 4)
            ForEach(samples.indices, id: \.self) { index in
                if let message = try? samples[index].message() {
                    ToolPillView(message: message, initiallyExpanded: expanded && index == 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme == .dark ? Color(white: 0.085) : Color(white: 0.965))
    }
}
#endif
