import Foundation
import NativeAgentCore
import PersistenceCore

/// Result of durably consuming a generic approval immediately before its
/// effect boundary. A spend is intentionally not an outcome: it records that
/// execution may have started, so a restart must not blindly repeat it.
public enum ApprovalEffectSpendOutcome: String, Sendable, Equatable {
    case spent
    case alreadySpent
    case unavailable
}

extension SwiftNativeApprovalInbox {
    public static let effectSpendSchema = "approval-effect-spend.v1"
    static let effectSpendCap = 2000

    /// Kept separate from injection_spends.json: injection verification owns
    /// its narrower capability fence, while this store owns ordinary approved
    /// chat-tool and connector execution starts.
    nonisolated var effectSpendPath: URL {
        root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("effect_spends.json")
    }

    public func consumeApprovedEffect(
        id: String,
        digest: String,
        action: String,
        surface: String
    ) async -> ApprovalEffectSpendOutcome {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !digest.isEmpty, !action.isEmpty, !surface.isEmpty else {
            return .unavailable
        }
        let path = effectSpendPath
        let now = clock()
        let persistence = self.persistence
        do {
            return try await persistence.withFileLock(path) {
                var spends = try Self.loadEffectSpends(at: path)
                if spends[id] != nil { return .alreadySpent }
                spends[id] = .object([
                    "digest": .string(digest),
                    "action": .string(action),
                    "surface": .string(surface),
                    "spentAt": .string(Self.effectSpendTimestamp(now)),
                ])
                if spends.count > Self.effectSpendCap {
                    let ordered = spends.sorted {
                        Self.effectSpentAt($0.value) < Self.effectSpentAt($1.value)
                    }
                    for entry in ordered.prefix(spends.count - Self.effectSpendCap) {
                        spends.removeValue(forKey: entry.key)
                    }
                }
                try await persistence.writeJSON(
                    .object([
                        "schema": .string(Self.effectSpendSchema),
                        "spends": .object(spends),
                    ]),
                    to: path
                )
                return .spent
            }
        } catch {
            // Existing malformed bytes are never interpreted as an empty
            // ledger and are never overwritten. The effect stays blocked.
            return .unavailable
        }
    }

    func approvedEffectSpend(id: String) async -> JSONValue? {
        guard let spends = try? Self.loadEffectSpends(at: effectSpendPath) else { return nil }
        return spends[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    nonisolated static func loadEffectSpends(at path: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ApprovalInboxError.unavailable(
                underlying: "approval effect spend store unreadable: \(error.localizedDescription)"
            )
        }
        guard !data.isEmpty else {
            throw ApprovalInboxError.malformedResponse("approval effect spend store exists but is empty")
        }
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw ApprovalInboxError.malformedResponse(
                "approval effect spend store contains malformed JSON: \(error.localizedDescription)"
            )
        }
        guard case .object(let root) = raw,
              root["schema"] == .string(effectSpendSchema),
              case .object(let spends)? = root["spends"] else {
            throw ApprovalInboxError.malformedResponse(
                "approval effect spend store has an unsupported shape or schema"
            )
        }
        for (id, value) in spends {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .object(let marker) = value,
                  case .string(let digest)? = marker["digest"], !digest.isEmpty,
                  case .string(let action)? = marker["action"], !action.isEmpty,
                  case .string(let surface)? = marker["surface"], !surface.isEmpty,
                  case .string(let spentAt)? = marker["spentAt"], !spentAt.isEmpty else {
                throw ApprovalInboxError.malformedResponse(
                    "approval effect spend store contains a malformed marker"
                )
            }
        }
        return spends
    }

    private nonisolated static func effectSpentAt(_ value: JSONValue) -> String {
        guard case .object(let object) = value,
              case .string(let value)? = object["spentAt"] else { return "" }
        return value
    }

    private nonisolated static func effectSpendTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
