import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `Browser+MotorReadModel.swift` | `SwiftNativeBrowserClient.motorActionReadModel`: canonical payload-free projection |

/// Only canonical runs can establish outcome; an older derived receipt cannot override a newer owner row.
public enum BrowserMotorReadModelError: Error, Sendable, Equatable {
    case invalidRunsDocument
    case invalidMatchingRun
    case duplicateActionIdentity
    case invalidStatusToken
    case invalidTimestamp
    case invalidDeadline
}

extension SwiftNativeBrowserClient: MotorActionReadModelProviding {
    /// Browser retains effect authority; this read-only projection exposes no URL, capture or approval payload.
    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        let runID = actionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runID.isEmpty else { return nil }
        let rows: [JSONValue]
        do {
            rows = try await Self.readCanonicalRuns(at: runsPath)
        } catch {
            throw BrowserMotorReadModelError.invalidRunsDocument
        }

        var matching: [String: JSONValue]?
        for row in rows {
            guard case .object(let object) = row else { continue }
            guard case .string(let candidateID)? = object["id"], candidateID == runID else {
                continue
            }
            if object["status"] == .string("unavailable") {
                throw PersistenceCoreError.ioFailure(object["error"]?.stringValue ?? "Browser run \(runID) unavailable")
            }
            guard matching == nil else {
                throw BrowserMotorReadModelError.duplicateActionIdentity
            }
            matching = object
        }
        guard let run = matching else {
            try Self.requireIdentifiableRuns(rows)
            return nil
        }
        guard case .string(let persistedStatus)? = run["status"] else {
            throw BrowserMotorReadModelError.invalidMatchingRun
        }

        guard Self.isBoundedMotorToken(persistedStatus) else {
            throw BrowserMotorReadModelError.invalidStatusToken
        }
        let normalized = persistedStatus

        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let expectedEvidence: String?
        let isCancellable: Bool
        switch normalized {
        case "running":
            phase = .running
            verification = .pending
            expectedEvidence = "browser_navigation_terminal"
            isCancellable = true
        case "waiting_approval":
            phase = .awaitingApproval
            verification = .notStarted
            expectedEvidence = "approval_resolution"
            isCancellable = true
        case "succeeded":
            phase = .succeeded
            if case .bool(true)? = run["opened"] {
                // `opened` is committed only after WKWebView navigation returns.
                verification = .satisfied
                expectedEvidence = nil
            } else {
                // A page effect can be terminal without proving navigation.
                verification = .unverified
                expectedEvidence = "browser_navigation_receipt"
            }
            isCancellable = false
        case "failed":
            phase = .failed
            verification = .failed
            expectedEvidence = nil
            isCancellable = false
        case "canceled", "denied":
            phase = .cancelled
            verification = .notRequired
            expectedEvidence = nil
            isCancellable = false
        default:
            throw BrowserMotorReadModelError.invalidStatusToken
        }

        let opaqueID = CausalTransitionEvidence.opaqueIdentity(runID)
        let deadline: MotorActionDeadlineReadModel?
        if normalized == "running", let raw = run["deadlineSeconds"] {
            guard case .int(let seconds) = raw,
                  seconds > 0, seconds <= 86_400 else {
                throw BrowserMotorReadModelError.invalidDeadline
            }
            deadline = MotorActionDeadlineReadModel(
                scope: .operation,
                timeoutSeconds: Int(seconds)
            )
        } else {
            deadline = nil
        }
        return MotorActionReadModel(
            domain: "browser",
            actionIdentity: opaqueID,
            phase: phase,
            domainState: persistedStatus,
            verification: verification,
            expectedNextEvidence: expectedEvidence,
            updatedAt: try canonicalMotorTimestamp(run: run, status: normalized),
            cancellationIdentity: isCancellable ? opaqueID : nil,
            deadline: deadline
        )
    }

    /// Require the current state's writer-owned timestamp; missing evidence cannot supply one.
    private func canonicalMotorTimestamp(run: [String: JSONValue], status: String) throws -> String {
        let key: String
        switch status {
        case "canceled":
            key = "canceledAt"
        case "denied":
            key = "deniedAt"
        case "succeeded", "failed":
            key = "completedAt"
        default:
            key = "updatedAt"
        }
        guard let value = run[key]?.stringValue, Self.isBoundedISOTimestamp(value) else {
            throw BrowserMotorReadModelError.invalidTimestamp
        }
        return value
    }

    private static func isBoundedMotorToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95 || byte == 45
        }
    }

    private static func isBoundedISOTimestamp(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        guard value.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57)
                || byte == 84  // T
                || byte == 90  // Z
                || byte == 43  // +
                || byte == 45  // -
                || byte == 58  // :
                || byte == 46  // .
        }) else { return false }

        return NativeTimestampFormat.parseISO8601FractionalFirst(value) != nil
    }
}
