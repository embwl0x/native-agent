import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Research

private struct CoverageHTTP: ResearchHTTPClient {
    let body: Data
    let contentType: String?
    func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?) {
        #expect(timeout == 30)
        return (200, body, contentType)
    }
}

@Suite struct ReadPageCoverageTests {
    private func fetch(body: Data, type: String?) async throws -> ResearchFetchRecord {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await SwiftNativeResearchClient(dataRoot: root, http: CoverageHTTP(body: body, contentType: type))
            .fetchURL("https://page.example/source")
    }

    @Test func mixedCaseHTMLAndUnknownFinalURLAreHonest() async throws {
        let record = try await fetch(body: Data("<p>Hello</p><script>hidden()</script>".utf8), type: "Text/HTML; charset=UTF-8")
        #expect(record.text == "Hello")
        guard case .object(let coverage)? = record.coverage else { Issue.record("Missing coverage"); return }
        #expect(coverage["final_url"] == .null, "Legacy injected transport cannot establish a redirect destination")
        #expect(coverage["complete"] == .bool(true))
        #expect(coverage["extraction_status"] == .string("html_text"))
    }

    @Test(arguments: ["application/pdf", "image/png", "application/octet-stream"])
    func binaryIsNotPresentedAsReadText(type: String) async throws {
        let record = try await fetch(body: Data([0xFF, 0xD8, 0x00]), type: type)
        #expect(record.text.isEmpty)
        guard case .object(let coverage)? = record.coverage else { Issue.record("Missing coverage"); return }
        #expect(coverage["extraction_status"] == .string("unsupported_content_type"))
        #expect(coverage["response_complete"] == .bool(true))
        #expect(coverage["complete"] == .bool(false))
    }

    @Test func byteClippingIsVisibleWithoutASecondTextClip() async throws {
        let record = try await fetch(body: Data(repeating: 65, count: 1_000_010), type: "text/plain")
        #expect(record.text.count == 1_000_000)
        guard case .object(let coverage)? = record.coverage else { Issue.record("Missing coverage"); return }
        #expect(coverage["body_truncated"] == .bool(true))
        #expect(coverage["response_complete"] == .bool(false))
        #expect(coverage["retained_body_bytes"] == .int(1_000_000))
        #expect(coverage["observed_body_bytes"] == .int(1_000_010))
        #expect(coverage["text_truncated"] == .bool(false))
        #expect(coverage["complete"] == .bool(false))
    }

    @Test func clippedUTF8ScalarDoesNotDestroyReadablePrefix() async throws {
        let body = Data((String(repeating: "a", count: 999_999) + "é tail").utf8)
        let record = try await fetch(body: body, type: "text/plain")
        #expect(record.text.count == 999_999)
        #expect(!record.text.contains("�"))
        guard case .object(let coverage)? = record.coverage else { Issue.record("Missing coverage"); return }
        #expect(coverage["body_truncated"] == .bool(true))
        #expect(coverage["extraction_status"] == .string("plain_text"))
    }

    @Test func invalidUTF8IsNotClaimedAsReadable() async throws {
        let record = try await fetch(body: Data([0x61, 0xFF, 0x62]), type: "text/plain")
        #expect(record.text.isEmpty)
        guard case .object(let coverage)? = record.coverage else { Issue.record("Missing coverage"); return }
        #expect(coverage["extraction_status"] == .string("unsupported_text_encoding"))
        #expect(coverage["complete"] == .bool(false))
    }

    @Test func oldRecordInitializerRetainsItsShape() {
        let record = ResearchFetchRecord(id: "legacy", url: "https://page.example/", text: "text", createdAt: "date")
        guard case .object(let object) = record.toJSON() else { Issue.record("Missing record"); return }
        #expect(Set(object.keys) == ["id", "url", "text", "createdAt"])
    }
    @Test(arguments: ["text/plain; charset=ISO-8859-1", "Text/HTML; Charset=\"windows-1252\""])
    func declaredSingleByteEncodingIsReadable(type: String) async throws {
        let isHTML = type.lowercased().contains("html")
        let text = isHTML ? "<p>Café — \"quoted\"</p>" : "Café déjà vu"
        let body = try #require(text.data(using: isHTML ? .windowsCP1252 : .isoLatin1))
        let record = try await fetch(body: body, type: type)
        #expect(record.text.contains("Café"))
        if isHTML { #expect(record.text.contains("—")); #expect(!record.text.contains("<p>")) }
        guard case .object(let coverage)? = record.coverage else { Issue.record("Missing coverage"); return }
        #expect(coverage["decoded_encoding"] == .string(isHTML ? "windows-1252" : "iso-8859-1"))
        #expect(coverage["encoding_source"] == .string("http_charset"))
        #expect(coverage["complete"] == .bool(true))
    }

    @Test func encodingFailuresRemainFailedReadOutcomes() async throws {
        let record = try await fetch(body: Data("Hello".utf8), type: "text/plain; charset=utf-8; charset=windows-1252")
        guard case .object(let result) = record.toJSON(), case .object(let coverage)? = record.coverage else { Issue.record("Missing result"); return }
        #expect(result["status"] == .string("failed"))
        #expect(coverage["encoding_error"] == .string("conflicting_charset_declarations"))
        #expect(coverage["http_status"] == .int(200))
    }

    @Test func sourceLocatorRecoversRetainedTailWithoutRefetch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = _ResearchHTTPStub()
        let body = String(repeating: "a", count: 50_000) + "OFFLINE-TAIL"
        await http.set("https://page.example/source", status: 200, body: Data(body.utf8), contentType: "text/plain")
        let client = SwiftNativeResearchClient(dataRoot: root, http: http, receiptIDFactory: { "offline-source" })
        let record = try await client.fetchURL("https://page.example/source")
        guard case .object(let locator)? = record.sourceReceipt,
              case .string(let path)? = locator["path"] else { Issue.record("Missing source locator"); return }
        #expect(path == root.appendingPathComponent("research/source-offline-source.json").path)
        #expect(locator["source_id"] == .string("offline-source"))
        #expect(locator["read_tool"] == .string("read_file"))
        guard case .string(let retention)? = locator["retention"] else { Issue.record("Missing retention"); return }
        #expect(retention.contains(String(SwiftNativeResearchClient.receiptRetentionLimit)))
        let saved = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        guard case .object(let receipt) = saved else { Issue.record("Missing persisted source"); return }
        #expect(receipt["text"] == .string(body))
        #expect(receipt["coverage"] == record.coverage)
        #expect(receipt["source_receipt"] == record.sourceReceipt)
        let requests = await http.requests
        #expect(requests.count == 1, "Reading the stored source does not fetch the page again")
    }

    @Test func failedPersistenceCannotReturnALocator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = root.appendingPathComponent("occupied")
        try Data("not a directory".utf8).write(to: occupied)
        let http = _ResearchHTTPStub()
        await http.set("https://page.example/source", status: 200, body: Data("text".utf8), contentType: "text/plain")
        let client = SwiftNativeResearchClient(dataRoot: root, http: http, receiptsDirOverride: occupied)
        var returned = false
        do { _ = try await client.fetchURL("https://page.example/source"); returned = true } catch {}
        #expect(!returned, "A source locator is only returned after its receipt write succeeds")
        let requests = await http.requests
        #expect(requests.count == 1)
    }

}
