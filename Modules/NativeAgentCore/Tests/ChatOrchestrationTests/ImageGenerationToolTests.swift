import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import MacIntegration

private func makeImageRoot(imageAllowed: Bool) async throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("imagegen-\(UUID().uuidString)", isDirectory: true)
    let policyPath = root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json")
    let policy: JSONValue = .object([
        "multimodalPolicy": .object([
            "image_generation_openai": .bool(imageAllowed)
        ])
    ])
    try await SwiftNativePersistenceCore().writeJSON(policy, to: policyPath)
    return root
}

final class ImageGenerationStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]
    nonisolated(unsafe) static var capturedBody: [String: Any] = [:]
    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var responseData: Data = Data()

    static func reset() {
        capturedURL = nil
        capturedMethod = nil
        capturedHeaders = [:]
        capturedBody = [:]
        responseStatus = 200
        let b64 = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        responseData = Data(#"{"data":[{"b64_json":""#.utf8)
            + Data(b64.utf8)
            + Data(#"","revised_prompt":"small moon watercolor"}],"usage":{"input_tokens":12}}"#.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        Self.capturedMethod = request.httpMethod
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            stream.close()
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.capturedBody = obj
            }
        } else if let body = request.httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            Self.capturedBody = obj
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func imageStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ImageGenerationStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func capturedHeader(_ name: String) -> String? {
    ImageGenerationStubURLProtocol.capturedHeaders.first {
        $0.key.lowercased() == name.lowercased()
    }?.value
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func makeCodexAccessJWT(accountID: String, exp: Int = Int(Date().timeIntervalSince1970) + 3600) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: [
        "exp": exp,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": accountID,
        ],
    ] as [String: Any])
    return "\(base64URL(header)).\(base64URL(payload)).signature"
}

private func writeCodexAuthJSON(root: URL, accountID: String = "acct_image_test") throws -> (URL, String) {
    let authPath = root
        .appendingPathComponent("codex_home", isDirectory: true)
        .appendingPathComponent("auth.json", isDirectory: false)
    try FileManager.default.createDirectory(
        at: authPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let token = try makeCodexAccessJWT(accountID: accountID)
    let payload: [String: Any] = [
        "tokens": [
            "access_token": token,
            "refresh_token": "rt_image_test",
            "account_id": accountID,
        ],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: authPath)
    return (authPath, token)
}

private final class CapturedCodexInvocation: @unchecked Sendable {
    var invocation: CodexImageGenerationInvocation?
    var called = false
}

@Suite(.serialized)
struct ImageGenerationToolTests {

    @Test func codexOAuthImageClientUsesResponsesImageGenerationTool() async throws {
        ImageGenerationStubURLProtocol.reset()
        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (authPath, token) = try writeCodexAuthJSON(root: root, accountID: "acct_image_123")
        let imageB64 = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        ImageGenerationStubURLProtocol.responseData = Data("""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Generated a small moon."}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"image_generation_call","result":"\(imageB64)"}}

        data: [DONE]

        """.utf8)
        let client = SwiftCodexOAuthImageGenerationClient(
            session: imageStubSession(),
            authPathOverride: authPath,
            dataRoot: root
        )

        let result = try await client.generate(CodexImageGenerationRequest(
            prompt: "small moon watercolor",
            size: "landscape",
            quality: "high",
            outputFormat: "webp",
            count: 1,
            timeoutSeconds: 60
        ))

        #expect(result.model == "gpt-image-2-high")
        #expect(result.reply == "Generated a small moon.")
        #expect(result.sourceImages.count == 1)
        let source = try #require(result.sourceImages.first)
        #expect(source.pathExtension == "png")
        #expect(try Data(contentsOf: source) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(ImageGenerationStubURLProtocol.capturedURL?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(ImageGenerationStubURLProtocol.capturedMethod == "POST")
        #expect(capturedHeader("Authorization") == "Bearer \(token)")
        #expect(capturedHeader("chatgpt-account-id") == "acct_image_123")
        #expect(capturedHeader("originator") == "nativeagent")
        #expect(capturedHeader("Accept") == "text/event-stream")
        #expect(capturedHeader("Content-Type") == "application/json")
        #expect(ImageGenerationStubURLProtocol.capturedBody["model"] as? String == nativeAgentPrimaryModel)
        #expect(ImageGenerationStubURLProtocol.capturedBody["store"] as? Bool == false)
        #expect(ImageGenerationStubURLProtocol.capturedBody["stream"] as? Bool == true)
        let tools = try #require(ImageGenerationStubURLProtocol.capturedBody["tools"] as? [[String: Any]])
        let tool = try #require(tools.first)
        #expect(tool["type"] as? String == "image_generation")
        #expect(tool["model"] as? String == "gpt-image-2")
        #expect(tool["size"] as? String == "1536x1024")
        #expect(tool["quality"] as? String == "high")
        #expect(tool["output_format"] as? String == "png")
        let toolChoice = try #require(ImageGenerationStubURLProtocol.capturedBody["tool_choice"] as? [String: Any])
        #expect(toolChoice["mode"] as? String == "required")
        let allowed = try #require(toolChoice["tools"] as? [[String: Any]])
        #expect(allowed.first?["type"] as? String == "image_generation")
    }

    @Test func codexOAuthImageGenerationTrustDeniedBeforeNetworkOrAuth() async throws {
        ImageGenerationStubURLProtocol.reset()
        let root = try await makeImageRoot(imageAllowed: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (authPath, _) = try writeCodexAuthJSON(root: root)
        let client = SwiftCodexOAuthImageGenerationClient(
            session: imageStubSession(),
            authPathOverride: authPath,
            dataRoot: root
        )

        await #expect(throws: ImageGenerationToolError.trustDenied) {
            _ = try await client.generate(CodexImageGenerationRequest(
                prompt: "small moon watercolor",
                size: nil,
                quality: nil,
                outputFormat: "png",
                count: 1,
                timeoutSeconds: 60
            ))
        }
        #expect(ImageGenerationStubURLProtocol.capturedURL == nil)
    }

    @Test func codexImageClientUsesImagegenAndCollectsArtifact() async throws {
        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-imagegen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let captured = CapturedCodexInvocation()
        let runner: CodexImageGenerationRunner = { invocation in
            captured.called = true
            captured.invocation = invocation
            try FileManager.default.createDirectory(
                at: invocation.codexGeneratedImagesDir,
                withIntermediateDirectories: true
            )
            let sessionDir = invocation.codexGeneratedImagesDir
                .appendingPathComponent("019f-image-test", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let imagePath = sessionDir.appendingPathComponent("agent-test.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imagePath)
            return CodexImageGenerationProcessResult(
                exitCode: 0,
                stdout: "generated",
                stderr: "",
                lastMessage: "Generated one image.",
                timedOut: false,
                durationMs: 42
            )
        }
        let client = SwiftCodexImageGenerationClient(
            runner: runner,
            codexHome: codexHome,
            dataRoot: root,
            cwd: root
        )

        let result = try await client.generate(CodexImageGenerationRequest(
            prompt: "Agent as a luminous desktop agent",
            size: "1024x1024",
            quality: "high",
            outputFormat: "png",
            count: 1,
            timeoutSeconds: 60
        ))

        #expect(captured.called)
        let invocation = try #require(captured.invocation)
        #expect(invocation.arguments.prefix(2) == ["codex", "exec"])
        #expect(!invocation.arguments.contains("--ephemeral"))
        #expect(invocation.arguments.contains("--enable"))
        #expect(invocation.arguments.contains("image_generation"))
        #expect(invocation.arguments.contains("-o"))
        let prompt = try #require(invocation.arguments.last)
        #expect(prompt.contains("imagegen skill's default built-in image_gen tool"))
        #expect(prompt.contains("Do not use OPENAI_API_KEY"))
        #expect(prompt.contains("IMAGE_GEN_UNAVAILABLE"))
        #expect(prompt.contains("Agent as a luminous desktop agent"))
        #expect(result.model == "codex-imagegen")
        #expect(result.sourceImages.count == 1)
        #expect(result.sourceImages.first?.lastPathComponent == "agent-test.png")
        #expect(result.reply == "Generated one image.")
    }

    @Test func codexImageGenerationTrustDeniedBeforeSpawn() async throws {
        let root = try await makeImageRoot(imageAllowed: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = CapturedCodexInvocation()
        let runner: CodexImageGenerationRunner = { _ in
            captured.called = true
            return CodexImageGenerationProcessResult(
                exitCode: 0,
                stdout: "",
                stderr: "",
                lastMessage: "",
                timedOut: false,
                durationMs: 1
            )
        }
        let client = SwiftCodexImageGenerationClient(
            runner: runner,
            codexHome: root.appendingPathComponent("codex-home", isDirectory: true),
            dataRoot: root,
            cwd: root
        )

        await #expect(throws: ImageGenerationToolError.trustDenied) {
            _ = try await client.generate(CodexImageGenerationRequest(
                prompt: "small moon watercolor",
                size: nil,
                quality: nil,
                outputFormat: "png",
                count: 1,
                timeoutSeconds: 60
            ))
        }
        #expect(!captured.called)
    }

    @Test func codexImageGenerationRequiresRealArtifact() async throws {
        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-imagegen-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let runner: CodexImageGenerationRunner = { invocation in
            try FileManager.default.createDirectory(
                at: invocation.codexGeneratedImagesDir,
                withIntermediateDirectories: true
            )
            return CodexImageGenerationProcessResult(
                exitCode: 0,
                stdout: "Generated with built-in image_gen.",
                stderr: "",
                lastMessage: "Generated with built-in image_gen.",
                timedOut: false,
                durationMs: 42
            )
        }
        let client = SwiftCodexImageGenerationClient(
            runner: runner,
            codexHome: codexHome,
            dataRoot: root,
            cwd: root
        )

        await #expect(throws: ImageGenerationToolError.noCodexImagesFound) {
            _ = try await client.generate(CodexImageGenerationRequest(
                prompt: "Agent as a luminous desktop agent",
                size: nil,
                quality: nil,
                outputFormat: "png",
                count: 1,
                timeoutSeconds: 60
            ))
        }
    }

    @Test func imageClientRequestMatchesOpenAIShape() async throws {
        ImageGenerationStubURLProtocol.reset()
        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftOpenAIImageGenerationClient(
            session: imageStubSession(),
            apiKeyOverride: "sk-image-test",
            dataRoot: root
        )

        let result = try await client.generate(OpenAIImageGenerationRequest(
            prompt: "small moon watercolor",
            model: "gpt-image-2",
            size: "1024x1024",
            quality: "medium",
            outputFormat: "png",
            count: 1
        ))

        #expect(result.images.count == 1)
        #expect(result.images.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(result.images.first?.revisedPrompt == "small moon watercolor")
        #expect(ImageGenerationStubURLProtocol.capturedURL?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(ImageGenerationStubURLProtocol.capturedMethod == "POST")
        #expect(ImageGenerationStubURLProtocol.capturedHeaders["Authorization"] == "Bearer sk-image-test")
        #expect(ImageGenerationStubURLProtocol.capturedHeaders["Content-Type"] == "application/json")
        #expect(ImageGenerationStubURLProtocol.capturedHeaders["User-Agent"] == "NativeAgent/0.2.0")
        #expect(ImageGenerationStubURLProtocol.capturedBody["model"] as? String == "gpt-image-2")
        #expect(ImageGenerationStubURLProtocol.capturedBody["prompt"] as? String == "small moon watercolor")
        #expect(ImageGenerationStubURLProtocol.capturedBody["size"] as? String == "1024x1024")
        #expect(ImageGenerationStubURLProtocol.capturedBody["quality"] as? String == "medium")
        #expect(ImageGenerationStubURLProtocol.capturedBody["output_format"] as? String == "png")
        #expect(ImageGenerationStubURLProtocol.capturedBody["n"] as? Int == 1)
    }

    @Test func imageGenerationTrustDeniedBeforeNetwork() async throws {
        ImageGenerationStubURLProtocol.reset()
        let root = try await makeImageRoot(imageAllowed: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftOpenAIImageGenerationClient(
            session: imageStubSession(),
            apiKeyOverride: "sk-image-test",
            dataRoot: root
        )

        await #expect(throws: ImageGenerationToolError.trustDenied) {
            _ = try await client.generate(OpenAIImageGenerationRequest(
                prompt: "small moon watercolor",
                model: "gpt-image-2",
                size: nil,
                quality: nil,
                outputFormat: "png",
                count: 1
            ))
        }
        #expect(ImageGenerationStubURLProtocol.capturedURL == nil)
    }

    @Test func imageGenerateIsCatalogVisibleButLazy() async throws {
        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)

        #expect(SwiftToolDispatcher.builtInToolNames.contains("image_generate"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("image_generate"))

        let schema = try #require(dispatcher.builtInToolSchemas(includeFullMacFileTools: false).first { $0.name == "image_generate" })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let obj) = parsed,
              case .array(let required)? = obj["required"],
              case .object(let properties)? = obj["properties"] else {
            Issue.record("image_generate schema malformed")
            return
        }
        #expect(required == [.string("prompt")])
        #expect(properties["prompt"] != nil)
        #expect(properties["provider"] != nil)
        #expect(properties["output_format"] != nil)
        #expect(schema.description.contains("Defaults to Codex/ChatGPT OAuth"))
        #expect(schema.description.contains("image_generation tool"))

        let sessionId = "image-session-\(UUID().uuidString)"
        let loaded = try await dispatcher.impl_tool_load(input: [
            "session_id": .string(sessionId),
            "category": .string("art"),
        ])
        guard case .object(let loadObj) = loaded,
              case .array(let names)? = loadObj["loaded"],
              case .array(let schemas)? = loadObj["schemas_added"] else {
            Issue.record("image tool_load malformed: \(loaded)")
            return
        }
        #expect(names.contains(.string("image_generate")))
        #expect(schemas.contains { row in
            guard case .object(let obj) = row,
                  case .string("image_generate")? = obj["name"] else { return false }
            return true
        })
    }

    @Test func imageArtPromptPreloadsImageGenerate() async throws {
        let prediction = ToolPreloadHeuristics.predict(
            userMessage: "can you generate an image of Agent as a luminous desktop agent"
        )
        #expect(prediction?.groupNames.contains("art") == true)
        #expect(prediction?.candidateTools.contains("image_generate") == true)

        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = await ToolPreloadHeuristics.preloadIfConfident(
            prediction: prediction,
            sessionId: "image-preload-\(UUID().uuidString)",
            activeTools: [],
            availableToolNames: Set(SwiftToolDispatcher.builtInToolNames),
            surface: "chat",
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )
        #expect(active.contains("image_generate"))
    }

    @Test func generatedImageArtifactsBecomePathBackedAttachments() async throws {
        let root = try await makeImageRoot(imageAllowed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generatedRoot = root.appendingPathComponent("generated_images", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedRoot, withIntermediateDirectories: true)
        let imageURL = generatedRoot.appendingPathComponent("agent-art.png")
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
        try imageBytes.write(to: imageURL)
        let outsideURL = root.appendingPathComponent("outside.png")
        try imageBytes.write(to: outsideURL)

        let dispatch = TurnEngineResult.ToolDispatchRecord(
            name: "image_generate",
            input: [:],
            result: .object([
                "images": .array([
                    .object([
                        "path": .string(imageURL.path),
                        "filename": .string("agent-art.png"),
                    ]),
                    .object([
                        "path": .string(outsideURL.path),
                        "filename": .string("outside.png"),
                    ]),
                ])
            ])
        )

        let attachments = ChatGeneratedImageArtifacts.attachments(from: [dispatch], dataRoot: root)
        let attachment = try #require(attachments.first)
        #expect(attachments.count == 1)
        #expect(attachment.type == "image")
        #expect(attachment.mime == "image/png")
        #expect(attachment.name == "agent-art.png")
        #expect(attachment.byteSize == imageBytes.count)
        #expect(attachment.path == imageURL.path)
        #expect(attachment.base64.isEmpty)

        let bridgeAttachment = try #require(ChatGeneratedImageArtifacts.imageDataAttachment(from: attachment))
        #expect(bridgeAttachment.base64 == imageBytes.base64EncodedString())
        #expect(bridgeAttachment.byteSize == imageBytes.count)
        #expect(bridgeAttachment.path == imageURL.path)
    }
}
