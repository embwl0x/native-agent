import ChatOrchestration
import Foundation
import PersistenceCore
import Testing

@testable import NativeAgentApp

@Suite
struct AgentBridgeCompletionRouterTests {
  @Test
  func parsesPersistedOriginRoute() {
    let route = AgentBridgeCompletionRoute(
      origin: [
        "surface": "slack",
        "destinationId": "C123",
        "threadId": "171.42",
        "sourceKey": "device-a",
        "replyTo": "iphone",
        "correlationId": "message-1",
      ],
      sessionId: "session-1"
    )

    #expect(route.surface == "slack")
    #expect(route.sessionId == "session-1")
    #expect(route.destinationId == "C123")
    #expect(route.threadId == "171.42")
    #expect(route.sourceKey == "device-a")
    #expect(route.replyTo == "iphone")
    #expect(route.correlationId == "message-1")
  }

  @Test
  func routesCompletionToOriginAndRefreshesSharedSession() async {
    let fixture = try! await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder()
    let route = AgentBridgeCompletionRoute(
      surface: "telegram",
      sessionId: "session-telegram",
      destinationId: "123456"
    )

    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Codex finished and I checked the result.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "completed")
    #expect(result.delivery == "telegram")
    #expect(result.artifactCount == 1)
    #expect(result.attempts == 1)
    #expect(await sender.refreshedSessions() == ["session-telegram"])
    #expect(await sender.telegramDestinations() == ["123456"])
  }

  @Test
  func retriesOnlyIdempotentOriginDeliveryWithOneStableKey() async {
    let fixture = try! await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder(failuresBeforeSuccessByKind: ["text": 2])
    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: AgentBridgeCompletionRoute(
        surface: "slack",
        sessionId: "session-retry",
        destinationId: "C123"
      ),
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "completed")
    #expect(result.attempts == 3)
    #expect(await sender.attemptCount() == 3)
    #expect(Set(await sender.idempotencyKeys()).count == 1)
  }

  @Test
  func partialFailureNeverResendsAcceptedTextOrAmbiguousAttachment() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let imageURL = fixture.directory.appendingPathComponent("image.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
    let attachment = ChatOrchestration.MultimodalAttachment(
      id: "image-1",
      type: "image",
      base64: "",
      mime: "image/png",
      name: "image.png",
      byteSize: 4,
      path: imageURL.path
    )
    let sender = CompletionSenderRecorder(failuresBeforeSuccessByKind: ["attachment": 99])
    let route = AgentBridgeCompletionRoute(
      surface: "telegram",
      sessionId: "session-partial",
      destinationId: "123456"
    )

    let first = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [attachment],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(first.status == "outcome_unknown")
    #expect(first.artifactCount == 1)
    #expect(first.attempts == 2)

    let second = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [attachment],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(second.status == "outcome_unknown")
    #expect(second.artifactCount == 1)
    #expect(second.attempts == 0)
    #expect(await sender.attemptedKinds() == ["text", "attachment"])
  }

  @Test
  func acceptedReplayDoesNotReenterTransportPreflight() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder()
    let route = AgentBridgeCompletionRoute(
      surface: "telegram",
      sessionId: "session-replay",
      destinationId: "123456"
    )
    let first = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(first.status == "completed")
    await sender.failFuturePreflights()

    let replay = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(replay.status == "completed")
    #expect(replay.attempts == 0)
    #expect(await sender.preflightCount() == 1)
    #expect(await sender.attemptCount() == 1)
  }

  @Test
  func iosMessageReplayIsStableButAmbiguousPushIsNeverRetried() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder(
      failuresBeforeSuccessByKind: ["ios_notification": 99]
    )
    let route = AgentBridgeCompletionRoute(
      surface: "ios",
      sessionId: "session-ios",
      sourceKey: "iphone:device-a",
      replyTo: "iphone"
    )
    let first = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(first.status == "outcome_unknown")
    #expect(first.artifactCount == 1)
    #expect(first.attempts == 2)
    #expect(await sender.attemptedKinds() == ["ios_message", "ios_notification"])

    let replay = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(replay.status == "outcome_unknown")
    #expect(replay.artifactCount == 1)
    #expect(replay.attempts == 0)
    #expect(await sender.attemptedKinds() == ["ios_message", "ios_notification"])
  }

  @Test
  func iosNotificationDoesNotRunWithoutAcceptedMessage() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder(
      failuresBeforeSuccessByKind: ["ios_message": 99]
    )
    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: AgentBridgeCompletionRoute(surface: "ios", sessionId: "session-ios"),
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "failed_pre_dispatch")
    #expect(result.artifactCount == 0)
    #expect(result.attempts == 0)
    #expect(result.reason == "missing_ios_source_key")
    #expect(await sender.attemptedKinds().isEmpty)
    #expect(await sender.preflightCount() == 0)
    #expect(await sender.refreshedSessions().isEmpty)
  }

  @Test(arguments: [
    AgentBridgeCompletionRoute(surface: "", sessionId: "missing"),
    AgentBridgeCompletionRoute(surface: "slakc", sessionId: "typo"),
    AgentBridgeCompletionRoute(surface: "slack", sessionId: "slack"),
    AgentBridgeCompletionRoute(surface: "telegram", sessionId: "telegram", destinationId: "not-a-number"),
    AgentBridgeCompletionRoute(surface: "ios", sessionId: "ios"),
    AgentBridgeCompletionRoute(surface: "ios", sessionId: "ios-app", sourceKey: "app"),
    AgentBridgeCompletionRoute(surface: "ios", sessionId: "ios-shared", sourceKey: "mobile_app"),
    AgentBridgeCompletionRoute(surface: "ios", sessionId: "ios-blank", sourceKey: "   "),
    AgentBridgeCompletionRoute(surface: "ios", sessionId: "ios-prefix", sourceKey: "iphone:"),
  ])
  func invalidOriginRoutesFailDurablyBeforeAnySenderCall(
    route: AgentBridgeCompletionRoute
  ) async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder()

    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "failed_pre_dispatch")
    #expect(result.attempts == 0)
    #expect(result.artifactCount == 0)
    #expect(await sender.refreshedSessions().isEmpty)
    #expect(await sender.preflightCount() == 0)
    #expect(await sender.attemptCount() == 0)
  }

  @Test(arguments: ["chat", "codex-bridge", "mission", "missions", "workshop"])
  func validLocalOriginsRefreshAndSettleWithoutTransport(surface: String) async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder()

    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: AgentBridgeCompletionRoute(surface: surface, sessionId: "local-session"),
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "completed")
    #expect(result.delivery == "local_session_refresh")
    #expect(await sender.refreshedSessions() == ["local-session"])
    #expect(await sender.preflightCount() == 0)
    #expect(await sender.attemptCount() == 0)
  }

  @Test(arguments: ["iphone", "iphone:User's iPhone", " iphone:device-a "])
  func exactIOSDeviceRouteKeysAreAccepted(raw: String) {
    #expect(AgentBridgeCompletionRouter.isValidIOSDeviceRouteKey(raw))
  }

  @Test
  func concurrentDuplicateDeliveryDispatchesOneArtifact() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = BlockingCompletionSender()
    let route = AgentBridgeCompletionRoute(
      surface: "telegram",
      sessionId: "session-concurrent",
      destinationId: "123456"
    )

    async let first = AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    await sender.waitUntilStarted()
    let duplicate = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: route,
      sender: sender,
      lifecycle: fixture.lifecycle
    )
    #expect(duplicate.status == "in_progress")
    #expect(duplicate.attempts == 0)
    await sender.release()
    let firstResult = await first
    #expect(firstResult.status == "completed")
    #expect(await sender.attemptCount() == 1)
  }

  @Test
  func slackSemanticFailureCannotBecomeAcceptedReceipt() throws {
    #expect(throws: (any Error).self) {
      try LiveAgentBridgeCompletionSender.requireSlackAcceptance(.object([
        "ok": .bool(false),
        "status": .string("failed"),
        "error": .string("channel_not_found"),
      ]))
    }
    try LiveAgentBridgeCompletionSender.requireSlackAcceptance(.object([
      "ok": .bool(true),
      "status": .string("completed"),
    ]))
  }

  @Test
  func missingSlackTokenRemainsRetryablePreDispatchFailure() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }

    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: AgentBridgeCompletionRoute(
        surface: "slack",
        sessionId: "session-no-slack-token",
        destinationId: "C123"
      ),
      sender: LiveAgentBridgeCompletionSender(dataRoot: fixture.directory),
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "failed_pre_dispatch")
    #expect(result.attempts == 0)
    #expect(result.artifactCount == 0)
  }

  @Test
  func missingAttachmentFailsBeforeAnyTransportDispatch() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder()
    let missingPath = fixture.directory.appendingPathComponent("missing.png").path
    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "",
      attachments: [ChatOrchestration.MultimodalAttachment(
        id: "missing-image",
        type: "image",
        base64: "",
        mime: "image/png",
        name: "missing.png",
        byteSize: 4,
        path: missingPath
      )],
      route: AgentBridgeCompletionRoute(
        surface: "telegram",
        sessionId: "session-missing",
        destinationId: "123456"
      ),
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "failed_pre_dispatch")
    #expect(result.attempts == 0)
    #expect(await sender.attemptCount() == 0)
  }

  @Test
  func lifecycleFailureBeforeDispatchIsNotMislabeledOutcomeUnknown() async throws {
    let fixture = try await LifecycleFixture.make()
    defer { fixture.cleanup() }
    let sender = CompletionSenderRecorder()
    let statePath = fixture.directory
      .appendingPathComponent("codex-completion-lifecycle", isDirectory: true)
      .appendingPathComponent(
        "\(CausalTransitionEvidence.opaqueIdentity(fixture.deliveryId)).json"
      )
    try Data("{corrupt".utf8).write(to: statePath)

    let result = await AgentBridgeCompletionRouter.deliver(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest,
      text: "Done.",
      attachments: [],
      route: AgentBridgeCompletionRoute(
        surface: "telegram",
        sessionId: "session-corrupt",
        destinationId: "123456"
      ),
      sender: sender,
      lifecycle: fixture.lifecycle
    )

    #expect(result.status == "lifecycle_unavailable")
    #expect(result.attempts == 0)
    #expect(await sender.attemptCount() == 0)
  }

  @Test
  func bridgeStatusDistinguishesAttachmentsAndAmbiguousDelivery() {
    #expect(ClaudeBridge.codexCompletionReplyStatus(
      hasReplyText: false,
      attachmentCount: 1,
      completionDeliveryStatus: "completed"
    ) == "ok")
    #expect(ClaudeBridge.codexCompletionReplyStatus(
      hasReplyText: true,
      attachmentCount: 0,
      completionDeliveryStatus: "outcome_unknown"
    ) == "outcome_unknown")
    #expect(ClaudeBridge.codexCompletionReplyStatus(
      hasReplyText: true,
      attachmentCount: 0,
      completionDeliveryStatus: "lifecycle_unavailable"
    ) == "delivery_lifecycle_unavailable")
    #expect(ClaudeBridge.codexCompletionReplyStatus(
      hasReplyText: false,
      attachmentCount: 0,
      completionDeliveryStatus: nil
    ) == "no_reply")
  }
}

private actor CompletionSenderRecorder: AgentBridgeCompletionSending {
  enum ProbeError: Error { case transient }

  private var refreshed: [String] = []
  private var attempts: [(kind: String, key: String)] = []
  private var destinations: [String] = []
  private var remainingFailures: [String: Int]
  private var preflightCalls = 0
  private var preflightShouldFail = false

  init(failuresBeforeSuccessByKind: [String: Int] = [:]) {
    self.remainingFailures = failuresBeforeSuccessByKind
  }

  func refreshLocalChat(sessionId: String?) async {
    if let sessionId { refreshed.append(sessionId) }
  }

  func preflight(
    surface: String,
    route: AgentBridgeCompletionRoute,
    artifacts: [AgentBridgeCompletionArtifact]
  ) async throws {
    preflightCalls += 1
    if preflightShouldFail { throw ProbeError.transient }
    #expect(!artifacts.isEmpty)
  }

  func send(
    artifact: AgentBridgeCompletionArtifact,
    idempotencyKey: String,
    surface: String,
    route: AgentBridgeCompletionRoute
  ) async -> AgentBridgeTransportResult {
    attempts.append((artifact.kind, idempotencyKey))
    if let destination = route.destinationId { destinations.append(destination) }
    let remaining = remainingFailures[artifact.kind] ?? 0
    if remaining > 0 {
      remainingFailures[artifact.kind] = remaining - 1
      return artifact.retrySafe
        ? .rejected(reason: "transient", retryable: true)
        : .ambiguous(reason: "transient")
    }
    return .accepted
  }

  func refreshedSessions() -> [String] { refreshed }
  func telegramDestinations() -> [String] { destinations }
  func attemptCount() -> Int { attempts.count }
  func idempotencyKeys() -> [String] { attempts.map(\.key) }
  func attemptedKinds() -> [String] { attempts.map(\.kind) }
  func preflightCount() -> Int { preflightCalls }
  func failFuturePreflights() { preflightShouldFail = true }
}

private actor BlockingCompletionSender: AgentBridgeCompletionSending {
  private var started = false
  private var attempts = 0
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func refreshLocalChat(sessionId: String?) async {}

  func preflight(
    surface: String,
    route: AgentBridgeCompletionRoute,
    artifacts: [AgentBridgeCompletionArtifact]
  ) async throws {}

  func send(
    artifact: AgentBridgeCompletionArtifact,
    idempotencyKey: String,
    surface: String,
    route: AgentBridgeCompletionRoute
  ) async -> AgentBridgeTransportResult {
    attempts += 1
    started = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return .accepted
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startedContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func attemptCount() -> Int { attempts }
}

private struct LifecycleFixture {
  let directory: URL
  let deliveryId: String
  let requestDigest: String
  let lifecycle: CodexCompletionLifecycle

  static func make(owner: String = "owner-a") async throws -> LifecycleFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nativeagent-codex-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = LifecycleFixture(
      directory: directory,
      deliveryId: UUID().uuidString,
      requestDigest: "digest-a",
      lifecycle: CodexCompletionLifecycle(
        receiptURL: directory.appendingPathComponent("message-replies.jsonl"),
        ownerInstanceId: owner
      )
    )
    #expect(try await fixture.lifecycle.claim(
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest
    ) == .start)
    try await fixture.lifecycle.cacheResponse(
      ChatOrchestration.ChatResponse(
        runId: "run-1",
        model: "model-1",
        output: "Done.",
        sessionId: "session-1"
      ),
      deliveryId: fixture.deliveryId,
      requestDigest: fixture.requestDigest
    )
    return fixture
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
