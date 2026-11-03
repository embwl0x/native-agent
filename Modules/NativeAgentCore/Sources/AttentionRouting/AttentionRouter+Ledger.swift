import Foundation
import CryptoKit
import PersistenceCore
// Blueprint: | `AttentionRouter+Ledger.swift` | Checked delivered-knock projection from the one delivery ledger; read-only retained reason-only history while its data remains present |

extension AttentionRouter {
    // DATA PRESENT: shipped reason-only receipts remain read-only evidence of
    // possible previous effects. No current writer produces this format.
    struct RetainedReasons: Decodable {
        let reasons: [String: String]
        let order: [String]
    }

    static func retainedReasons(dataRoot: URL) throws -> [String: String] {
        let path = dataRoot.appendingPathComponent("notify/attention_router.json")
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        return try JSONDecoder().decode(RetainedReasons.self, from: data).reasons
    }

    /// Only checked destination acceptance is delivered. Queued publications,
    /// preference suppression and old reason-only history cannot prove it.
    public static func deliveredKnocks(dataRoot: URL) throws -> [String: String] {
        let entries = try NotificationDeliveryLedger(dataRoot: dataRoot).read().entries.values
        var result: [String: String] = [:]
        for entry in entries where entry.supersededBy == nil && entry.rows.values.contains(where: { $0.outcome == .delivered }) {
            result[entry.occurrence.eventID] = stableDigest(entry.occurrence.reason)
        }
        return result
    }

    public nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
