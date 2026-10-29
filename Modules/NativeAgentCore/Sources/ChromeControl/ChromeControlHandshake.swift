import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `ChromeControlHandshake.swift` | `ChromeControlHandshake`: private per-listener token, registered relay executable/signer and browser-parent authentication, bounded hello framing and listener-generation acknowledgement |

/// Only an authenticated registered relay may replace the live channel.
enum ChromeControlHandshake {
    /// One wall-clock deadline bounds the entire hello, across every read.
    static let helloSeconds = 5

    static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%016lx", UInt64.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Kernel peer identity proves the registered relay; the token is a second factor.
    static func peerProcessID(descriptor: Int32) -> pid_t? {
        var pid: pid_t = -1
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              pid > 0 else { return nil }
        return pid
    }

    /// The whole proof for one accepted connection, run on the accept task.
    ///
    /// `expecting` contains this app's symlink-resolved relay executable paths.
    /// Registration administration never relaxes the connection identity proof.
    ///
    /// Order matters. The peer's executable is settled first: it costs one
    /// getsockopt and needs no cooperation from the caller, so an impostor
    /// never gets to hold the accept task for the hello's whole budget.
    static func validateConnection(
        descriptor: Int32, expecting: Set<String>, token: String
    ) throws {
        guard !expecting.isEmpty else {
            throw ChromeControlRuntimeError.handshakeRejected("the app has no authenticated relay identity.")
        }
        guard let pid = peerProcessID(descriptor: descriptor),
              let peer = ChromeHostIdentity.executablePath(ofProcess: pid) else {
            nativeLog("[NativeAgent] Chrome control refused a connection with no readable peer pid.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay's peer process identity could not be read.")
        }
        let resolved = URL(fileURLWithPath: peer).resolvingSymlinksInPath().path
        guard expecting.contains(resolved) else {
            nativeLog("[NativeAgent] Chrome control refused a connection from an unexpected peer executable.")
            throw ChromeControlRuntimeError.handshakeRejected("the peer executable is not the registered relay.")
        }
        // The running relay must match this app's signer, even after its parent exits.
        guard ChromeSocketIdentity.peerIsTrusted(
            descriptor: descriptor, identifiers: ["NativeAgentChromeRelay"]
        ) else {
            nativeLog("[NativeAgent] Chrome control refused a relay with an unexpected code identity.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay's code identity does not match NativeAgent.")
        }
        guard let parent = ChromeHostIdentity.parentProcessID(of: pid) else {
            nativeLog("[NativeAgent] Chrome control refused a relay whose parent could not be read.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay's parent process could not be read.")
        }
        // Both app and relay require a browser-launched native messaging host.
        let parentIsBrowser = ChromeHostIdentity.isBrowserProcess(parent)
        // A relay reparented to launchd must prove its browser parent at launch.
        guard parentIsBrowser || parent == 1 else {
            nativeLog("[NativeAgent] Chrome control refused a relay whose parent is not a browser.")
            throw ChromeControlRuntimeError.handshakeRejected("the relay was not launched by a signed browser.")
        }
        let hello = try readHello(descriptor: descriptor, token: token)
        if parentIsBrowser { return }
        // Only the registered, signer-validated relay may attest its launch parent.
        guard helloCarriesParentEvidence(hello) else {
            nativeLog("[NativeAgent] Chrome control refused a reparented relay with no launch-time parent evidence.")
            throw ChromeControlRuntimeError.handshakeRejected("the reparented relay has no valid launch-time browser evidence.")
        }
    }

    private static func helloCarriesParentEvidence(_ hello: [String: JSONValue]) -> Bool {
        var processID: Int?
        if case .int(let value)? = hello[ChromeHostIdentity.ParentEvidence.processIDField] {
            processID = Int(value)
        }
        var validatedAt: Double?
        switch hello[ChromeHostIdentity.ParentEvidence.validatedAtField] {
        case .double(let value): validatedAt = value
        case .int(let value): validatedAt = Double(value)
        default: break
        }
        var bundleIdentifier: String?
        if case .string(let value)? = hello[ChromeHostIdentity.ParentEvidence.bundleIDField] {
            bundleIdentifier = value
        }
        return ChromeHostIdentity.ParentEvidence.isWellFormed(
            bundleIdentifier: bundleIdentifier, processID: processID, validatedAt: validatedAt
        )
    }

    /// Acknowledgement identifies the listener that accepted the authenticated peer.
    @discardableResult
    static func sendHelloAck(descriptor: Int32, generation: UInt64) -> Bool {
        do {
            let payload = try JSONSerialization.data(
                withJSONObject: ["version": 1, "type": "hello_ack", "generation": String(generation)],
                options: [.sortedKeys]
            )
            try NativeMessagingFramer().writeMessage(payload, toSocket: descriptor, timeout: TimeInterval(helloSeconds))
            return true
        } catch { return false }
    }

    /// The handshake owner retains the descriptor; the framer only borrows it.
    static func readHello(descriptor: Int32, token: String) throws -> [String: JSONValue] {
        let hello: Data
        do {
            guard let frame = try NativeMessagingFramer().readMessage(fromSocket: descriptor, timeout: TimeInterval(helloSeconds)) else {
                throw ChromeControlRuntimeError.handshakeRejected("the relay closed before sending its greeting.")
            }
            hello = frame
        } catch let error as ChromeControlRuntimeError { throw error }
        catch { throw ChromeControlRuntimeError.handshakeRejected("the relay greeting could not be read: \(error.localizedDescription)") }
        guard let value = try? JSONValue.parse(hello), case .object(let object) = value else {
            throw ChromeControlRuntimeError.handshakeRejected("the relay greeting is not a JSON object.")
        }
        guard case .int(1)? = object["version"],
              case .string("hello")? = object["type"]
        else { throw ChromeControlRuntimeError.handshakeRejected("the relay greeting has an unsupported protocol version or type.") }
        guard case .string(let presented)? = object["token"], !token.isEmpty, presented == token else {
            throw ChromeControlRuntimeError.handshakeRejected("the relay greeting does not carry this listener's credential.")
        }
        return object
    }
}
