import Foundation
import AppKit
import Network

// MARK: - Loopback OAuth (ChatGPT / OpenAI)
//
// OpenAI's ChatGPT sign-in client (`app_EMoamEEZ73f0CkXaXp7hrann`, the same
// public client the `codex` CLI uses) only allows a LOOPBACK redirect —
// `http://localhost:1455/auth/callback` — never a custom URL scheme. So the
// custom-scheme ASWebAuthenticationSession path that Anthropic/Grok use returns
// an OpenAI "unknown_error" for ChatGPT (redirect_uri not registered).
//
// This runs codex's flow natively, minus the codex binary: bind a one-shot
// local HTTP listener on 127.0.0.1:1455, open auth.openai.com in the default
// browser, catch the `GET /auth/callback?code=…&state=…` redirect, hand the
// browser a "you can close this" page, then PKCE-exchange the code exactly as
// the shared ProviderOAuthConfig.openai already does. Verified port/path/params
// against the shipped codex Rust binary (1455, /auth/callback, /success,
// id_token_add_organizations, codex_cli_simplified_flow) — 2026-07-05.
//
// Hardening (gpt-5.5 review 2026-07-05): per-connection buffering so a split
// request line can't hang; EXACT /auth/callback path match + require code/error
// before resolving (stray probes like /favicon.ico get a 404 and are ignored);
// open the browser only on listener .ready; fail loud on port-in-use; wire task
// cancellation to tear the listener down.

extension NativeOAuthFlow {

    /// Fixed loopback port OpenAI's ChatGPT client is registered against.
    static let openAILoopbackPort: UInt16 = 1455
    static let openAILoopbackPath = "/auth/callback"
    private static let loopbackMaxRequestBytes = 64 * 1024

    @MainActor
    static func startOpenAILoopbackFlow() async -> OAuthFlowResult {
        let config = ProviderOAuthConfig.openai
        let redirectURI = "http://localhost:\(openAILoopbackPort)\(openAILoopbackPath)"

        let pkce = PKCE.generate()
        let state = randomHex(16)
        let authURL = config.buildAuthURL(
            redirectURI: redirectURI,
            state: state,
            challenge: pkce.challenge
        )

        let callbackURL: URL
        do {
            callbackURL = try await runLoopbackAuthSession(
                authURL: authURL,
                port: openAILoopbackPort
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "ChatGPT sign-in failed: \(error.localizedDescription)")
        }

        let (code, returnedState, providerError) = parseCallback(callbackURL)
        if let providerError = providerError {
            return OAuthFlowResult(ok: false,
                error: "ChatGPT returned an error: \(providerError)")
        }
        guard let code = code, !code.isEmpty else {
            return OAuthFlowResult(ok: false,
                error: "ChatGPT did not return an authorization code.")
        }
        guard returnedState == state else {
            return OAuthFlowResult(ok: false,
                error: "OAuth state mismatch — possible CSRF; aborting.")
        }

        let tokens: [String: Any]
        do {
            tokens = try await config.exchangeCode(
                code: code,
                verifier: pkce.verifier,
                state: state,
                redirectURI: redirectURI
            )
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Token exchange failed: \(redact(error.localizedDescription))")
        }

        do {
            try config.persistTokens(tokens)
        } catch {
            return OAuthFlowResult(ok: false,
                error: "Could not write token file: \(error.localizedDescription)")
        }

        return OAuthFlowResult(ok: true, error: nil)
    }

    // MARK: - Loopback listener

    /// Bind a one-shot loopback HTTP listener, open the auth URL in the browser
    /// once the listener is ready, and return the full callback URL when the
    /// browser is redirected to a valid `/auth/callback?code|error` target.
    static func runLoopbackAuthSession(authURL: URL, port: UInt16) async throws -> URL {
        let params = NWParameters.tcp
        // Do NOT reuse the endpoint: a fixed-port bind must fail LOUD if :1455
        // is already held (e.g. a running codex), never silently share it.
        params.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "NativeOAuthFlow", code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Invalid loopback port \(port)."])
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw NSError(domain: "NativeOAuthFlow", code: -20, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't start the local sign-in listener on port \(port). "
                    + "Another app (or a running `codex`) may be using it. "
                    + "Underlying error: \(error.localizedDescription)"])
        }

        let gate = LoopbackGate(listener: listener)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                gate.attach(cont)

                listener.newConnectionHandler = { connection in
                    connection.start(queue: NativeOAuthFlow.loopbackQueue)
                    NativeOAuthFlow.receiveLoopbackRequest(connection, buffer: Data(), port: port, gate: gate)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        // Open the browser only once the socket is actually up.
                        Task { @MainActor in NSWorkspace.shared.open(authURL) }
                    case .failed(let err):
                        gate.finish(.failure(NSError(domain: "NativeOAuthFlow", code: -23,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Local sign-in listener failed: \(err.localizedDescription)"])))
                    default:
                        break
                    }
                }
                listener.start(queue: NativeOAuthFlow.loopbackQueue)

                // Bounded wait so a never-completed sign-in can't hang forever.
                NativeOAuthFlow.loopbackQueue.asyncAfter(deadline: .now() + 300) {
                    gate.finish(.failure(NSError(domain: "NativeOAuthFlow", code: -21,
                        userInfo: [NSLocalizedDescriptionKey:
                            "ChatGPT sign-in timed out. Start it again to retry."])))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    static let loopbackQueue = DispatchQueue(label: "com.nativeagent.oauth.loopback")

    /// Read the request, accumulating across TCP segments until we have a full
    /// first line. A valid `/auth/callback` with code|error resolves the gate;
    /// a stray probe (favicon, path without a result) gets a 404 and is ignored
    /// so the real callback on a later connection still wins.
    private static func receiveLoopbackRequest(_ connection: NWConnection, buffer: Data, port: UInt16, gate: LoopbackGate) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var acc = buffer
            if let data = data { acc.append(data) }

            if acc.count > loopbackMaxRequestBytes {
                respondNotFound(connection)
                return
            }

            if let line = firstRequestLine(acc) {
                if let target = callbackTarget(from: line),
                   let url = URL(string: "http://localhost:\(port)\(target)"),
                   callbackHasResult(url) {
                    respondSuccess(connection)
                    gate.finish(.success(url))
                    return
                }
                // Recognized a full request line but it isn't a valid callback —
                // a favicon/stray probe. Answer it, drop this connection, and
                // keep the listener alive for the real redirect.
                respondNotFound(connection)
                return
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }
            // First line not complete yet — keep reading with what we have.
            NativeOAuthFlow.receiveLoopbackRequest(connection, buffer: acc, port: port, gate: gate)
        }
    }

    /// The first HTTP request line (before CRLF), or nil if not yet received.
    private static func firstRequestLine(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            // Non-UTF8 prefix: only bail if we've clearly got a line terminator.
            return nil
        }
        guard let range = text.range(of: "\r\n") else { return nil }
        return String(text[text.startIndex..<range.lowerBound])
    }

    /// From `GET /auth/callback?code=…&state=… HTTP/1.1`, return the request
    /// target (path+query) ONLY when the path is EXACTLY `/auth/callback`.
    static func callbackTarget(from requestLine: String) -> String? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return nil }
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        guard path == openAILoopbackPath else { return nil }
        return target
    }

    /// True only when the callback carries an OAuth result (code or error) —
    /// so a bare `/auth/callback` probe can't resolve the flow prematurely.
    private static func callbackHasResult(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        let hasCode = items.contains { $0.name == "code" && !($0.value ?? "").isEmpty }
        let hasError = items.contains { $0.name == "error" && !($0.value ?? "").isEmpty }
        return hasCode || hasError
    }

    private static func respondSuccess(_ connection: NWConnection) {
        let bodyHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>NativeAgent</title>
        <style>body{font:15px -apple-system,Helvetica,Arial;background:#111;color:#eee;
        display:flex;height:100vh;align-items:center;justify-content:center;margin:0}
        .c{text-align:center;max-width:420px;padding:24px}</style></head>
        <body><div class="c"><h2>ChatGPT connected</h2>
        <p>You're signed in. You can close this tab and return to NativeAgent.</p>
        </div></body></html>
        """
        sendHTTP(connection, status: "200 OK", body: bodyHTML)
    }

    private static func respondNotFound(_ connection: NWConnection) {
        sendHTTP(connection, status: "404 Not Found", body: "Not found.")
    }

    private static func sendHTTP(_ connection: NWConnection, status: String, body: String) {
        let bytes = Array(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        var out = Array(header.utf8)
        out.append(contentsOf: bytes)
        connection.send(content: Data(out), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Resolves the loopback continuation exactly once and tears down the listener.
/// Handles the race where cancellation (onCancel) fires before the continuation
/// is attached: the result is held pending and delivered on attach.
final class LoopbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var pending: Result<URL, Error>?
    private var done = false
    private let listener: NWListener

    init(listener: NWListener) {
        self.listener = listener
    }

    func attach(_ cont: CheckedContinuation<URL, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        if let pending = pending {
            self.pending = nil
            done = true
            lock.unlock()
            listener.cancel()
            resume(cont, pending)
            return
        }
        continuation = cont
        lock.unlock()
    }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        if let cont = continuation {
            continuation = nil
            done = true
            lock.unlock()
            listener.cancel()
            resume(cont, result)
        } else {
            // Result arrived before the continuation was attached (e.g. cancel
            // racing startup). Hold it; attach() will deliver + cancel listener.
            pending = result
            lock.unlock()
        }
    }

    private func resume(_ cont: CheckedContinuation<URL, Error>, _ result: Result<URL, Error>) {
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
