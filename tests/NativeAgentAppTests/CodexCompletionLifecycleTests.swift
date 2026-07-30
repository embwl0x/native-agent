import ChatOrchestration
import Foundation
import PersistenceCore
import Testing

@testable import NativeAgentApp

@Suite
struct CodexCompletionLifecycleTests {
  @Test
  func concurrentDuplicateClaimsStartExactlyOneAgentTurn() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let lifecycle = fixture.lifecycle(owner: "process-a")

    async let first = lifecycle.claim(deliveryId: "delivery-1", requestDigest: "digest-1")
    async let second = lifecycle.claim(deliveryId: "delivery-1", requestDigest: "digest-1")
    let decisions = try await [first, second]

    #expect(decisions.filter { $0 == .start }.count == 1)
    #expect(decisions.filter { $0 == .inProgress }.count == 1)
  }

  @Test
  func relaunchNeverReplaysClaimWithoutCachedResponse() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    let afterRestart = fixture.lifecycle(owner: "process-b")

    #expect(try await beforeRestart.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .start)
    #expect(try await afterRestart.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .outcomeUnknown)
    #expect(try await afterRestart.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .outcomeUnknown)
  }

  @Test
  func relaunchServesCachedResponseWithoutAnotherClaim() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    let response = ChatOrchestration.ChatResponse(
      runId: "run-1",
      model: "model-1",
      output: "finished",
      sessionId: "session-1"
    )
    #expect(try await beforeRestart.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .start)
    try await beforeRestart.cacheResponse(
      response,
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    )

    let afterRestart = fixture.lifecycle(owner: "process-b")
    #expect(try await afterRestart.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .cached(response))
  }

  @Test
  func relaunchRecoversCanonicalAssistantCommittedBeforeLifecycleCache() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    let sessionId = "session-transcript-recovery"
    #expect(try await beforeRestart.claim(
      deliveryId: "delivery-recover",
      requestDigest: "digest-recover",
      sessionId: sessionId
    ) == .start)

    let transcriptDirectory = fixture.directory
      .appendingPathComponent("chat/messages", isDirectory: true)
    try FileManager.default.createDirectory(
      at: transcriptDirectory, withIntermediateDirectories: true
    )
    let content = "The durable answer already exists."
    let runId = "run-recovered"
    let responseDigest = CodexCompletionTranscriptEvidence.responseDigest(
      sessionId: sessionId,
      runId: runId,
      content: content,
      attachments: []
    )
    let row: JSONValue = .object([
      "id": .string("assistant-1"),
      "sessionId": .string(sessionId),
      "role": .string("assistant"),
      "content": .string(content),
      "runId": .string(runId),
      "metadata": .object([
        "codexCompletion": .object([
          "deliveryId": .string("delivery-recover"),
          "requestDigest": .string("digest-recover"),
          "model": .string("gpt-recovered"),
          "reasoningEffort": .string("high"),
          "responseDigest": .string(responseDigest),
        ]),
      ]),
    ])
    try await SwiftNativePersistenceCore().appendJSONL(
      row,
      to: transcriptDirectory.appendingPathComponent("\(sessionId).jsonl")
    )

    #expect(try await fixture.lifecycle(owner: "process-b").claim(
      deliveryId: "delivery-recover",
      requestDigest: "digest-recover",
      sessionId: sessionId
    ) == .cached(ChatOrchestration.ChatResponse(
      runId: runId,
      model: "gpt-recovered",
      reasoningEffort: "high",
      output: content,
      sessionId: sessionId
    )))
  }

  @Test
  func artifactRecoveryRetriesOnlyStableIdempotentTransport() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    try await prepareCachedResponse(beforeRestart)

    #expect(try await beforeRestart.beginArtifact(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "slack-text",
      artifactKind: "text",
      retrySafe: true
    ) == .send)
    try await beforeRestart.markArtifactDispatchStarted(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "slack-text"
    )
    #expect(try await beforeRestart.beginArtifact(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "telegram-photo",
      artifactKind: "attachment",
      retrySafe: false
    ) == .send)
    try await beforeRestart.markArtifactDispatchStarted(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "telegram-photo"
    )

    let afterRestart = fixture.lifecycle(owner: "process-b")
    #expect(try await afterRestart.beginArtifact(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "slack-text",
      artifactKind: "text",
      retrySafe: true
    ) == .send)
    #expect(try await afterRestart.beginArtifact(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "telegram-photo",
      artifactKind: "attachment",
      retrySafe: false
    ) == .outcomeUnknown)
  }

  @Test
  func relaunchRetriesReservedNonIdempotentArtifactBecauseDispatchNeverStarted() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    try await prepareCachedResponse(beforeRestart)

    #expect(try await beforeRestart.beginArtifact(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "telegram-photo",
      artifactKind: "attachment",
      retrySafe: false
    ) == .send)

    #expect(try await fixture.lifecycle(owner: "process-b").beginArtifact(
      deliveryId: "delivery-1",
      requestDigest: "digest-1",
      artifactId: "telegram-photo",
      artifactKind: "attachment",
      retrySafe: false
    ) == .send)
  }

  @Test
  func deliveryIdCannotBeReusedForDifferentCompletion() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let lifecycle = fixture.lifecycle(owner: "process-a")
    #expect(try await lifecycle.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .start)
    #expect(try await lifecycle.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-2"
    ) == .conflict)
  }

  @Test
  func malformedLifecycleRowFailsClosedInsteadOfReplayingClaim() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let legacy = "{\"status\":\"ok\",\"reply\":\"legacy row is intentionally mixed\"}\n"
    let corruptLifecycle = "{\"kind\":\"codex_completion_claimed\",\"deliveryId\":\"delivery-1\"\n"
    try Data((legacy + corruptLifecycle).utf8).write(to: fixture.receiptURL)

    await #expect(throws: CodexCompletionLifecycle.LifecycleError.self) {
      _ = try await fixture.lifecycle(owner: "process-a").claim(
        deliveryId: "delivery-1",
        requestDigest: "digest-1"
      )
    }
  }

  @Test
  func oneCorruptV2StateIsQuarantinedWithoutBlockingHealthyReconciliation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    #expect(try await beforeRestart.claim(
      deliveryId: "delivery-corrupt",
      requestDigest: "digest-corrupt"
    ) == .start)
    #expect(try await beforeRestart.claim(
      deliveryId: "delivery-healthy",
      requestDigest: "digest-healthy"
    ) == .start)
    try Data("{corrupt".utf8).write(
      to: fixture.stateURL(deliveryId: "delivery-corrupt")
    )

    let afterRestart = fixture.lifecycle(owner: "process-b")
    #expect(try await afterRestart.reconcileInterruptedClaims() == ["delivery-healthy"])
    #expect(try await afterRestart.claim(
      deliveryId: "delivery-healthy",
      requestDigest: "digest-healthy"
    ) == .outcomeUnknown)
    await #expect(throws: CodexCompletionLifecycle.LifecycleError.self) {
      _ = try await afterRestart.claim(
        deliveryId: "delivery-corrupt",
        requestDigest: "digest-corrupt"
      )
    }
    let quarantine = fixture.directory
      .appendingPathComponent("codex-completion-lifecycle/quarantine", isDirectory: true)
    #expect((try FileManager.default.contentsOfDirectory(atPath: quarantine.path)).count == 1)
  }

  @Test
  func oneFilesystemIOFailureDoesNotBlockHealthyReconciliation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let beforeRestart = fixture.lifecycle(owner: "process-a")
    #expect(try await beforeRestart.claim(
      deliveryId: "delivery-healthy-io",
      requestDigest: "digest-healthy-io"
    ) == .start)
    let badEntry = fixture.directory
      .appendingPathComponent("codex-completion-lifecycle/000-bad.json", isDirectory: true)
    try FileManager.default.createDirectory(at: badEntry, withIntermediateDirectories: true)

    let afterRestart = fixture.lifecycle(owner: "process-b")
    #expect(try await afterRestart.reconcileInterruptedClaims() == ["delivery-healthy-io"])
    #expect(try await afterRestart.claim(
      deliveryId: "delivery-healthy-io",
      requestDigest: "digest-healthy-io"
    ) == .outcomeUnknown)
    #expect(FileManager.default.fileExists(atPath: badEntry.path))
  }

  @Test
  func terminalResponseRetentionCannotGrowUnboundedInsideMarkerHour() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let lifecycle = fixture.lifecycle(owner: "process-a")
    let count = CodexCompletionLifecycle.retainedTerminalResponses
      + CodexCompletionLifecycle.terminalResponseCompactionSlack + 1
    let delivery = AgentBridgeCompletionDelivery(
      status: "delivered",
      surface: "chat",
      delivery: "local",
      artifactCount: 0,
      attempts: 1,
      reason: nil
    )
    for index in 0..<count {
      let deliveryID = "retention-\(index)"
      let digest = "digest-\(index)"
      #expect(try await lifecycle.claim(
        deliveryId: deliveryID,
        requestDigest: digest
      ) == .start)
      try await lifecycle.cacheResponse(
        ChatOrchestration.ChatResponse(
          runId: "run-\(index)",
          model: "model",
          output: "response-\(index)"
        ),
        deliveryId: deliveryID,
        requestDigest: digest
      )
      try await lifecycle.recordDelivery(
        delivery,
        deliveryId: deliveryID,
        requestDigest: digest
      )
    }

    let stateDirectory = fixture.directory
      .appendingPathComponent("codex-completion-lifecycle", isDirectory: true)
    let responseBearing = try FileManager.default.contentsOfDirectory(
      at: stateDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" && !$0.hasDirectoryPath }.filter { url in
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
      guard let dictionary = object as? [String: Any] else { return false }
      return !(dictionary["response"] is NSNull) && dictionary["response"] != nil
    }
    #expect(responseBearing.count == CodexCompletionLifecycle.retainedTerminalResponses)
  }

  @Test
  func legacyReplyTextCannotMasqueradeAsCorruptLifecycleState() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let legacy = """
    {"status":"ok","reply":"Explain codex_completion_claimed without changing state."}

    """
    try Data(legacy.utf8).write(to: fixture.receiptURL)

    #expect(try await fixture.lifecycle(owner: "process-a").claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .start)
  }

  @Test
  func requestDigestIsStableAcrossDictionaryOrderAndChangesWithIntent() {
    let first: [String: Any] = [
      "text": "done",
      "sessionId": "session-1",
      "completion": ["turnId": "turn-1", "threadId": "thread-1"],
      "origin": ["surface": "slack", "destinationId": "C123"],
    ]
    let reordered: [String: Any] = [
      "origin": ["destinationId": "C123", "surface": "slack"],
      "completion": ["threadId": "thread-1", "turnId": "turn-1"],
      "sessionId": "session-1",
      "text": "done",
    ]
    var changed = first
    changed["text"] = "different"

    #expect(ClaudeBridge.codexCompletionRequestDigest(first)
      == ClaudeBridge.codexCompletionRequestDigest(reordered))
    #expect(ClaudeBridge.codexCompletionRequestDigest(first)
      != ClaudeBridge.codexCompletionRequestDigest(changed))
  }

  private func prepareCachedResponse(_ lifecycle: CodexCompletionLifecycle) async throws {
    #expect(try await lifecycle.claim(
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    ) == .start)
    try await lifecycle.cacheResponse(
      ChatOrchestration.ChatResponse(
        runId: "run-1",
        model: "model-1",
        output: "done"
      ),
      deliveryId: "delivery-1",
      requestDigest: "digest-1"
    )
  }
}

private struct Fixture {
  let directory: URL
  let receiptURL: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nativeagent-codex-completion-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    receiptURL = directory.appendingPathComponent("message-replies.jsonl")
  }

  func lifecycle(owner: String) -> CodexCompletionLifecycle {
    CodexCompletionLifecycle(
      receiptURL: receiptURL,
      ownerInstanceId: owner,
      dataRoot: directory
    )
  }

  func stateURL(deliveryId: String) -> URL {
    directory
      .appendingPathComponent("codex-completion-lifecycle", isDirectory: true)
      .appendingPathComponent("\(CausalTransitionEvidence.opaqueIdentity(deliveryId)).json")
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
