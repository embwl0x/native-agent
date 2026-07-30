import Foundation
import PersistenceCore

/// Fail-loud errors for the Browser shared-motor projection. The projection
/// reads only the canonical `runs.json`; derived receipts are deliberately not
/// a recovery source because an older receipt must never manufacture a terminal
/// outcome over a newer owner row.
public enum BrowserMotorReadModelError: Error, Sendable, Equatable {
    case invalidRunsDocument
    case invalidMatchingRun
    case duplicateActionIdentity
    case invalidStatusToken
    case invalidTimestamp
    case invalidDeadline
}

extension SwiftNativeBrowserClient: MotorActionReadModelProviding {
    /// Read-only, payload-free projection over one canonical Browser run.
    ///
    /// Browser remains the sole owner of navigation, approval, cancellation,
    /// and persistence. This adapter performs no write and exposes no URL,
    /// domain, capture path, approval payload, or receipt body.
    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        let runID = actionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runID.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: runsPath.path) else { return nil }

        let raw: JSONValue
        do {
            raw = try JSONValue.parse(Data(contentsOf: runsPath))
        } catch {
            throw BrowserMotorReadModelError.invalidRunsDocument
        }
        guard case .array(let rows) = raw else {
            throw BrowserMotorReadModelError.invalidRunsDocument
        }

        var matching: [String: JSONValue]?
        for row in rows {
            guard case .object(let object) = row else { continue }
            guard case .string(let candidateID)? = object["id"], candidateID == runID else {
                continue
            }
            guard matching == nil else {
                throw BrowserMotorReadModelError.duplicateActionIdentity
            }
            matching = object
        }
        guard let run = matching else { return nil }
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
                // Older/manual rows can say succeeded without the navigation
                // observation. Preserve terminality but do not invent proof.
                verification = .unverified
                expectedEvidence = "browser_navigation_receipt"
            }
            isCancellable = false
        case "failed":
            phase = .failed
            verification = .failed
            expectedEvidence = nil
            isCancellable = false
        case "canceled", "cancelled", "denied":
            phase = .cancelled
            verification = .notRequired
            expectedEvidence = nil
            isCancellable = false
        case "dry_run":
            // Browser's canonical cancel owner deliberately accepts dry-run
            // rows. Do not manufacture terminality merely because a simulation
            // receipt was emitted; the owner still exposes a real transition.
            phase = .ready
            verification = .notRequired
            expectedEvidence = "browser_run_cancellation"
            isCancellable = true
        default:
            phase = .unknown
            verification = .unknown
            expectedEvidence = "domain_recovery"
            isCancellable = false
        }

        let opaqueID = CausalTransitionEvidence.opaqueIdentity(runID)
        let deadline: MotorActionDeadlineReadModel?
        if let raw = run["deadlineSeconds"] {
            guard normalized == "running", case .int(let seconds) = raw,
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

    /// Returns only timestamps whose meaning is exact for the current owner
    /// state. In particular, `createdAt` is not mislabeled as a terminal update
    /// for succeeded/failed legacy rows that lack a completion timestamp.
    private func canonicalMotorTimestamp(run: [String: JSONValue], status: String) throws -> String? {
        func firstValidTimestamp(_ keys: [String]) throws -> String? {
            for key in keys {
                guard let raw = run[key] else { continue }
                guard case .string(let value) = raw,
                      Self.isBoundedISOTimestamp(value) else {
                    throw BrowserMotorReadModelError.invalidTimestamp
                }
                return value
            }
            return nil
        }
        switch status {
        case "canceled", "cancelled":
            return try firstValidTimestamp(["canceledAt", "updatedAt"])
        case "denied":
            return try firstValidTimestamp(["deniedAt", "updatedAt"])
        case "succeeded", "failed":
            return try firstValidTimestamp(["completedAt", "updatedAt"])
        default:
            return try firstValidTimestamp(["updatedAt", "createdAt"])
        }
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

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}
