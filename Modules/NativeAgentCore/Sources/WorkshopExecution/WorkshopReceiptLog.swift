import Foundation
import NativeAgentShared
import Darwin
import NativeAgentCore
import PersistenceCore
import Desk
// Blueprint: | `WorkshopReceiptLog.swift` | `WorkshopReceiptLog` actor; session/directed_task receipt variants, one locked idempotent directed batch append, reservation recovery index and bounded raw read of workshop/receipts.jsonl |

/// Owns workshop/receipts.jsonl: untagged session and directed_task variants.
/// Shared fields: handle, reservationId, status, model, artifactCount, summary, ts.
/// Local backup/export include workshop/; no raw phone sync; PrivacyMap lists it.
/// Handoff markers retain the directed variant; each variant keeps its evidence.
public actor WorkshopReceiptLog {
    private let path: URL

    public init(dataRoot: URL) {
        self.path = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
    }

    public var receiptsPath: URL { path }

    public nonisolated static func readRecent(at path: URL, limit: Int) async throws -> SwiftNativePersistenceCore.JSONLTailReadReceipt {
        try await SwiftNativePersistenceCore.tailJSONLReadReceipt(path, limit: limit, maxBytes: 1_048_576)
    }

    nonisolated static func directedJSON(_ receipt: WorkshopDirectedTaskReceipt) -> JSONValue {
        .object([
            "kind": .string("directed_task"),
            "handle": .string(receipt.handle),
            "reservationId": .string(receipt.executionId),
            "executionId": .string(receipt.executionId),
            "status": .string(receipt.status),
            "model": .null,
            "artifactCount": .int(0),
            "summary": .string(String(receipt.summary.prefix(600))),
            "ts": .string(receipt.completedAt),
            "createdAt": .string(receipt.createdAt),
            "totalSteps": .int(Int64(receipt.totalSteps)),
            "completedSteps": .int(Int64(receipt.completedSteps)),
            "rerunCount": .int(Int64(receipt.rerunCount)),
            "triggerSource": .string(receipt.triggerSource),
            "wasStub": .bool(receipt.wasStub),
            "verificationStatus": receipt.verificationStatus.map { .string($0.rawValue) } ?? .null,
        ])
    }

    nonisolated static func directedReceipt(from value: JSONValue) -> WorkshopDirectedTaskReceipt? {
        guard case .object(let object) = value,
              case .string("directed_task")? = object["kind"] else { return nil }
        guard let handle = object["handle"]?.stringValue, !handle.isEmpty,
              let executionId = object["executionId"]?.stringValue ?? object["reservationId"]?.stringValue, !executionId.isEmpty,
              let status = object["status"]?.stringValue,
              let completedAt = object["ts"]?.stringValue else { return nil }
        return WorkshopDirectedTaskReceipt(
            handle: handle,
            executionId: executionId,
            status: status,
            summary: object["summary"]?.stringValue ?? "",
            createdAt: object["createdAt"]?.stringValue ?? completedAt,
            completedAt: completedAt,
            totalSteps: object["totalSteps"]?.integerValue.flatMap { Int(exactly: $0) } ?? 0,
            completedSteps: object["completedSteps"]?.integerValue.flatMap { Int(exactly: $0) } ?? 0,
            rerunCount: object["rerunCount"]?.integerValue.flatMap { Int(exactly: $0) } ?? 0,
            triggerSource: object["triggerSource"]?.stringValue ?? "manual",
            wasStub: object["wasStub"] == .bool(true),
            verificationStatus: object["verificationStatus"]?.stringValue
                .flatMap(WorkshopVerificationStatus.init(rawValue:))
        )
    }

    func append(_ receipts: [WorkshopDirectedTaskReceipt]) async throws {
        guard !receipts.isEmpty else { return }
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var existing = Set<[String?]>(try await SwiftNativePersistenceCore.readJSONL(path)
                .compactMap(Self.directedReceipt).map { [$0.executionId, $0.status, $0.verificationStatus?.rawValue] })
            let rows = receipts.filter {
                existing.insert([$0.executionId, $0.status, $0.verificationStatus?.rawValue]).inserted
            }.map(Self.directedJSON)
            try await SwiftNativePersistenceCore.appendJSONLDurable(rows, to: path)
        }
    }

    public func reservationIdsByHandle() async throws -> [String: Set<String>] {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
            var ids: [String: Set<String>] = [:]
            for row in try await SwiftNativePersistenceCore.readJSONL(path) {
                guard Self.isReceiptRow(row), case .object(let object) = row,
                      case .string(let handle)? = object["handle"],
                      case .string(let id)? = object["reservationId"] else { continue }
                ids[handle, default: []].insert(id)
            }
            try Self.flushReceiptLog(path)
            return ids
        }
    }

    @discardableResult
    public func append(_ receipt: WorkshopSessionReceipt) async -> Bool {
        let stamp = NativeTimestampFormat.plainZulu(receipt.generatedAt)
        let row: JSONValue = .object([
            "handle": .string(receipt.handle),
            "reservationId": .string(receipt.reservationId),
            "status": .string(receipt.status.rawValue),
            "model": receipt.model.map { JSONValue.string($0) } ?? .null,
            "output": receipt.output.map(JSONValue.string) ?? .null,
            "artifactCount": .int(Int64(receipt.artifactPaths.count)),
            "artifactRefs": .array(receipt.artifactPaths.prefix(16).map(JSONValue.string)),
            "disposition": .string(receipt.disposition.rawValue),
            "summary": .string(String(receipt.summary.prefix(600))),
            "ts": .string(stamp),
        ])
        do {
            try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Void in
                if FileManager.default.fileExists(atPath: path.path) {
                    let rows = try await SwiftNativePersistenceCore.readJSONL(path)
                    let exists = try rows.contains { value in
                        guard case .object(let object) = value, object["kind"] != .string("directed_task"),
                              case .string(let handle)? = object["handle"],
                              case .string(let id)? = object["reservationId"] else { return false }
                        guard handle == receipt.handle && id == receipt.reservationId else { return false }
                        guard Self.isReceiptRow(value) else {
                            throw PersistenceCoreError.ioFailure("Workshop receipt row is malformed")
                        }
                        return true
                    }
                    if exists {
                        try Self.flushReceiptLog(path)
                        return
                    }
                }
                try await SwiftNativePersistenceCore.appendJSONLDurable(row, to: path)
                try Self.flushReceiptLog(path)
            }
            return true
        } catch {
            nativeLog("[workshop] compact receipt append failed for %@/%@: %@",
                  receipt.handle, receipt.reservationId, String(describing: error))
            return false
        }
    }

    private static func isReceiptRow(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value, object["kind"] != .string("directed_task"),
              case .string(let status)? = object["status"], WorkshopSessionStatus(rawValue: status) != nil,
              case .string? = object["summary"],
              case .int(let artifactCount)? = object["artifactCount"], artifactCount >= 0,
              case .array(let artifactRefs)? = object["artifactRefs"],
              artifactRefs.count == Int(min(artifactCount, 16)),
              artifactRefs.allSatisfy({ reference in
                  guard case .string(let path) = reference else { return false }
                  return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              case .string(let disposition)? = object["disposition"], DeskWorkDisposition(rawValue: disposition) != nil,
              case .string(let stamp)? = object["ts"], DeskClock.parseISO(stamp) != nil else { return false }
        return true
    }

    private static func flushReceiptLog(_ path: URL) throws {
        guard WorkshopReservationDurability.flush(path) else {
            throw PersistenceCoreError.ioFailure("Workshop receipt log durability unproven")
        }
        let descriptor = Darwin.open(path.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PersistenceCoreError.ioFailure("Workshop receipt log durability unproven")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) != -1 else {
            throw PersistenceCoreError.ioFailure("Workshop receipt log durability unproven")
        }
    }
}
