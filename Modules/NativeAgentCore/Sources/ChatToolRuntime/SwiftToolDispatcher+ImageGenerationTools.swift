import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Dispatcher
import ImageIO
import TrustCenter
// Blueprint: | `SwiftToolDispatcher+ImageGenerationTools.swift` | `SwiftToolDispatcher`: image generation, display and references; checked routing failures propagate without a model-choice card; Codex settlement preserves captured output and produced images through Stop, then writes one terminal receipt; successful responses normalize to ok for Make registration while stopped receipts stay stopped |

// Admission is bound only around an explicitly requested image tool call.
// Backend clients keep their default-deny policy for callers outside that turn.
enum ImageGenerationAdmission {
    @TaskLocal static var fullMacAdmitted = false

    static func allowed(dataRoot: URL) async throws -> Bool {
        if ImageGenerationAdmission.fullMacAdmitted { return true }
        let authority = SavedTrustPolicyAuthority.read(dataRoot: dataRoot)
        if case .damaged = authority {
            throw ToolFailureError("Saved Trust policy could not be read or validated. Preserve the damaged file and ask the owner to repair it.",
                effects: .none, owner: SavedTrustPolicyAuthority.policyURL(dataRoot: dataRoot).path,
                tap: "Trust > Access and policy > Preserve damaged policy and authorize Safe",
                code: "trust_policy_unavailable", instruction: "Ask the owner to preserve the damaged policy and authorize Safe.")
        }
        return authority.flag(block: "multimodalPolicy", key: "image_generation_openai", default: false)
    }

    static func clippedPrompt(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars
        guard scalars.count > 16_000 else { return prompt }
        return String(String.UnicodeScalarView(scalars.prefix(16_000)))
    }
}

enum ImageGenerationToolError: Error, Equatable, Sendable, LocalizedError {
    case trustDenied
    case missingPrompt
    case unsupportedProvider(String)
    case codexUnavailable
    case codexFailed(exitCode: Int32, message: String)
    case noCodexImagesFound
    case notConfigured
    case authRejected
    case apiError(status: Int, message: String?)
    case transport(message: String)
    case invalidResponse(String)
    case invalidImageData
    case unsupportedControl(String)
    /// Refuse unsupported image generation on the Work route and name that route in the result.
    case routeCannotGenerateImages(route: String)

    var errorDescription: String? {
        switch self {
        case .trustDenied:
            return "[trust_denied] Image generation is disabled. In Trust, turn on ‘Allow image generation’, then try again."
        case .missingPrompt:
            return "prompt is required"
        case .unsupportedProvider(let provider):
            return "[image_generation_unsupported_provider] Use provider='codex', provider='codex_cli', or provider='openai_api', not '\(provider)'."
        case .codexUnavailable:
            return "[image_generation_codex_unavailable] Codex image generation is unavailable. It requires the Codex command-line tool installed on this Mac and signed in with an account that can use Codex image generation. Install the Codex command-line tool if needed, then run `codex login` in Terminal. Signing in to ChatGPT chat in NativeAgent alone does not complete this setup."
        case .codexFailed(let exitCode, let message):
            return "[image_generation_codex_failed] codex exec exited \(exitCode): \(message)"
        case .noCodexImagesFound:
            return "[image_generation_no_artifact] Codex returned no collectable image. Check image-generation access in the installed Codex CLI/account. To choose the separately billed OpenAI API instead, open Providers, set up OpenAI with an API key, then select OpenAI for Work before calling image.generate."
        case .notConfigured:
            return "[image_generation_openai_api_unavailable] OpenAI API images need a separately billed API key. In Providers, set up OpenAI and save the key; select OpenAI for Work before calling image.generate."
        case .authRejected:
            return "[image_generation_auth_error] OpenAI rejected the API key. Open Providers, choose ‘Set up’ for OpenAI, and replace and save the key, then try again."
        case .apiError(let status, let message):
            if let message, !message.isEmpty {
                return "[image_generation_api_error] HTTP \(status): \(message)"
            }
            return "[image_generation_api_error] HTTP \(status)"
        case .transport(let message):
            return "[image_generation_error] \(message)"
        case .invalidResponse(let message):
            return "[image_generation_invalid_response] \(message)"
        case .invalidImageData:
            return "[image_generation_invalid_image_data] Response did not include decodable base64 image data."
        case .unsupportedControl(let detail):
            return "[image_generation_unsupported_control] \(detail)"
        case .routeCannotGenerateImages(let route):
            let named = route.isEmpty
                ? "Work has no provider connected"
                : "Work runs on \(route), which generates no images"
            return "[image_generation_route_unavailable] \(named). Open Providers and give the "
                + "Work group a provider that makes images. NativeAgent will not send this to a "
                + "different one."
        }
    }
}

extension SwiftToolDispatcher {
    func impl_image_generate(input: [String: JSONValue], surface: String = "unknown") async -> JSONValue {
        let admitted = await fullMacYoloAdmitted(surface: surface)
        return await ImageGenerationAdmission.$fullMacAdmitted.withValue(admitted) {
            await impl_admitted_image_generate(input: input, surface: surface)
        }
    }

    private func impl_admitted_image_generate(input: [String: JSONValue], surface: String) async -> JSONValue {
        let input = input.filter {
            if case .string(let text) = $0.value { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
        let prompt = input["prompt"]?.stringValue ?? input["description"]?.stringValue ?? ""
        let requestedProvider = normalizedImageProvider((input["provider"] ?? input["backend"])?.stringValue)
        let outputFormat = normalizedImageOutputFormat((input["output_format"] ?? input["format"])?.stringValue)
        var admittedRoute: (providerID: String, controllerModel: String,
            route: FirstPartyModelCatalog.FirstPartyImageRoute?, snapshot: ProviderRoutingSnapshot)?
        do {
            for key in ["reasoning_effort", "reasoning", "image_reasoning_effort"]
            where input[key] != nil && input[key] != .null {
                throw ImageGenerationToolError.unsupportedControl("\(key) is not an image quality control and is not exposed by image_generate.")
            }
            // Check Trust first; supplied provider/model names must match the Work route, which must support images.
            guard try await ImageGenerationAdmission.allowed(dataRoot: dataRoot) else {
                throw ImageGenerationToolError.trustDenied
            }
            let resolved = try await workGroupImageRoute()
            admittedRoute = resolved
            guard let route = resolved.route else {
                throw ImageGenerationToolError.routeCannotGenerateImages(route: resolved.providerID)
            }
            let provider = route.backend
            let controllerModel = resolved.controllerModel
            if let requestedProvider, requestedProvider != provider,
               !(provider == "codex" && requestedProvider == "codex_cli") {
                throw ImageGenerationToolError.unsupportedControl(
                    "image_generate cannot choose its own provider: it runs on the route picked for"
                        + " Work (\(provider)). Remove provider/backend, or change the Work group in"
                        + " Providers. Requested: \(requestedProvider)."
                )
            }
            let model = route.model
            if let requestedModel = input["model"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedModel.isEmpty,
               requestedModel.caseInsensitiveCompare(model) != .orderedSame {
                throw ImageGenerationToolError.unsupportedControl(
                    "image_generate cannot choose its own image model: the \(provider) route names"
                        + " \(model). Remove model. Requested: \(requestedModel)."
                )
            }
            if provider != "codex" && provider != "codex_cli" {
                for key in ["referenced_image_paths", "action", "previous_response_id", "num_last_images_to_include", "mask", "background", "input_fidelity", "output_compression"] where input[key] != nil && input[key] != .null {
                    // Strict schemas may supply empty optional reference arrays.
                    if key == "referenced_image_paths", input[key] == .array([]) { continue }
                    throw ImageGenerationToolError.unsupportedControl("\(key) is not implemented for provider=\(provider).")
                }
            }
            switch provider {
            case "codex", "codex_cli":
                // Trust precedes file reads as well as OAuth/network access.
                guard try await ImageGenerationAdmission.allowed(dataRoot: dataRoot) else {
                    throw ImageGenerationToolError.trustDenied
                }
                for key in ["prompt", "description", "provider", "backend", "model", "size", "quality", "output_format", "format", "action", "background"] {
                    if let value = input[key], value != .null, case .string = value { continue }
                    if let value = input[key], value != .null {
                        throw ImageGenerationToolError.unsupportedControl("\(key) must be a string.")
                    }
                }
                for key in ["previous_response_id", "num_last_images_to_include", "mask", "input_fidelity", "output_compression"] where input[key] != nil && input[key] != .null {
                    throw ImageGenerationToolError.unsupportedControl("\(key) is not exposed by the Codex OAuth route. Continue edits by supplying the last artifact in referenced_image_paths.")
                }
                let references = try await imageGenerationReferences(input["referenced_image_paths"], surface: surface)
                let request = try CodexImageGenerationRequest(
                    prompt: prompt,
                    size: input["size"]?.stringValue,
                    quality: input["quality"]?.stringValue,
                    outputFormat: (input["output_format"] ?? input["format"])?.stringValue ?? "png",
                    count: Self.jsonInt(input["n"] ?? input["count"]) ?? 1,
                    timeoutSeconds: Self.jsonInt(input["timeout_seconds"]) ?? SwiftCodexImageGenerationClient.defaultTimeoutSeconds,
                    action: input["action"]?.stringValue ?? "auto",
                    references: references,
                    background: input["background"]?.stringValue ?? "auto"
                ).normalizedForBuiltIn()
                // Image work resolves the same account as Work readiness.
                let client = SwiftCodexImageGenerationClient(
                    dataRoot: dataRoot,
                    controllerModel: controllerModel
                )
                let result = try await client.generate(request)
                let receipt = try await settle { [self] in
                    do {
                        return Result<JSONValue, Error>.success(try await persistCodexImageGenerationResult(
                            result, request: request, prompt: prompt, provider: provider))
                    } catch { return Result<JSONValue, Error>.failure(error) }
                }.get()
                return showGeneratedImages(in: receipt)
            case "openai_api":
                let request = OpenAIImageGenerationRequest(
                    prompt: prompt,
                    model: model,
                    size: input["size"]?.stringValue,
                    quality: input["quality"]?.stringValue,
                    outputFormat: outputFormat,
                    count: Self.jsonInt(input["n"] ?? input["count"]) ?? 1
                )
                let client = SwiftOpenAIImageGenerationClient(dataRoot: dataRoot)
                let result = try await client.generate(request)
                return showGeneratedImages(in: try await persistOpenAIImageGenerationResult(
                    result,
                    request: request,
                    prompt: prompt
                ))
            default:
                throw ImageGenerationToolError.unsupportedProvider(provider)
            }
        } catch {
            if let need = imageGenerationNeedEnvelope(error, providerID: admittedRoute?.providerID,
                                                      snapshot: admittedRoute?.snapshot) { return need }
            return imageGenerationErrorEnvelope(error)
        }
    }

    /// Return bounded thumbnails with image rows, retaining full-size paths and explaining failures in visionNote.
    func showGeneratedImages(in envelope: JSONValue) -> JSONValue {
        guard case .object(var object) = envelope,
              case .array(let rows)? = object["images"], !rows.isEmpty else { return envelope }
        var updated: [JSONValue] = []
        var shown = 0
        for row in rows {
            guard case .object(var imageRow) = row,
                  case .string(let path)? = imageRow["path"] else {
                updated.append(row)
                continue
            }
            let outcome = LocalToolImage.showProducedImage(
                at: URL(fileURLWithPath: path),
                name: imageRow["filename"]?.stringValue
            )
            imageRow["shownToModel"] = .bool(outcome.shown)
            imageRow["visionNote"] = .string(outcome.note)
            if let width = outcome.width, let height = outcome.height {
                imageRow["thumbnailWidth"] = .int(Int64(width))
                imageRow["thumbnailHeight"] = .int(Int64(height))
            }
            if outcome.shown { shown += 1 }
            updated.append(.object(imageRow))
        }
        object["images"] = .array(updated)
        object["imagesShownToModel"] = .int(Int64(shown))
        object["visionNote"] = .string(shown > 0
            ? "\(shown) of \(rows.count) generated image(s) follow this tool result as thumbnails —"
                + " look at them before you describe or ship them. The thumbnails are for checking;"
                + " the full-size files are at images[].path."
            : "No generated image could be shown inline this turn — each row's visionNote says why."
                + " Do NOT describe what you have not seen; read the path if you need to look.")
        return .object(object)
    }

    func imageGenerationReferences(_ value: JSONValue?, surface: String) async throws -> [CodexImageReference] {
        guard let value, value != .null else { return [] }
        guard case .array(let paths) = value, paths.count <= 4 else {
            throw ImageGenerationToolError.unsupportedControl("referenced_image_paths must be an array of at most four local image paths.")
        }
        var references: [CodexImageReference] = []
        var bytes = 0
        let fullMacReadAllowed = await fullMacToolAccess(surface: surface).fileOpsAllowed
        for path in paths {
            guard case .string(let rawPath) = path, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImageGenerationToolError.unsupportedControl("Each referenced_image_paths entry must be a nonempty local path.")
            }
            // Existing generated attachments are the tool's own output surface.
            // Permit only its canonical subtree, with symlinks unable to escape it.
            let artifactRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("generated_images", isDirectory: true)
            let path = NativeAgentWorkspaceRoot.fileSpelling(rawPath)
            let candidate = NativeAgentWorkspaceRoot.resolveFileMutationPath(rawPath, dataRoot: dataRoot)
            let url: URL
            if (path.hasPrefix("/") || path.hasPrefix("~")), let tail = NativeAgentWorkspaceRoot.relativePath(candidate.path, under: artifactRoot.path), !tail.isEmpty {
                url = candidate
            } else if fullMacReadAllowed, path.hasPrefix("/") || path.hasPrefix("~") {
                url = candidate
            } else {
                url = try await resolveTrustedFilePath(rawPath)
            }
            try requireNonSensitiveReadPath(url, tool: "image_generate")
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= CodexImageReference.maximumTotalBytes - bytes else {
                throw ImageGenerationToolError.unsupportedControl("References exceed the 20 MiB total limit.")
            }
            let reference = try CodexImageReference.readAuthorized(url)
            bytes += reference.data.count
            guard bytes <= CodexImageReference.maximumTotalBytes else {
                throw ImageGenerationToolError.unsupportedControl("References exceed the 20 MiB total limit.")
            }
            references.append(reference)
        }
        return references
    }

    private func imageGenerationDirectory() throws -> URL {
        // PrivacyMap: generated_images stays local; attachments publish selected image bytes separately.
        let directory = dataRoot.appendingPathComponent("generated_images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("receipts", isDirectory: true),
                                                withIntermediateDirectories: true)
        return directory
    }

    private func finalizeImageGenerationReceipt(_ receipt: [String: JSONValue], message: String) async throws -> JSONValue {
        let id = try JSONRow(.object(receipt)).string("id")
        let path = dataRoot.appendingPathComponent("generated_images/receipts/\(id).json")
        try await SwiftNativePersistenceCore.writeJSON(.object(receipt), to: path)
        var response = receipt
        response["status"] = receipt["status"] == .string("completed") ? .string("ok") : receipt["status"] ?? .string("ok")
        response["receiptPath"] = .string(path.path)
        response["message"] = .string(message)
        return .object(response)
    }

    private func persistOpenAIImageGenerationResult(
        _ result: OpenAIImageGenerationResult,
        request: OpenAIImageGenerationRequest,
        prompt: String
    ) async throws -> JSONValue {
        let runId = UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let baseDir = try imageGenerationDirectory()

        var imageRows: [JSONValue] = []
        for image in result.images {
            let filename = result.images.count == 1
                ? "\(runId).\(request.outputFormat)"
                : "\(runId)-\(image.index + 1).\(request.outputFormat)"
            let path = baseDir.appendingPathComponent(filename, isDirectory: false)
            try image.data.write(to: path, options: .atomic)
            _ = chmod(path.path, 0o600)
            var row: [String: JSONValue] = [
                "index": .int(Int64(image.index)),
                "path": .string(path.path),
                "filename": .string(filename),
                "byteSize": .int(Int64(image.data.count)),
            ]
            if let revised = image.revisedPrompt, !revised.isEmpty {
                row["revisedPrompt"] = .string(String(ChatSecretRedactor.redactText(revised).prefix(1_000)))
            }
            imageRows.append(.object(row))
        }

        var receipt: [String: JSONValue] = [
            "id": .string(runId),
            "tool": .string("image_generate"),
            "provider": .string("openai_api"),
            "model": .string(result.model),
            "createdAt": .string(createdAt),
            "promptPreview": .string(String(ChatSecretRedactor.redactText(prompt).prefix(1_000))),
            "size": request.size.map { .string($0) } ?? .null,
            "quality": request.quality.map { .string($0) } ?? .null,
            "outputFormat": .string(request.outputFormat),
            "count": .int(Int64(result.images.count)),
            "images": .array(imageRows),
        ]
        if let usage = result.usage {
            receipt["usage"] = usage
        }

        return try await finalizeImageGenerationReceipt(receipt,
            message: "Generated \(result.images.count) image\(result.images.count == 1 ? "" : "s") with \(result.model).")
    }

    func persistCodexImageGenerationResult(
        _ result: CodexImageGenerationResult,
        request: CodexImageGenerationRequest,
        prompt: String,
        provider: String = "codex"
    ) async throws -> JSONValue {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let baseDir = try imageGenerationDirectory()

        var imageRows: [JSONValue] = []
        for (idx, source) in result.sourceImages.enumerated() {
            guard result.evidence.indices.contains(idx), case .object(let measured) = result.evidence[idx],
                  case .string(let ext)? = measured["actualFormat"] else { throw ImageGenerationToolError.invalidImageData }
            let filename = result.runId + (result.sourceImages.count == 1 ? "" : "-\(idx + 1)") + ".\(ext)"
            let destination = baseDir.appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            _ = chmod(destination.path, 0o600)
            let byteSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            imageRows.append(.object([
                "index": .int(Int64(idx)),
                "path": .string(destination.path),
                "filename": .string(filename),
                "byteSize": .int(Int64(byteSize)),
            ]))
        }

        var receipt: [String: JSONValue] = [
            "id": .string(result.runId),
            "status": .string(result.stopped ? "stopped" : "completed"),
            "tool": .string("image_generate"),
            "provider": .string(provider),
            "model": .string(result.model),
            "createdAt": .string(createdAt),
            "promptPreview": .string(String(ChatSecretRedactor.redactText(prompt).prefix(1_000))),
            "size": request.size.map { .string($0) } ?? .null,
            "quality": request.quality.map { .string($0) } ?? .null,
            "outputFormat": .string(request.outputFormat),
            "count": .int(Int64(imageRows.count)),
            "durationMs": .int(Int64(result.durationMs)),
            "exitCode": .int(Int64(result.exitCode)),
            "images": .array(imageRows),
            "providerToolReceipts": .array(result.evidence),
            "requestedAction": .string(request.action),
            "referenceCount": .int(Int64(request.references.count)),
        ]
        if provider == "codex" || provider == "codex_cli" {
            func uniformEvidence(_ key: String) -> String {
                let values = result.evidence.map { value -> String in
                    guard case .object(let row) = value, case .string(let text)? = row[key], !text.isEmpty else { return "unknown" }
                    return text
                }
                return Set(values).count == 1 ? values[0] : "unknown"
            }
            receipt["imageModel"] = .string(result.model)
            receipt["transport"] = .string(uniformEvidence("transport"))
            receipt["sourceTool"] = .string(uniformEvidence("tool"))
            receipt["codexThreadId"] = .string(uniformEvidence("codexThreadId"))
            receipt["backendToolModel"] = .string("unknown")
            receipt["backendToolModelEvidenceSource"] = .string("not_exposed_by_builtin")
            receipt["responseModel"] = .string("not_applicable")
            receipt["modelVersion"] = .string("unverified")
            receipt["modelExplanation"] = .string("Executed through Codex's built-in image_gen.imagegen tool. Its exposed result has no image-model identifier or quality selector; those remain unknown. Quality/size/format/background requests are prompt preferences, not native control guarantees.")
            receipt["requestedQuality"] = request.quality.map { .string($0) } ?? .string("medium")
            receipt["outboundQuality"] = .string("not_exposed")
            receipt["qualityRequestForwarding"] = .string("prompt_preference")
            for key in ["outboundQualityEvidenceSource", "returnedToolQuality", "returnedToolQualityEvidenceSource",
                        "observedQuality", "observedQualityEvidenceSource", "qualityFulfillment", "actionFulfillment"] {
                receipt[key] = .string("unknown")
            }
            // An image can be valid while other requested controls were not honored.
            var controlWarnings: [JSONValue] = []
            for key in ["sizeFulfillment", "formatFulfillment"] {
                let values = result.evidence.map { value -> String in
                    guard case .object(let row) = value, case .string(let text)? = row[key] else { return "unknown" }
                    return text
                }
                let fulfillment = values.contains("not_fulfilled") ? "not_fulfilled"
                    : (values.contains("unknown") ? "unknown"
                       : (Set(values).count == 1 ? values.first! : "unknown"))
                receipt[key] = .string(fulfillment)
                if fulfillment == "not_fulfilled" {
                    controlWarnings.append(.string("\(key): at least one image differs from the requested setting; inspect providerToolReceipts for requested and actual values."))
                }
            }
            receipt["controlWarnings"] = .array(controlWarnings)
        }
        if !result.reply.isEmpty {
            receipt["codexReply"] = .string(String(ChatSecretRedactor.redactText(result.reply).prefix(2_000)))
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receipt["codexStderrPreview"] = .string(String(ChatSecretRedactor.redactText(result.stderr).prefix(2_000)))
        }

        let message: String
        let providerName = provider == "codex_cli" ? "Codex CLI" : "Codex OAuth"
        if result.stopped {
            message = "Stopped image generation. Saved \(imageRows.count) image(s) produced before Stop; the captured output remains in the run folder."
        } else if case .array(let warnings)? = receipt["controlWarnings"], !warnings.isEmpty {
            message = "Generated \(imageRows.count) image(s) through \(providerName), but some requested controls were not fulfilled. Inspect controlWarnings and providerToolReceipts."
        } else {
            message = "Generated \(imageRows.count) image\(imageRows.count == 1 ? "" : "s") through \(providerName)."
        }
        return try await finalizeImageGenerationReceipt(receipt, message: message)
    }

    /// Only Trust, credentials and an unsupported Work route ask the person for a decision.
    /// Other image-generation errors remain failures.
    private func imageGenerationNeedEnvelope(
        _ error: Error, providerID: String?, snapshot: ProviderRoutingSnapshot?
    ) -> JSONValue? {
        guard let typed = error as? ImageGenerationToolError else { return nil }
        switch typed {
        case .trustDenied:
            // The switch exists in Trust and the person owns it.
            return InlineInteractionRegistry.capability(
                "image_generation",
                why: "Making pictures is switched off, so I stopped before trying.",
                declineConsequence: "It stays off and I'll describe what I'd have drawn instead."
            ).map { InlineInteractionNeed.envelope($0) }

        case .notConfigured, .authRejected:
            // Missing and rejected keys both ask for a working key.
            guard let providerID else { return nil }
            let why = typed == .authRejected
                ? "The saved key for this provider was rejected, so the picture never started."
                : "Making pictures here needs an API key I don't have yet."
            return InlineInteractionNeed.envelope(
                InlineInteractionRegistry.apiKey(
                    provider: providerID,
                    why: why,
                    declineConsequence: "No key, no picture — nothing else about this turn changes."
                )
            )

        case .routeCannotGenerateImages:
            // A one-image choice never rewrites the Work group's saved route.
            guard let providerID, let snapshot else { return nil }
            // The Providers catalog supplies choices; an empty list directs the person to Providers.
            let options = InlineInteractionRegistry.imageCapableModelOptions(
                providerIDs: imageCandidateProviderIDs(snapshot: snapshot)
            )
            return InlineInteractionNeed.envelope(
                InlineInteractionRegistry.modelChoice(
                    group: ProviderSurfaceGroups.work.id,
                    why: "\(providerID.isEmpty ? "The model your Work tasks use" : providerID) can't make pictures.",
                    options: options,
                    scopedToThisRequest: "this image",
                    declineConsequence: "I'll skip the picture and leave your Work models alone."
                )
            )

        default:
            return nil
        }
    }

    private func imageGenerationErrorEnvelope(_ error: Error) -> JSONValue {
        guard error is ImageGenerationToolError else {
            return ChatToolOutcome.failure(error: error, tool: "image_generate")
        }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let reason: String = {
            guard let e = error as? ImageGenerationToolError else { return "image_generation_failed" }
            switch e {
            case .trustDenied: return "trust_denied"
            case .missingPrompt: return "missing_prompt"
            case .unsupportedProvider: return "unsupported_provider"
            case .codexUnavailable: return "codex_unavailable"
            case .codexFailed: return "codex_failed"
            case .noCodexImagesFound: return "no_codex_images_found"
            case .notConfigured: return "not_configured"
            case .authRejected: return "auth_rejected"
            case .apiError: return "api_error"
            case .transport: return "transport_error"
            case .invalidResponse: return "invalid_response"
            case .invalidImageData: return "invalid_image_data"
            case .unsupportedControl: return "unsupported_control"
            case .routeCannotGenerateImages: return "route_cannot_generate_images"
            }
        }()
        return .object([
            "status": .string("failed"),
            "tool": .string("image_generate"),
            "reason": .string(reason),
            "error": .string(message),
        ])
    }

    /// An omitted backend leaves selection to the Work route.
    private func normalizedImageProvider(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "":
            return nil
        case "codex", "codex_oauth", "codex-oauth", "chatgpt", "subscription":
            return "codex"
        case "codex_cli", "codex-cli", "cli":
            return "codex_cli"
        case "openai", "openai_api", "openai-api", "api", "platform":
            return "openai_api"
        case let other?:
            return other
        }
    }

    /// Resolve Work at dispatch, retaining its provider id even when that route cannot make images.
    func workGroupImageRoute() async throws -> (
        providerID: String,
        controllerModel: String,
        route: FirstPartyModelCatalog.FirstPartyImageRoute?,
        snapshot: ProviderRoutingSnapshot
    ) {
        let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot()
        // A one-request model choice overrides only this resumed request, never saved routing.
        if let override = InlineInteractionModelOverride.binding(
            forGroup: ProviderSurfaceGroups.work.id
        ) {
            return (
                override.providerID,
                override.model,
                FirstPartyModelCatalog.imageRoute(forProviderID: override.providerID),
                snapshot
            )
        }
        // Every group member shares one choice; the first resolved member supplies it.
        var providerID = ""
        var controllerModel = ""
        for surface in ProviderSurfaceGroups.work.surfaces {
            let preference = ProviderRoutingSurfaceLookup.value(snapshot.preferences, surface)
            if controllerModel.isEmpty { controllerModel = preference?.model ?? "" }
            // The group's chosen route only, never inferred from its model's name.
            if let active = ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, surface) {
                providerID = active
                break
            }
        }
        return (providerID, controllerModel, FirstPartyModelCatalog.imageRoute(forProviderID: providerID), snapshot)
    }

    /// Accounts used by active routes or saved model picks; the catalog decides which can draw.
    func imageCandidateProviderIDs(snapshot: ProviderRoutingSnapshot) -> [String] {
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        var ids: [String] = []
        var seen: Set<String> = []
        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty, seen.insert(raw.lowercased()).inserted else { return }
            ids.append(raw)
        }
        for active in snapshot.activeProviders.values { add(active) }
        for preference in snapshot.preferences.values {
            add(router.inferProviderForModel(preference.model))
        }
        return ids
    }

    private func normalizedImageOutputFormat(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "jpeg", "jpg": return "jpeg"
        case "webp": return "webp"
        default: return "png"
        }
    }
}
