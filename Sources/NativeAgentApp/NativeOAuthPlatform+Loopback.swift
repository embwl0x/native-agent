import Foundation
import AppKit
import Network
import ProviderRouting

extension NativeOAuthPlatform {
    private static let loopbackMaxRequestBytes = 64 * 1024

    // MARK: - Loopback listener

    /// Bind a one-shot loopback HTTP listener, open the auth URL in the browser
    /// once the listener is ready, and return the full callback URL when the
    /// browser is redirected to a valid `/auth/callback?code|error` target
    /// carrying the exact state issued for this attempt.
    static func runLoopbackAuthSession(authURL: URL, port: UInt16, expectedState: String) async throws -> URL {
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
                    connection.start(queue: NativeOAuthPlatform.loopbackQueue)
                    NativeOAuthPlatform.receiveLoopbackRequest(connection, buffer: Data(), port: port, expectedState: expectedState, gate: gate)
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
                listener.start(queue: NativeOAuthPlatform.loopbackQueue)

                // Bounded wait so a never-completed sign-in can't hang forever.
                NativeOAuthPlatform.loopbackQueue.asyncAfter(deadline: .now() + 300) {
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
    /// first line. A valid `/auth/callback` with code|error and the expected
    /// state resolves the gate; a stray or unauthenticated request gets a 404
    /// so the real callback on a later connection still wins.
    private static func receiveLoopbackRequest(_ connection: NWConnection, buffer: Data, port: UInt16, expectedState: String, gate: LoopbackGate) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var acc = buffer
            if let data = data { acc.append(data) }

            if acc.count > loopbackMaxRequestBytes {
                respondNotFound(connection)
                return
            }

            if let line = firstRequestLine(acc) {
                if let target = NativeOAuthFlow.callbackTarget(from: line),
                   let url = URL(string: "http://localhost:\(port)\(target)"),
                   NativeOAuthFlow.callbackHasResult(url),
                   OAuthLoopbackCallbackPolicy.callbackMatchesState(url, expectedState: expectedState) {
                    respondSuccess(connection, message: callbackPageMessage(url))
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
            NativeOAuthPlatform.receiveLoopbackRequest(connection, buffer: acc, port: port, expectedState: expectedState, gate: gate)
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

    /// The browser tab's one line once the callback lands. The token exchange
    /// hasn't run yet, so the tab claims nothing; the app comes forward with
    /// the real result (OAuthSignInButton.runFlow).
    static func callbackPageMessage(_ url: URL) -> String {
        let declined = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "error" } == true
        return declined
            ? "Sign-in didn't finish — return to NativeAgent to try again."
            : "Finishing sign-in — return to NativeAgent."
    }

    private static func respondSuccess(_ connection: NWConnection, message: String) {
        let bodyHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>NativeAgent</title>
        <style>body{font:15px -apple-system,Helvetica,Arial;background:#111;color:#eee;
        display:flex;height:100vh;align-items:center;justify-content:center;margin:0}
        .c{text-align:center;max-width:420px;padding:24px}</style></head>
        <body><div class="c"><h2>\(message)</h2></div></body></html>
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
