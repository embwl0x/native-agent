import Foundation
import NativeAgentCTestSupport

public struct NativeAgentFlockChild: Sendable {
    public let pid: pid_t

    public func wait(timeout: TimeInterval) -> Int32? {
        var status: Int32 = -1
        let exited = na_wait_pid(pid, timeout, &status)
        return exited == 1 ? status : nil
    }

    public func terminate() {
        na_terminate_pid(pid)
    }

    public static func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func hold(
        lockPath: String,
        acquiredMarker: URL,
        releasedMarker: URL? = nil,
        releaseRequest: URL? = nil,
        holdSeconds: TimeInterval = 0
    ) throws -> NativeAgentFlockChild {
        var pid: pid_t = 0
        let released = releasedMarker?.path ?? ""
        let release = releaseRequest?.path ?? ""
        let rc = lockPath.withCString { lockC in
            acquiredMarker.path.withCString { acquiredC in
                released.withCString { releasedC in
                    release.withCString { releaseC in
                        na_spawn_flock_holder(lockC, acquiredC, releasedC, releaseC, holdSeconds, &pid)
                    }
                }
            }
        }
        if rc != 0 {
            throw NSError(
                domain: "NativeAgentFlockChild",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "failed to spawn flock holder: \(rc)"]
            )
        }
        return NativeAgentFlockChild(pid: pid)
    }

    public static func appendAfterHold(
        lockPath: String,
        target: URL,
        acquiredMarker: URL,
        line: String,
        holdSeconds: TimeInterval
    ) throws -> NativeAgentFlockChild {
        var pid: pid_t = 0
        let rc = lockPath.withCString { lockC in
            target.path.withCString { targetC in
                acquiredMarker.path.withCString { acquiredC in
                    line.withCString { lineC in
                        na_spawn_locked_append_after_hold(lockC, targetC, acquiredC, lineC, holdSeconds, &pid)
                    }
                }
            }
        }
        if rc != 0 {
            throw NSError(
                domain: "NativeAgentFlockChild",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "failed to spawn append helper: \(rc)"]
            )
        }
        return NativeAgentFlockChild(pid: pid)
    }

    public static func remProposalAppender(
        target: URL,
        count: Int
    ) throws -> NativeAgentFlockChild {
        var pid: pid_t = 0
        let rc = target.path.withCString { targetC in
            na_spawn_rem_proposal_appender(targetC, Int32(count), &pid)
        }
        if rc != 0 {
            throw NSError(
                domain: "NativeAgentFlockChild",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "failed to spawn proposal appender: \(rc)"]
            )
        }
        return NativeAgentFlockChild(pid: pid)
    }

    public static func mcpConsentWriter(
        ledger: URL,
        ready: URL,
        ack: URL,
        count: Int
    ) throws -> NativeAgentFlockChild {
        var pid: pid_t = 0
        let rc = ledger.path.withCString { ledgerC in
            ready.path.withCString { readyC in
                ack.path.withCString { ackC in
                    na_spawn_mcp_consent_writer(ledgerC, readyC, ackC, Int32(count), &pid)
                }
            }
        }
        if rc != 0 {
            throw NSError(
                domain: "NativeAgentFlockChild",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "failed to spawn MCP consent writer: \(rc)"]
            )
        }
        return NativeAgentFlockChild(pid: pid)
    }
}
