import Foundation
import PersistenceCore
// Blueprint: | `MacMediaTarget.swift` | One read-only live Now Playing process recipe through ProcessExecution; successful no-player evidence returns nil, Stop throws CancellationError; typed launch, channel, timeout, exit, truncation and PID failures retain bounded process evidence in the same admission/execution refusal; no player launch or retained target state |

enum MacMediaTarget {
    struct Failure: Error, LocalizedError, Sendable {
        enum Kind: String, Sendable {
            case process, channels, timeout, exit, truncated, invalidPID, unsupported
        }
        let kind: Kind
        let cause: String
        var process: ProcessRunResult? = nil
        var channels: [String] = []
        var underlying: (any Error)? = nil
        var message: String { "Now Playing target discovery \(kind.rawValue): \(cause)" }
        var errorDescription: String? { message }

        var refusal: MacAppActRefusal {
            var evidence: [String: JSONValue] = ["kind": .string(kind.rawValue), "cause": .string(cause),
                "channels": .array(channels.map(JSONValue.string))]
            if let underlying {
                let native = underlying as NSError
                evidence["native_error"] = .object(["type": .string(String(reflecting: type(of: underlying))),
                    "domain": .string(native.domain), "code": .int(Int64(native.code)), "message": .string(native.localizedDescription)])
            }
            if let process {
                evidence["exit_code"] = .int(Int64(process.exitCode))
                evidence["timed_out"] = .bool(process.timedOut)
                evidence["stdout"] = .string(process.stdout)
                evidence["stderr"] = .string(process.stderr)
                evidence["stdout_truncated"] = .bool(process.stdoutTruncated)
                evidence["stderr_truncated"] = .bool(process.stderrTruncated)
            }
            return MacAppActRefusal(code: "media_target_discovery_\(kind.rawValue)",
                message: "\(message) No media key was sent. Use the named player's action or repair Now Playing discovery.", integration: nil,
                remedy: Repair.remedy(owner: "macOS Now Playing / MediaRemote", nextCall: nil, tap: "the player's controls",
                    instruction: "Use the named player's action; repair the reported discovery failure before trying a system media key again."),
                targetDiscovery: .object(evidence))
        }
    }

    // MediaRemote's read requires an Apple platform host on recent macOS.
    // This fixed recipe reads only the system player's process identity; no
    // caller-supplied code or app command enters the interpreter.
    static let query = #"""
    ObjC.import('Foundation');
    function run() {
        const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        if (!framework.load) throw Error('MediaRemote unavailable');
        const request = $.NSClassFromString('MRNowPlayingRequest');
        if (!request || request.isNil()) throw Error('Now Playing request unavailable');
        const path = request.localNowPlayingPlayerPath;
        if (!path || path.isNil()) return 'no_player';
        const client = path.client;
        if (!client || client.isNil()) return 'no_player';
        const pid = client.processIdentifier;
        if (pid === 0) return 'no_player';
        return String(pid);
    }
    """#

    static func currentPID() async throws -> Int32? {
        #if canImport(AppKit)
        do {
            try Task.checkCancellation()
            let result = try await ProcessExecution().run(
                executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-"],
                currentDirectory: nil, environment: nil, standardInput: Data(query.utf8),
                timeoutSeconds: 2, outputByteLimit: 4096, launchFailure: { $0 })
            try Task.checkCancellation()
            guard !result.timedOut else { throw Failure(kind: .timeout, cause: "The two-second process deadline expired; the player is unknown.", process: result) }
            guard result.exitCode == 0 else { throw Failure(kind: .exit, cause: "The Now Playing recipe exited with status \(result.exitCode): \(result.stderr)", process: result) }
            guard !result.stdoutTruncated, !result.stderrTruncated else { throw Failure(kind: .truncated, cause: "Discovery output exceeded its 4096-byte capture limit.", process: result) }
            let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer == "no_player" { return nil }
            guard let pid = Int32(answer), pid > 0 else {
                throw Failure(kind: .invalidPID, cause: "The recipe did not return a positive process identifier; the player is unknown.", process: result)
            }
            return pid
        } catch let failure as Failure { throw failure }
        catch is ProcessRunCancellation { throw CancellationError() }
        catch let error as ProcessRunIOFailure { throw Failure(kind: .channels, cause: error.localizedDescription, process: error.result, channels: error.channels) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure(kind: .process, cause: error.localizedDescription, underlying: error) }
        #else
        throw Failure(kind: .unsupported, cause: "Now Playing process discovery requires macOS.")
        #endif
    }
}
