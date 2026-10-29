// Retention archives rows without tombstones: age is not rejection, and lineage remains walkable.

import Foundation
import GRDB

// Blueprint: | `MemoryV2+LaneRetention.swift` | `MemoryStorage` indexed lane ID reads for inventory retirement without tombstoning user memory |

extension MemoryStorage {
    /// Newest-first active, recall-eligible IDs, without decoding full records.
    public func laneMemoryIDs(sourcePrefix: String) async throws -> [String] {
        // GLOB preserves case-sensitive lane identities and
        // can use the existing BINARY source index. LIKE both widened ASCII
        // lane identities across case and forced an active-memory table scan.
        // Escape pattern characters so every caller-supplied byte is literal.
        let escaped = sourcePrefix
            .replacingOccurrences(of: "[", with: "[[]")
            .replacingOccurrences(of: "*", with: "[*]")
            .replacingOccurrences(of: "?", with: "[?]")
        return try await dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM memories
                WHERE source GLOB ?
                  AND status = 'active'
                  AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                ORDER BY created_at DESC, id DESC
            """, arguments: [escaped + "*"])
        }
    }
}
