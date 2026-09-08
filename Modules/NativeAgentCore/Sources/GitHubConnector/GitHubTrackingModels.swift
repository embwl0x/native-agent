import Foundation
import NativeAgentCore
import PersistenceCore

struct TrackedRepository: Sendable, Equatable {
    let fullName: String
    let name: String
    let htmlURL: String
    let defaultBranch: String?

    var json: JSONValue {
        var out: [String: JSONValue] = ["fullName": .string(fullName), "name": .string(name), "htmlURL": .string(htmlURL)]
        if let defaultBranch { out["defaultBranch"] = .string(defaultBranch) }
        return .object(out)
    }

    static func fromJSON(_ value: JSONValue) -> TrackedRepository? {
        guard case .object(let o) = value,
              case .string(let fullName)? = o["fullName"],
              case .string(let name)? = o["name"],
              case .string(let htmlURL)? = o["htmlURL"] else { return nil }
        let defaultBranch: String? = { if case .string(let s)? = o["defaultBranch"] { return s }; return nil }()
        return TrackedRepository(fullName: fullName, name: name, htmlURL: htmlURL, defaultBranch: defaultBranch)
    }
}

enum TrackingMode: String, Sendable, Equatable {
    case repository
    case contributions

    init(input: String) throws {
        guard let mode = TrackingMode(rawValue: input.lowercased()) else {
            throw GitHubConnectorError.invalidInput("GitHub tracking mode must be 'contributions' or 'repository'.")
        }
        self = mode
    }
}

struct TrackingConfig: Sendable, Equatable {
    let version: Int
    let project: String
    let mode: TrackingMode
    let contributorLogin: String?
    let discoveryQuery: String?
    let repositories: [TrackedRepository]
    let refreshIntervalMinutes: Int
    let staleAfterHours: Int
    let updatedAt: String

    var json: JSONValue {
        var out: [String: JSONValue] = [
            "version": .int(Int64(version)), "project": .string(project),
            "mode": .string(mode.rawValue),
            "repositories": .array(repositories.map(\.json)),
            "refreshIntervalMinutes": .int(Int64(refreshIntervalMinutes)),
            "staleAfterHours": .int(Int64(staleAfterHours)), "updatedAt": .string(updatedAt),
        ]
        if let contributorLogin { out["contributorLogin"] = .string(contributorLogin) }
        if let discoveryQuery { out["discoveryQuery"] = .string(discoveryQuery) }
        return .object(out)
    }

    static func fromJSON(_ value: JSONValue) -> TrackingConfig? {
        guard case .object(let o) = value,
              case .string(let project)? = o["project"],
              case .string(let rawMode)? = o["mode"],
              let mode = TrackingMode(rawValue: rawMode),
              case .array(let rawRepos)? = o["repositories"] else { return nil }
        let intValue: (String, Int) -> Int = { key, fallback in
            if case .int(let value)? = o[key] { return Int(value) }
            return fallback
        }
        let query: String? = { if case .string(let s)? = o["discoveryQuery"] { return s }; return nil }()
        let contributor: String? = { if case .string(let s)? = o["contributorLogin"] { return s }; return nil }()
        let updated: String = { if case .string(let s)? = o["updatedAt"] { return s }; return "" }()
        let repos = rawRepos.compactMap(TrackedRepository.fromJSON)
        guard !repos.isEmpty else { return nil }
        if mode == .contributions, contributor?.isEmpty != false { return nil }
        return TrackingConfig(
            version: intValue("version", 2),
            project: project,
            mode: mode,
            contributorLogin: contributor,
            discoveryQuery: query,
            repositories: repos,
            refreshIntervalMinutes: intValue("refreshIntervalMinutes", 5),
            staleAfterHours: intValue("staleAfterHours", 72),
            updatedAt: updated
        )
    }
}

struct TrackingEntity: Sendable, Equatable {
    let key: String
    let repo: String
    let number: Int
    let kind: String
    let title: String
    let state: String
    let updatedAt: String
    let url: String
    let author: String?
    let reviewState: String?
    let checks: String?
    let mergeable: String?
    let needsUser: Bool
    let blocked: Bool
    let stale: Bool
    let commandObservation: GitHubCommandObservation?
    // When this entity's detail calls last actually ran (ISO). Local
    // bookkeeping for the delta-refresh carry bound — deliberately excluded
    // from `signature` (it is not remote state) and optional so pre-delta
    // snapshots decode as nil, which fails open into a full detail fetch.
    var detailFetchedAt: String? = nil

    var signature: String {
        // "needs_user" is an internal fingerprint token (never persisted —
        // signature recomputes from fields on both sides of every compare),
        // renamed from a personal name for public-identity neutrality
        // (release-polish item 9, last residue).
        [state, updatedAt, reviewState ?? "", checks ?? "", mergeable ?? "", needsUser ? "needs_user" : "", blocked ? "blocked" : "", stale ? "stale" : ""].joined(separator: "|")
    }

    /// Fingerprint for the CADENCE LEARNER, which counts "this differs from last
    /// time" as evidence that the ref moved upstream.
    ///
    /// NOT `signature`. `signature` folds in `stale`, and `stale` is
    /// `isStale(updatedAt, hours:)` — a comparison against the LOCAL CLOCK. A PR
    /// nobody has touched flips it false→true the moment it crosses the staleness
    /// window, so `signature` would report a change on a ref where upstream did
    /// nothing at all: a fabricated sample in the EWMA, and a third of the
    /// evidence the learner needs before it trusts an interval. Everything below
    /// is a value GitHub reported. `needsUser`/`blocked` are dropped for the same
    /// reason they'd be redundant — they derive from `reviewState`/`checks`,
    /// which are already here.
    var observationFingerprint: String {
        [state, updatedAt, reviewState ?? "", checks ?? "", mergeable ?? ""].joined(separator: "|")
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "key": .string(key), "repository": .string(repo), "number": .int(Int64(number)),
            "kind": .string(kind), "title": .string(title), "state": .string(state),
            "updatedAt": .string(updatedAt), "url": .string(url),
            "needsUser": .bool(needsUser), "blocked": .bool(blocked), "stale": .bool(stale),
            "signature": .string(signature),
        ]
        if let author { o["author"] = .string(author) }
        if let reviewState { o["reviewState"] = .string(reviewState) }
        if let checks { o["checks"] = .string(checks) }
        if let mergeable { o["mergeable"] = .string(mergeable) }
        if let detailFetchedAt { o["detailFetchedAt"] = .string(detailFetchedAt) }
        if let commandObservation,
           let data = try? JSONEncoder().encode(commandObservation),
           let value = try? JSONValue.parse(data) {
            o["commandObservation"] = value
        }
        return .object(o)
    }

    static func fromJSON(_ value: JSONValue) -> TrackingEntity? {
        guard case .object(let o) = value,
              case .string(let key)? = o["key"], case .string(let repo)? = o["repository"],
              case .int(let number)? = o["number"], case .string(let kind)? = o["kind"],
              case .string(let title)? = o["title"], case .string(let state)? = o["state"],
              case .string(let updatedAt)? = o["updatedAt"], case .string(let url)? = o["url"] else { return nil }
        func str(_ key: String) -> String? { if case .string(let s)? = o[key] { return s }; return nil }
        func flag(_ key: String) -> Bool { if case .bool(let b)? = o[key] { return b }; return false }
        let commandObservation: GitHubCommandObservation? = {
            guard let raw = o["commandObservation"],
                  let data = try? raw.serializedData(pretty: false) else { return nil }
            return try? JSONDecoder().decode(GitHubCommandObservation.self, from: data)
        }()
        return TrackingEntity(key: key, repo: repo, number: Int(number), kind: kind, title: title, state: state, updatedAt: updatedAt, url: url, author: str("author"), reviewState: str("reviewState"), checks: str("checks"), mergeable: str("mergeable"), needsUser: flag("needsUser"), blocked: flag("blocked"), stale: flag("stale"), commandObservation: commandObservation, detailFetchedAt: str("detailFetchedAt"))
    }
}

struct TrackingSnapshot: Sendable, Equatable {
    let project: String
    let mode: TrackingMode?
    let contributorLogin: String?
    let refreshedAt: String
    let entities: [TrackingEntity]
    let changedKeys: [String]
    let newKeys: [String]
    let deskCreated: Int
    let deskUpdated: Int
    let deskArchived: Int

    var json: JSONValue {
        var out: [String: JSONValue] = [
        "version": .int(2), "project": .string(project), "refreshedAt": .string(refreshedAt),
        "entities": .array(entities.map(\.json)), "changedKeys": .array(changedKeys.map(JSONValue.string)),
        "newKeys": .array(newKeys.map(JSONValue.string)), "deskCreated": .int(Int64(deskCreated)),
        "deskUpdated": .int(Int64(deskUpdated)), "deskArchived": .int(Int64(deskArchived)),
        ]
        if let mode { out["mode"] = .string(mode.rawValue) }
        if let contributorLogin { out["contributorLogin"] = .string(contributorLogin) }
        return .object(out)
    }

    static func fromJSON(_ value: JSONValue) -> TrackingSnapshot? {
        guard case .object(let o) = value, case .string(let project)? = o["project"],
              case .string(let refreshedAt)? = o["refreshedAt"], case .array(let rows)? = o["entities"] else { return nil }
        func strings(_ key: String) -> [String] { if case .array(let a)? = o[key] { return a.compactMap { if case .string(let s) = $0 { return s }; return nil } }; return [] }
        func int(_ key: String) -> Int { if case .int(let i)? = o[key] { return Int(i) }; return 0 }
        let mode: TrackingMode? = { if case .string(let s)? = o["mode"] { return TrackingMode(rawValue: s) }; return nil }()
        let contributor: String? = { if case .string(let s)? = o["contributorLogin"] { return s }; return nil }()
        return TrackingSnapshot(
            project: project,
            mode: mode,
            contributorLogin: contributor,
            refreshedAt: refreshedAt,
            entities: rows.compactMap(TrackingEntity.fromJSON),
            changedKeys: strings("changedKeys"),
            newKeys: strings("newKeys"),
            deskCreated: int("deskCreated"),
            deskUpdated: int("deskUpdated"),
            deskArchived: int("deskArchived")
        )
    }
}
