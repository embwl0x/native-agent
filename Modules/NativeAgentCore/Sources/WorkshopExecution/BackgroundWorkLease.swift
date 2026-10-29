import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `BackgroundWorkLease.swift` | `BackgroundWorkLease` actor; persisted shared window claims and release of the holder’s newest unused claim |

/// Durable shared window claims; only the holder’s newest unused claim may be
/// released. background_lease.json stays in Workshop backup/export, without phone sync.
public actor BackgroundWorkLease {
    private let path: URL

    public init(dataRoot: URL) {
        self.path = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("background_lease.json")
    }

    /// True iff this call is the first to claim `window`. Persists the claim
    /// under the file lock so concurrent callers can't both win.
    public func tryAcquire(holder: String, window: String) async -> Bool {
        let holder = holder.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = window.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !holder.isEmpty, !window.isEmpty else { return false }
        return (try? await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            var claims: [JSONValue] = []
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                let current = try JSONValue.parse(data)
                guard case .object(let obj) = current else {
                    throw NSError(domain: "BackgroundWorkLease", code: 1)
                }
                if case .array(let rows)? = obj["claims"] {
                    guard rows.allSatisfy({ row in
                        guard case .object(let claim) = row,
                              case .string(let claimedWindow)? = claim["window"],
                              !claimedWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return false
                        }
                        return true
                    }) else {
                        throw NSError(domain: "BackgroundWorkLease", code: 3)
                    }
                    claims = rows
                } else if case .string(let legacyWindow)? = obj["window"] {
                    claims = [.object([
                        "window": .string(legacyWindow),
                        "holder": obj["holder"] ?? .string("legacy"),
                        "acquiredAt": obj["acquiredAt"] ?? .null,
                    ])]
                } else {
                    throw NSError(domain: "BackgroundWorkLease", code: 2)
                }
            }
            let alreadyClaimed = claims.contains { row in
                guard case .object(let claim) = row,
                      case .string(let claimedWindow)? = claim["window"] else { return false }
                return claimedWindow == window
            }
            if alreadyClaimed {
                return false
            }
            let stamp = NativeTimestampFormat.plainZulu(Date())
            let claim: JSONValue = .object([
                "window": .string(window),
                "holder": .string(holder),
                "acquiredAt": .string(stamp),
            ])
            claims.append(claim)
            claims = Array(claims.suffix(32))
            let record: JSONValue = .object([
                "window": .string(window),
                "holder": .string(holder),
                "acquiredAt": .string(stamp),
                "claims": .array(claims),
            ])
            try await SwiftNativePersistenceCore.writeJSON(record, to: path)
            guard WorkshopReservationDurability.flushDirectory(path.deletingLastPathComponent()) else {
                throw NSError(domain: "BackgroundWorkLease", code: 4)
            }
            return true
        }) ?? false
    }

    /// Return only this holder's newest claim when admission failed before any
    /// provider/tool work. This is not a general release: a spent or older
    /// window remains immutable, and another holder's claim can never be
    /// removed.
    public func releaseUnused(holder: String, window: String) async -> Bool {
        (try? await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            guard FileManager.default.fileExists(atPath: path.path),
                  case .object(let object) = try JSONValue.parse(Data(contentsOf: path)),
                  case .array(var claims)? = object["claims"],
                  let last = claims.last,
                  case .object(let claim) = last,
                  case .string(let claimedWindow)? = claim["window"],
                  case .string(let claimedHolder)? = claim["holder"],
                  claimedWindow == window, claimedHolder == holder else { return false }
            claims.removeLast()
            var record: [String: JSONValue] = ["claims": .array(claims)]
            if let newest = claims.last, case .object(let fields) = newest {
                record["window"] = fields["window"] ?? .null
                record["holder"] = fields["holder"] ?? .null
                record["acquiredAt"] = fields["acquiredAt"] ?? .null
            }
            try await SwiftNativePersistenceCore.writeJSON(.object(record), to: path)
            return WorkshopReservationDurability.flushDirectory(path.deletingLastPathComponent())
        }) ?? false
    }

}
