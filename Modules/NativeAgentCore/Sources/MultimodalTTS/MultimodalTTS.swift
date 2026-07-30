// SwiftNative port of POST /v1/multimodal/tts (Subsystem #28 — wave 35 W18).
//
// HISTORY / WHY THIS UNBLOCKS WAVE-34:
//   Wave 33 W16 (CUTOVER_PLAN §6.96) and wave 34 W16 (§6.98) both classed this
//   route KEPT_LIVE, BLOCKED on "the Swift secret-resolution layer" — at the
//   time the OpenAI API key was only resolvable daemon-side (Runtime
//   `_VisionClient._get_token`). That blocker is now LIFTED: the chat-path
//   cutover landed `LLMCredentialResolver.resolveAPIKey(envVar:providerConfigFile:)`
//   in the ProviderRouting module (LLMClient+Real.swift), which resolves the
//   OpenAI platform key from the SAME first two sources the daemon's
//   `_get_token` uses — (1) the OPENAI_API_KEY env var, (2)
//   data/providers/openai.json `api_key`. ProviderRouting is already a product
//   dep of NativeAgentApp (Package.swift, wired for BackgroundLoops), so the
//   module-graph blocker is also already closed.
//
// SCOPE (audit-first, method-level):
//   POST /v1/multimodal/tts  (Runtime.multimodal_tts -> _VisionClient.tts)  -> PORTED
//
// The daemon handler:
//   - runs `_multimodal_policy_check("tts_openai")` (trust-policy gate),
//   - validates non-empty text,
//   - calls `_VisionClient.tts(text, voice, fmt)`, a stdlib-urllib passthrough
//     POSTing https://api.openai.com/v1/audio/speech with
//       {model:"tts-1", input:text[:4096], voice, response_format:fmt}
//       headers Authorization: Bearer <token>, Content-Type: application/json,
//       User-Agent: NativeAgent/0.2.0
//     and returns the raw audio bytes (or an "[tts_*]" error string),
//   - base64-encodes the bytes into the {ok, audio_base64, format,
//     duration_ms_estimate, latency_ms} JSON envelope.
//
// WHAT THIS PORT REPRODUCES (verified against the retired daemon primary source,
// NOT assumed):
//   • URL https://api.openai.com/v1/audio/speech
//   • body {model:"tts-1", input:text[:4096], voice, response_format:fmt}
// — note input is truncated to 4096 chars,
//     mirrored here.
//   • headers Authorization/Content-Type/User-Agent.
//   • 60s timeout.
//   • token precedence env -> <dataRoot>/providers/openai.json -> (<dataRoot>/
//     codex_home/auth.json OPENAI_API_KEY field), via LLMCredentialResolver's
//     `dataRoot:` overload — the first two are the daemon's `_get_token`
//     precedence exactly, resolved against the SAME data root the daemon's
//     _VisionClient is constructed with (provider_config_dir=self.root/"providers",
//     codex_home=self.root/"codex_home"), NOT the process CWD. This is the
//     REPO_PATH-parity fix (wave 36 W08 / §6.138): the wave-35 port used the
//     CWD-relative overload, which silently returns notConfigured in an installed
//     .app bundle (CWD `/`) even when the key is present in the stamped data root.
//     (The daemon's third source reads
//     a codex `access_token`/`token` JWT; in the user's OAuth-only production env that
//     JWT is a ChatGPT-backend token, NOT a platform key, and the daemon's own
//     comment at the retired daemon documents that it 401s against the
//     platform `/v1/audio/speech` endpoint. So NOT consulting that JWT here is
//     correct parity, not a regression — we never point a ChatGPT OAuth token at
//     the wrong endpoint.)
//
// TRUST GATE — REPRODUCED NATIVELY (NOT a daemon-only concern):
//   • The `_multimodal_policy_check("tts_openai")` trust gate IS reproduced here
//     by `SwiftOpenAITTSClient.ttsOpenAIAllowed()` (below), which reads
//     `<dataRoot>/trust/policy.json` → `multimodalPolicy.tts_openai`
//     (default-deny / fail-closed); `synthesize` throws `.trustDenied` BEFORE
//     any key/network work when it returns false. This is the gpt-5.5 BLOCKER
//     fix that landed WITH this port (wave-35 W18, §6.117) — it is NOT deferred.
//     [wave 39 W20 §6.201: this header block previously read "the native client
//     does NOT reproduce it … until a future wave ports the trust gate" — that
//     was stale; it predated the same-wave BLOCKER fix and contradicted the
//     `ttsOpenAIAllowed()`/`.trustDenied` code below. Corrected.]
//
// WHAT IS NOT IN SCOPE:
//   • The base64 envelope shape was route-only: the native client returns raw
//     `Data` directly (the consumer, VoiceOutputController, immediately feeds it
//     to AVAudioPlayer(data:)), skipping the base64 round-trip the HTTP path
//     needs only because JSON can't carry raw bytes.
//
// DEP-LIGHT MODULE (mirrors Browser / SwarmRuns / KnowledgeGraph): depends only
// on ProviderRouting (for LLMCredentialResolver) + NativeAgentCore.

import Foundation
import ProviderRouting
import PersistenceCore

/// Error sentinels mirroring the daemon `_VisionClient.tts` / `multimodal_tts`
/// failure strings, so a caller can surface the same user-facing messages on
/// either path. Conforms to `LocalizedError` so the Mac caller's
/// `error.localizedDescription` (VoiceOutputController.speakOpenAI) yields the
/// daemon-equivalent text instead of a generic Swift enum description.
public enum MultimodalTTSError: Error, Equatable, Sendable, LocalizedError {
    /// Trust Center denies `multimodalPolicy.tts_openai` (default OFF). Mirrors
    /// the daemon's `_multimodal_policy_check("tts_openai")` "[trust_denied]" path.
    case trustDenied
    /// No OpenAI platform key found (env / providers / codex). Mirrors the
    /// daemon's "[tts_unavailable] No OpenAI API key found." path.
    case notConfigured
    /// HTTP 401 — token rejected. Mirrors "[tts_auth_error] HTTP 401".
    case authRejected
    /// Any other non-2xx HTTP status. Mirrors "[tts_api_error] HTTP <code>".
    case apiError(status: Int)
    /// Transport/other failure. Mirrors "[tts_error] <exc>".
    case transport(message: String)
    /// Input text was empty (daemon returns {"ok": false, "error": "text is required"}).
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .trustDenied:
            // Matches the retired daemon _multimodal_policy_check trust_denied string.
            return "[trust_denied] Capability 'tts_openai' is disabled in Trust Center. "
                + "To enable: POST /v1/trust with multimodalPolicy.tts_openai=true"
        case .notConfigured:
            return "[tts_unavailable] No OpenAI API key found. "
                + "Set OPENAI_API_KEY in your environment. See docs/multimodal_setup.md."
        case .authRejected:
            return "[tts_auth_error] HTTP 401: API token rejected. "
                + "Set OPENAI_API_KEY in your environment. See docs/multimodal_setup.md."
        case .apiError(let status):
            return "[tts_api_error] HTTP \(status)"
        case .transport(let message):
            return "[tts_error] \(message)"
        case .emptyText:
            return "text is required"
        }
    }
}

/// One-call protocol so the synthesizer is injectable for tests.
public protocol MultimodalTTSSynthesizing: Sendable {
    /// Synthesize `text` to audio bytes via OpenAI TTS. Returns the raw audio
    /// `Data` (mp3/etc per `format`) on success, throws `MultimodalTTSError`
    /// otherwise.
    func synthesize(text: String, voice: String, format: String) async throws -> Data
}

/// SwiftNative OpenAI TTS client. Calls https://api.openai.com/v1/audio/speech
/// directly via URLSession, resolving the platform key with
/// `LLMCredentialResolver`. Byte-for-byte request parity with the daemon's
/// `_VisionClient.tts`.
public final class SwiftOpenAITTSClient: MultimodalTTSSynthesizing {
    /// Matches the retired daemon `OPENAI_TTS_URL`.
    public static let ttsURL = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// Matches the daemon's `model: "tts-1"`.
    public static let model = "tts-1"
    /// Matches the daemon's User-Agent.
    public static let userAgent = "NativeAgent/0.2.0"
    /// Matches the daemon's 4096-char input cap.
    public static let maxInputChars = 4096
    /// Matches the daemon's 60s urlopen timeout.
    public static let timeoutSeconds: TimeInterval = 60

    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol

    public init(
        session: URLSession = .shared,
        endpoint: URL = SwiftOpenAITTSClient.ttsURL,
        apiKeyOverride: String? = nil,
        dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        self.persistence = persistence
    }

    /// Reproduces the daemon's `_multimodal_policy_check("tts_openai")`
    ///. Reads `<dataRoot>/trust/policy.json` ->
    /// `multimodalPolicy.tts_openai`, defaulting to FALSE (deny) when the file
    /// is missing, the key is absent, or the value is non-bool — EXACTLY the
    /// daemon's `defaults["tts_openai"] = False` semantics. This is the trust
    /// gate the daemon runs BEFORE any TTS work; the native path must enforce it
    /// too, or flipping `.multimodalTTS` ON would let a user whose Trust Center
    /// has NOT enabled tts_openai (the default) bypass the gate. Path convention
    /// pinned at the retired daemon `trust_path = root / "trust" / "policy.json"`.
    ///
    /// FAIL-CLOSED on malformed values: the daemon's Python `if not allowed`
    /// truthiness would *accept* a malformed truthy value (the string "false",
    /// the int 1, a non-empty list) for `tts_openai`; this Swift gate requires a
    /// real JSON bool and DENIES anything else. That is intentionally STRICTER
    /// and safer for a sensitive-capability trust gate — fail-closed is the
    /// correct bias, and the Trust Center only ever writes a real bool, so no
    /// well-formed policy differs. (gpt-5.5 review NIT, wave 35 W18.)
    private func ttsOpenAIAllowed() async -> Bool {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let policy = await persistence.readJSON(path, defaultValue: .object([:]))
        guard case let .object(root) = policy,
              case let .object(mm)? = root["multimodalPolicy"],
              case let .bool(allowed)? = mm["tts_openai"] else {
            return false
        }
        return allowed
    }

    public func synthesize(text: String, voice: String, format: String) async throws -> Data {
        // Daemon runs _multimodal_policy_check("tts_openai") FIRST
        // — before empty-text/key/network. Default OFF.
        guard await ttsOpenAIAllowed() else { throw MultimodalTTSError.trustDenied }

        // Daemon: handler returns {"ok": false, "error": "text is required"} for
        // empty text BEFORE calling _vision_client.tts.
        if text.isEmpty { throw MultimodalTTSError.emptyText }

        // Same key precedence as the daemon's _get_token: env OPENAI_API_KEY,
        // then <dataRoot>/providers/openai.json `api_key`, then (OpenAI only)
        // <dataRoot>/codex_home/auth.json. (apiKeyOverride is for tests.)
        //
        // REPO_PATH parity (wave 36 W08 / §6.138): resolve against the SAME
        // `dataRoot` the trust gate above already uses
        // (`PersistenceCore.defaultDataRoot()`), NOT the CWD-relative default
        // overload. An installed `.app` bundle runs with CWD `/`, so the
        // CWD-relative resolver would look in `/data/providers/openai.json`
        // (nonexistent) and return notConfigured even though the key is sitting
        // in the stamped/AppSupport data root. The daemon's `_VisionClient` is
        // constructed with `provider_config_dir=self.root / "providers"` and
        // `codex_home=self.root / "codex_home"`, so
        // resolving against `dataRoot` is exact parity for installed builds.
        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: "OPENAI_API_KEY",
                    providerConfigFile: "openai.json",
                    dataRoot: dataRoot),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MultimodalTTSError.notConfigured
        }

        // Mirror the daemon's text[:4096] input truncation. Python's `str`
        // slicing is by CODE POINT (Unicode scalar), NOT by grapheme cluster, so
        // we truncate `unicodeScalars` — `String.prefix(_:)` would slice by
        // `Character` (grapheme) and drift for combining marks / emoji ZWJ
        // sequences. `.prefix` on a scalar view can split a grapheme; that
        // matches Python exactly (Python would split there too).
        let scalars = text.unicodeScalars
        let truncated: String
        if scalars.count > SwiftOpenAITTSClient.maxInputChars {
            truncated = String(String.UnicodeScalarView(scalars.prefix(SwiftOpenAITTSClient.maxInputChars)))
        } else {
            truncated = text
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = SwiftOpenAITTSClient.timeoutSeconds
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SwiftOpenAITTSClient.userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": SwiftOpenAITTSClient.model,
            "input": truncated,
            "voice": voice,
            "response_format": format,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Propagate cancellation cleanly (same convention as the ProviderRouting adapters).
            if error is CancellationError { throw CancellationError() }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw MultimodalTTSError.transport(message: nsError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MultimodalTTSError.transport(message: "non-HTTP response")
        }
        if http.statusCode == 401 {
            throw MultimodalTTSError.authRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MultimodalTTSError.apiError(status: http.statusCode)
        }
        return data
    }
}
