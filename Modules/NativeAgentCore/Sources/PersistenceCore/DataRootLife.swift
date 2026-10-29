import Foundation
import Darwin
import NativeAgentCore
// Blueprint: | `DataRootLife.swift` | `DataRootLife`; one root life-id, created once when absent as their first life (`first`) and replaced by the restore intent's UUID; `life(of:)` reads a missing stamp as the first life, so an upgrade never reads as a restore; resumable owners stamp at beginning and admit only that life, projecting work from another life stopped with reason restored; CodexCompletionReadout owns lifecycle disk projection and incremental transcript origins |

/// A restore brings back what she had, never what she was doing.
/// Resumable owners retain the life in which work began, never adopt it on read.
public enum DataRootLife {
    public static let stoppedReason = "restored"
    /// Her first life. Work saved before lives were stamped began in it, so an
    /// upgrade never reads as a restore; only a restore starts a new life.
    public static let first = "00000000-0000-0000-0000-000000000000"

    /// The life a stamp names; no stamp is her first life.
    public static func life(of stamp: String?) -> String { stamp ?? first }

    public static func current(in root: URL) throws -> String {
        let path = root.appendingPathComponent("life-id")
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let pending = root.appendingPathComponent(".life-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: pending) }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(first.utf8), to: pending)
            if link(pending.path, path.path) == 0 { try SwiftNativePersistenceCore.syncDirectory(root) }
            else if errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == 36 else { throw CocoaError(.fileReadCorruptFile) }
        let id = try String(contentsOf: path, encoding: .utf8)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw CocoaError(.fileReadCorruptFile) }
        return id
    }

    public static func isCurrent(_ lifeID: String?, in root: URL) throws -> Bool {
        try current(in: root) == life(of: lifeID)
    }

    /// The durable restore intent supplies one new identity across interrupted installation.
    public static func begin(in root: URL, id: UUID) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(
            Data(id.uuidString.lowercased().utf8), to: root.appendingPathComponent("life-id"))
    }
}

/// The lifecycle owner's read model, shared below the surface and reporting modules.
public struct CodexCompletionReadout: Decodable, Sendable {
  private struct Answer: Decodable, Sendable {
    struct Attachment: Decodable, Sendable { let id: String }
    let runId: String
    let sessionId: String?
    let output: String
    let attachments: [Attachment]?
  }
  private struct Delivery: Decodable, Sendable { let status: String; let delivery: String }
  private struct Artifact: Decodable, Sendable { let phase: String }
  public let deliveryId: String
  public let lifeID: String?
  public let principal: String?
  public let source: String?
  public let updatedAt: String
  private var phase: String
  private let response: Answer?
  private let responseRunId: String?
  private let sessionId: String?
  private let delivery: Delivery?
  private let artifacts: [String: Artifact]

  public init(deliveryId: String, lifeID: String? = nil, principal: String?, source: String?, updatedAt: String,
              phase: String, response: (runId: String, sessionId: String?, output: String, attachmentIds: [String])?, responseRunId: String?,
              sessionId: String?, delivery: (status: String, delivery: String)?, artifacts: [String: String]) {
    self.deliveryId = deliveryId
    self.lifeID = lifeID
    self.principal = principal
    self.source = source
    self.updatedAt = updatedAt
    self.phase = phase
    self.response = response.map { Answer(runId: $0.runId, sessionId: $0.sessionId, output: $0.output,
                                         attachments: $0.attachmentIds.map { Answer.Attachment(id: $0) }) }
    self.responseRunId = responseRunId
    self.sessionId = sessionId
    self.delivery = delivery.map { Delivery(status: $0.status, delivery: $0.delivery) }
    self.artifacts = artifacts.mapValues { Artifact(phase: $0) }
  }

  public var status: String? {
    if phase == "stopped" { return "stopped" }
    if delivery?.status == "let_go" { return "let_go" }
    if phase == "failed_before_answer" { return "failed_before_answer" }
    if delivery?.status == "completed" { return "delivered" }
    if delivery?.status == "sent_unconfirmed" || artifacts.values.contains(where: {
      !["accepted", "reserved", "pre_dispatch_failed", "rejected"].contains($0.phase)
    }) { return "sent_unconfirmed" }
    if !artifacts.isEmpty && artifacts.values.allSatisfy({ $0.phase == "accepted" }), let response,
       (response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || artifacts["\(deliveryId):text"] != nil),
       (response.attachments ?? []).enumerated().allSatisfy({ index, attachment in
         artifacts.keys.contains { $0.hasPrefix("\(deliveryId):attachment:\(index):\(attachment.id):") }
       }) { return "delivered" }
    if artifacts.values.contains(where: { $0.phase == "accepted" }) { return "sent_unconfirmed" }
    return response == nil ? nil : "owed"
  }

  public var routeSettled: Bool {
    delivery?.delivery == "route_journal" && ["completed", "sent_unconfirmed"].contains(delivery?.status ?? "")
  }

  public var permitsDelivery: Bool { phase != "stopped" && delivery?.status != "let_go" }

  package func reading(life: String) -> Self {
    var row = self
    if DataRootLife.life(of: lifeID) != life, !["delivered", "let_go"].contains(status ?? "") { row.phase = "stopped" }
    return row
  }

  public static func permitsDelivery(sessionId: String?, runId: String?, configRoot: URL, dataRoot: URL) throws -> Bool {
    guard let sessionId, let runId else { return true }
    return try rows(configRoot: configRoot, dataRoot: dataRoot).allSatisfy {
      $0.permitsDelivery || ($0.response?.runId ?? $0.responseRunId) != runId
        || ($0.response?.sessionId ?? $0.sessionId) != sessionId
    }
  }

  public var unsettledRunId: String? {
    ["delivered", "failed_before_answer", "let_go", "stopped"].contains(status ?? "") ? nil : response?.runId ?? responseRunId
  }

  public func knownPrincipal(dataRoot: URL) throws -> String? {
    if let principal { return principal }
    guard let session = response?.sessionId ?? sessionId,
          NativeAgentChatSessionID.normalizedPathComponent(session) == session,
          let run = response?.runId ?? responseRunId else { return nil }
    return try Self.transcriptOrigins.agent(
      forRun: run, in: dataRoot.appendingPathComponent("chat/messages/\(session).jsonl"))
  }

  /// Each transcript is indexed once, then only newly appended whole rows are read.
  private static let transcriptOrigins = TranscriptOrigins()

  public static func directories(configRoot: URL, dataRoot: URL) -> [URL] {
    [configRoot.appendingPathComponent("claude-bridge/codex-completion-lifecycle")]
      + ["agent-conversations", "chat/human-reply-delivery", "chat/anchor-mirror"].map {
        dataRoot.appendingPathComponent($0 + "/codex-completion-lifecycle")
      }
  }

  public static func unsettledAnswerRuns(configRoot: URL, dataRoot: URL) throws -> Set<String> {
    Set(try rows(configRoot: configRoot, dataRoot: dataRoot).compactMap(\.unsettledRunId))
  }

  private static func rows(configRoot: URL, dataRoot: URL) throws -> [Self] {
    var rows: [Self] = []
    for directory in directories(configRoot: configRoot, dataRoot: dataRoot)
      where FileManager.default.fileExists(atPath: directory.path) {
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) where url.pathExtension == "json" {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["schema"] as? String == "codex-completion-lifecycle.corrupt.v1" { continue }
        rows.append(try JSONDecoder().decode(Self.self, from: data))
      }
    }
    guard let life = rows.isEmpty ? nil : try DataRootLife.current(in: dataRoot) else { return [] }
    return rows.map { $0.reading(life: life) }
  }
}

/// Each transcript's run → origin agent (the last user row of the run that
/// names an origin). A run's origin is written once and never changes, so the
/// index only grows; a transcript that got shorter was rewritten and is reread.
private final class TranscriptOrigins: @unchecked Sendable {
  private struct Indexed { var offset: UInt64 = 0; var agents: [String: String?] = [:] }
  private let lock = NSLock()
  private var transcripts: [String: Indexed] = [:]

  func agent(forRun run: String, in path: URL) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    var indexed = transcripts[path.path] ?? Indexed()
    if let known = indexed.agents[run] { return known }
    guard let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? UInt64
    else { return nil }
    if size < indexed.offset { indexed = Indexed() }
    if size > indexed.offset {
      let handle = try FileHandle(forReadingFrom: path)
      defer { try? handle.close() }
      try handle.seek(toOffset: indexed.offset)
      let data = try handle.readToEnd() ?? Data()
      // Whole lines only: a row still being appended is read next time.
      let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
      for line in data[data.startIndex..<end].split(separator: UInt8(ascii: "\n")) {
        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              row["role"] as? String == "user", let runId = row["runId"] as? String,
              let metadata = row["metadata"] as? [String: Any],
              let origin = metadata["origin"] as? [String: Any] else { continue }
        indexed.agents[runId] = .some(origin["agent"] as? String)
      }
      indexed.offset += UInt64(end - data.startIndex)
    }
    transcripts[path.path] = indexed
    return indexed.agents[run] ?? nil
  }
}
