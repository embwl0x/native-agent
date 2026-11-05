import Darwin
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `BackgroundWorkLease.swift` | `BackgroundWorkLease` actor; persisted window claims and release of the holder’s newest unused claim |

/// Durable window claims: reflection takes at most one background slot per Desk-day window. Only the holder’s newest unused claim may be released.
public actor BackgroundWorkLease {
    private let path: URL

    public init(dataRoot: URL) {
        self.path = dataRoot.appendingPathComponent("background_lease.json")
    }

    /// True iff this call is the first to claim `window`. Persists the claim under the file lock so concurrent callers can't both win.
    public func tryAcquire(holder: String, window: String) async -> Bool {
        let holder = holder.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = window.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !holder.isEmpty, !window.isEmpty else { return false }
        return (try? await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            var claims: [JSONValue] = []
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                let current = try JSONValue.parse(data)
                guard case .object(let obj) = current else {
                    throw NSError(domain: "BackgroundWorkLease", code: 1)
                }
                if case .array(let rows)? = obj["claims"] {
                    guard rows.allSatisfy({ row in
                        guard case .object(let claim) = row,
                              case .string(let claimedWindow)? = claim["window"],
                              !claimedWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return false
                        }
                        return true
                    }) else {
                        throw NSError(domain: "BackgroundWorkLease", code: 3)
                    }
                    claims = rows
                } else {
                    throw NSError(domain: "BackgroundWorkLease", code: 2)
                }
            }
            let alreadyClaimed = claims.contains { row in
                guard case .object(let claim) = row,
                      case .string(let claimedWindow)? = claim["window"] else { return false }
                return claimedWindow == window
            }
            if alreadyClaimed {
                return false
            }
            let stamp = NativeTimestampFormat.plainZulu(Date())
            let claim: JSONValue = .object([
                "window": .string(window),
                "holder": .string(holder),
                "acquiredAt": .string(stamp),
            ])
            claims.append(claim)
            claims = Array(claims.suffix(32))
            try await SwiftNativePersistenceCore.writeJSON(.object(["claims": .array(claims)]), to: path)
            guard Self.flushDirectory(path.deletingLastPathComponent()) else {
                throw NSError(domain: "BackgroundWorkLease", code: 4)
            }
            return true
        }) ?? false
    }

    /// Who claimed `window` and when; nil when no claim names it. An unreadable lease throws: it is never read as free or as held.
    public func claim(window: String) async throws -> (holder: String, acquiredAt: String)? {
        try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> (holder: String, acquiredAt: String)? in
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            guard case .object(let object) = try JSONValue.parse(Data(contentsOf: path)), case .array(let claims)? = object["claims"] else {
                throw NSError(domain: "BackgroundWorkLease", code: 2)
            }
            for case .object(let claim) in claims.reversed() where claim["window"] == .string(window) {
                guard case .string(let holder)? = claim["holder"], case .string(let acquiredAt)? = claim["acquiredAt"] else {
                    throw NSError(domain: "BackgroundWorkLease", code: 5)
                }
                return (holder, acquiredAt)
            }
            return nil
        }
    }

    /// Return only this holder's newest claim when admission failed before any provider/tool work. This is not a general release: a spent or older window
    /// remains immutable, and another holder's claim can never be removed.
    public func releaseUnused(holder: String, window: String) async -> Bool {
        (try? await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            guard FileManager.default.fileExists(atPath: path.path),
                  case .object(let object) = try JSONValue.parse(Data(contentsOf: path)),
                  case .array(var claims)? = object["claims"],
                  let last = claims.last,
                  case .object(let claim) = last,
                  case .string(let claimedWindow)? = claim["window"],
                  case .string(let claimedHolder)? = claim["holder"],
                  claimedWindow == window, claimedHolder == holder else { return false }
            claims.removeLast()
            try await SwiftNativePersistenceCore.writeJSON(.object(["claims": .array(claims)]), to: path)
            return Self.flushDirectory(path.deletingLastPathComponent())
        }) ?? false
    }

    /// Fsync the directory entry before provider work; a symlinked parent is refused.
    private static func flushDirectory(_ path: URL) -> Bool {
        let fd = Darwin.open(path.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return Darwin.fsync(fd) == 0
    }
}
