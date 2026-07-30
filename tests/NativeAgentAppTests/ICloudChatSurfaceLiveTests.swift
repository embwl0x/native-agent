import Foundation
import Testing
import NativeAgentShared
import PersistenceCore

@Test
func liveICloudChatSurface_signedRoundTrip_optInOnly() async throws {
    guard ProcessInfo.processInfo.environment["NATIVE_AGENT_LIVE_ICLOUD_CHAT_TEST"] == "1" else {
        return
    }

    let dataRoot = PersistenceCore.defaultDataRoot()
    let secretURL = dataRoot.appendingPathComponent("icloud_pairing_secret.bin")
    let secret = try Data(contentsOf: secretURL)
    #expect(secret.count >= 32)

    let documents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~com.example~nativeagent/Documents", isDirectory: true)
    let iosOutbox = documents.appendingPathComponent("outbox/ios", isDirectory: true)
    let macOutbox = documents.appendingPathComponent("outbox/mac", isDirectory: true)
    try FileManager.default.createDirectory(at: iosOutbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: macOutbox, withIntermediateDirectories: true)

    let sessionID = "ios-live-\(UUID().uuidString.lowercased())"
    let prompt = "Agent, what are you feeling curious about right now? Call time_now once to ground the moment, then answer naturally in two sentences beginning IOS-LIVE."
    let unsigned = BridgeMessage.make(
        sender: "ios",
        text: prompt,
        sessionID: sessionID,
        metadata: [
            "sourceKey": "iphone:live-probe",
            "routeKey": "iphone:live-probe",
            "clientSurface": "iphone",
            "providerId": "anthropic_oauth_direct",
            "model": "claude-fable-5",
            "reasoningEffort": "high",
            "fileAccess": "auto",
        ]
    )
    let outbound = try unsigned.signed(with: secret)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let outboundData = try encoder.encode(outbound)
    let outboundURL = iosOutbox.appendingPathComponent("codex-live-\(outbound.id).json")
    try outboundData.write(to: outboundURL, options: .atomic)

    let receiptURL = dataRoot
        .appendingPathComponent("icloud", isDirectory: true)
        .appendingPathComponent("chat_delivery_receipts.jsonl")
    let deadline = Date().addingTimeInterval(120)
    var reply: BridgeMessage?
    var deliveryReceipt: [String: Any]?
    while Date() < deadline, reply == nil, deliveryReceipt == nil {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: macOutbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let candidate = try? decoder.decode(BridgeMessage.self, from: data),
                  candidate.correlationID == outbound.id else {
                continue
            }
            reply = candidate
            break
        }
        if reply == nil,
           let receiptData = try? Data(contentsOf: receiptURL),
           let receiptText = String(data: receiptData, encoding: .utf8) {
            for line in receiptText.split(whereSeparator: \.isNewline).reversed() {
                guard let data = String(line).data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      row["correlationId"] as? String == outbound.id,
                      row["kind"] as? String == "reply" else {
                    continue
                }
                deliveryReceipt = row
                break
            }
        }
        if reply == nil, deliveryReceipt == nil {
            try await Task.sleep(for: .seconds(2))
        }
    }

    if let resolved = reply {
        #expect(resolved.sender == "mac")
        #expect(resolved.sessionID == sessionID)
        #expect(resolved.verifySignature(secret: secret))
        #expect(resolved.metadata?["transport"] == "icloud")
        #expect(resolved.metadata?["targetSourceKey"] == "iphone:live-probe")
        #expect(resolved.text.contains("IOS-LIVE"))
        print("live iCloud Drive reply: \(resolved.text)")
    } else {
        let receipt = try #require(deliveryReceipt, "No correlated iCloud delivery receipt arrived")
        #expect(receipt["sender"] as? String == "mac")
        #expect(receipt["sessionId"] as? String == sessionID)
        #expect(receipt["status"] as? String == "sent")
        #expect(receipt["signatureVerified"] as? Bool == true)
        #expect(receipt["transport"] as? String == "cloudkit")
        #expect(receipt["targetSourceKey"] as? String == "iphone:live-probe")
        #expect((receipt["textPreview"] as? String)?.contains("IOS-LIVE") == true)
        print("live CloudKit delivery receipt: \(receipt)")
    }

    let messageLog = dataRoot
        .appendingPathComponent("chat/messages", isDirectory: true)
        .appendingPathComponent("\(sessionID).jsonl")
    let persisted = try String(contentsOf: messageLog, encoding: .utf8)
    #expect(persisted.contains(prompt))
    #expect(persisted.contains("IOS-LIVE"))

    let traceDirectory = dataRoot.appendingPathComponent("turn_traces", isDirectory: true)
    let traceFiles = (try? FileManager.default.contentsOfDirectory(
        at: traceDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []
    var matchingSnapshot: [String: Any]?
    for file in traceFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { continue }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let rowData = String(line).data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any],
                  row["kind"] as? String == "context.snapshot",
                  row["sessionId"] as? String == sessionID,
                  let payload = row["payload"] as? [String: Any] else {
                continue
            }
            matchingSnapshot = payload
            break
        }
        if matchingSnapshot != nil { break }
    }
    let snapshot = try #require(matchingSnapshot, "No context snapshot was recorded for the iOS turn")
    #expect(snapshot["containsCognitiveSubstrate"] as? Bool == true)
    #expect((snapshot["cognitiveCapsuleBytes"] as? NSNumber)?.intValue ?? 0 > 0)
    let sources = (snapshot["personaSources"] as? [[String: Any]] ?? [])
        .compactMap { $0["source"] as? String }
    #expect(Set(sources) == ["AGENTS", "GROWTH", "SOUL", "USER", "VOICE"])
}
