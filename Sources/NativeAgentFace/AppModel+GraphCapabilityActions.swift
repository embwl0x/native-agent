import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+GraphCapabilityActions.swift` | Research and export commands consume typed body replies |

enum ResearchSearchFailure: Error, Equatable {
    case blankQuery
    case requestFailed(String)
    var message: String {
        switch self {
        case .blankQuery: "Enter a research query."
        case .requestFailed(let message): message
        }
    }
}

struct ResearchResultFace: Equatable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let snippet: String
}

struct ResearchReplyFace: Equatable, Sendable {
    let results: [ResearchResultFace]
    let unresponsiveEngines: [String]
    let gaps: [String]

    @concurrent static func read(_ value: PartFace.Value) async throws -> Self {
        guard case .object(let fields) = value, case .array(let results)? = fields["results"] else {
            throw PartCallError(code: "research_reply_invalid", message: "The body did not return research results.")
        }
        func strings(_ key: String) throws -> [String] {
            guard case .array(let values)? = fields[key] else {
                throw PartCallError(code: "research_reply_invalid", message: "The research reply is missing " + key + ".")
            }
            return try values.map {
                guard case .string(let text) = $0 else {
                    throw PartCallError(code: "research_reply_invalid", message: "The research reply has an invalid " + key + " entry.")
                }
                return text
            }
        }
        let rows = try results.map { value -> ResearchResultFace in
            guard case .object(let row) = value, case .string(let title)? = row["title"],
                  case .string(let url)? = row["url"], case .string(let snippet)? = row["snippet"] else {
                throw PartCallError(code: "research_reply_invalid", message: "The body returned an invalid research row.")
            }
            return ResearchResultFace(title: title, url: url, snippet: snippet)
        }
        return Self(results: rows, unresponsiveEngines: try strings("unresponsive_engines"), gaps: try strings("gaps"))
    }
}

struct ProductionExportReceipt: Equatable {
    let id: String
    let path: String
    let sizeBytes: Int?
}

enum ProductionExportCreationOutcome: Equatable {
    case verified(ProductionExportReceipt)
    case failed(support: Bool, detail: String)
}

@MainActor extension AppModel {
    func search(_ query: String) async -> Result<ResearchReplyFace, ResearchSearchFailure> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankQuery) }
        do {
            let value = try FaceWindowReply.value(await client.act(.research(query: trimmed)))
            return .success(try await ResearchReplyFace.read(value))
        } catch {
            statusText = error.localizedDescription
            return .failure(.requestFailed(error.localizedDescription))
        }
    }

    func showVisibleBrowser() async {
        do {
            try FaceWindowReply.check(await client.act(.pageAct(.init(
                page: "browser", row: "", action: "open", value: nil, expectedRevision: nil, expectedCall: nil))))
        } catch { statusText = error.localizedDescription }
    }

    func createProductionExport(support: Bool = false) async -> ProductionExportCreationOutcome {
        do {
            let value = try FaceWindowReply.value(await client.act(.createProductionExport(support: support)))
            guard case .object(let row) = value, case .string(let id)? = row["id"],
                  case .string(let path)? = row["path"], case .int(let bytes)? = row["sizeBytes"],
                  let size = Int(exactly: bytes), size > 0 else {
                throw PartCallError(code: "export_reply_invalid", message: "The body did not return a verified export receipt.")
            }
            statusText = "Created and verified: " + path
            return .verified(.init(id: id, path: path, sizeBytes: size))
        } catch {
            statusText = error.localizedDescription
            return .failed(support: support, detail: error.localizedDescription)
        }
    }
}
