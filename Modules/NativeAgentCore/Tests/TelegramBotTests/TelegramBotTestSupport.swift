import Foundation
import PersistenceCore

func makeResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

let tokenStr = "TKN123"

let discardTurnCardSend: @Sendable (String, Int, String) async throws -> Int = { _, _, _ in
    9_999
}

let discardTurnCardEdit: @Sendable (String, Int, Int, String) async throws -> Void = { _, _, _, _ in }

func readTelegramJSONL(_ root: URL, _ name: String) throws -> [JSONValue] {
    let path = root
        .appendingPathComponent("telegram", isDirectory: true)
        .appendingPathComponent(name)
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else {
        return []
    }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        try? JSONValue.parse(Data(String(line).utf8))
    }
}
