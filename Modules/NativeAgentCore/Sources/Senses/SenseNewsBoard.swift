import AuthoredCapabilities
import Foundation
import AppKit
import CryptoKit
import Darwin
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `SenseNewsBoard.swift` | Bounded deduplicated news; checked persistence precedes publication, and each new item is a world happening |
public actor SenseNewsBoard {
    public static let shared = SenseNewsBoard()
    public static let presentationDidChange = Notification.Name("NativeAgent.sensePresentationDidChange")
    public static let capacity = 200
    /// Retain acknowledged news to suppress repeats; unread news waits for the next turn, bounded by capacity and newest-per-corner replacement.
    public static let maximumAge: TimeInterval = 60 * 60
    private var items: [SenseNews] = []
    private var recent: [SenseNews] = []
    private struct History: Codable, Equatable {
        var count: Int
        var deltas: [String]
    }
    private struct Saved: Codable {
        var schema = 1
        var items: [SenseNews]
        // Keep acknowledged identities so restored watchers cannot renew unread status for the same change.
        var recent: [SenseNews]
        var histories: [UUID: History]
    }
    private static let maximumStorageBytes = 8 * 1_024 * 1_024
    private static let maximumSummaryBytes = 2_048
    private static let maximumUpdateBytes = 240
    private var histories: [UUID: History] = [:]
    private var view: SenseInteractiveView?
    private var storageURL: URL?
    private var dataRoot: URL?
    private var storageBlocked = false
    private var storageNotice: SenseNews?
    public private(set) var storageFailure: String?
    /// Bind before readers start; only missing files mean an empty board, while damaged bytes must remain visible and preserved.
    @discardableResult
    public func configure(dataRoot: URL) -> Bool {
        guard storageURL == nil || storageBlocked else { return true }
        defer { NotificationCenter.default.post(name: Self.presentationDidChange, object: nil) }
        let directory = dataRoot.appendingPathComponent("senses/news", isDirectory: true)
        storageURL = directory.appendingPathComponent("unread.json")
        self.dataRoot = dataRoot
        do {
            let fm = FileManager.default
            for folder in [directory.deletingLastPathComponent(), directory] {
                var info = stat()
                if lstat(folder.path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFDIR else {
                        throw storageError("Private news folder is not a directory.")
                    }
                } else {
                    guard errno == ENOENT else { throw storageError("Private news folder is unreadable.") }
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                }
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            guard let url = storageURL else { throw storageError("Private news store is not bound.") }
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG,
                      info.st_size >= 0, info.st_size <= Self.maximumStorageBytes else {
                    throw storageError("Private news store must be a bounded regular file.")
                }
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
                guard saved.schema == 1, saved.items.count <= Self.capacity,
                      saved.recent.count <= Self.capacity, saved.histories.count <= Self.capacity,
                      Set(saved.items.map(\.id)).count == saved.items.count,
                      saved.histories.values.allSatisfy({ $0.count >= $0.deltas.count && $0.count < Int.max && $0.deltas.count <= 3 }) else {
                    throw storageError("Private news store has invalid bounds or schema.")
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                // Bind before watches start without losing source-owned startup notices.
                let buffered = items
                items = saved.items
                recent = saved.recent
                histories = saved.histories
                for item in buffered where !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                    recent.append(item)
                }
                items = Array(items.suffix(Self.capacity))
                recent = Array(recent.suffix(Self.capacity))
            } else if errno != ENOENT {
                throw storageError("Private news store is unreadable.")
            }
            prune(save: false)
            // Only a checked reopen may unblock storage; later failed writes leave it blocked.
            storageBlocked = false
            try persist()
            return true
        } catch {
            storageBlocked = true
            fail(error)
            return false
        }
    }
    public func present(_ view: SenseInteractiveView?) {
        guard self.view != view else { return }
        self.view = view
        NotificationCenter.default.post(name: Self.presentationDidChange, object: nil)
    }
    public func interactiveView() -> SenseInteractiveView? { view }
    /// Keep news for the next turn; each new item is posted to attention as a world happening, weighed by the agent's turn program.
    @discardableResult
    public func post(_ news: SenseNews) async -> Bool {
        guard !Task.isCancelled else { return false }
        let before = (items, recent, histories)
        let fresh: SenseNews?
        do {
            _ = try checkedStorage()
            fresh = try postCurrent(news)
            guard items != before.0 || recent != before.1 || histories != before.2 else { return true }
            try persist()
        }
        catch {
            (items, recent, histories) = before
            fail(error)
            NotificationCenter.default.post(name: Self.presentationDidChange, object: nil)
            return false
        }
        NotificationCenter.default.post(name: Self.presentationDidChange, object: nil)
        await published(news)
        // Pruning alone changes retained state, but a repeat or expired item is no new occurrence.
        guard let fresh, let dataRoot else { return true }
        // What it is about is the watched address (its private identity); the door is the sense, so its yield gathers per sense.
        let address = String((fresh.observationID ?? Self.identity(fresh.address)).prefix(16))
        Attention.post(Happening(.world, subject: "sense:" + fresh.senseID + ":" + address, door: "sense:" + fresh.senseID,
            words: fresh.senseID + " at " + Self.updateLine(fresh.address) + ": " + Self.updateLine(fresh.summary),
            once: "sense:" + fresh.senseID + ":" + fresh.id.uuidString.lowercased()), dataRoot: dataRoot)
        return true
    }
    /// Keep a notice for the next turn without posting it to attention (a watch's own availability).
    @discardableResult
    public func keep(_ news: SenseNews) async -> Bool {
        guard !Task.isCancelled else { return false }
        let before = (items, recent, histories)
        do {
            _ = try checkedStorage()
            try postCurrent(news)
            guard items != before.0 || recent != before.1 || histories != before.2 else { return true }
            try persist()
        }
        catch {
            (items, recent, histories) = before
            fail(error)
            NotificationCenter.default.post(name: Self.presentationDidChange, object: nil)
            return false
        }
        NotificationCenter.default.post(name: Self.presentationDidChange, object: nil)
        await published(news)
        return true
    }
    private func published(_ news: SenseNews) async {
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "sense-news", stableID: news.senseID, operation: .changed,
            reason: "sense_news_posted", occurredAt: news.at))
    }
    /// Nil means the news was a repeat or too old to retain.
    @discardableResult
    private func postCurrent(_ news: SenseNews) throws -> SenseNews? {
        // Sanitize visible fields before clipping while retaining exact private observation/change identities.
        var news = news
        // Use private hashes for exact source identities so deduplication and storage stay bounded.
        news.observationID = Self.identity(news.observationID ?? news.address)
        news.changeID = Self.identity(news.changeID ?? news.summary)
        news.senseID = ContextSecretContentPolicy.redactedFragment(news.senseID)
        news.address = ContextSecretContentPolicy.redactedFragment(news.address)
        news.summary = Self.bounded(ContextSecretContentPolicy.redactedFragment(news.summary), bytes: Self.maximumSummaryBytes)
        prune(save: false)
        guard news.at >= Date().addingTimeInterval(-Self.maximumAge) else { return nil }
        let sameCorner: (SenseNews) -> Bool = {
            $0.senseID == news.senseID && $0.version == news.version
                && ($0.observationID ?? $0.address) == (news.observationID ?? news.address)
        }
        // Repeats must not renew age or unread status.
        guard !recent.contains(where: { sameCorner($0) && ($0.changeID ?? $0.summary) == (news.changeID ?? news.summary) }) else { return nil }
        recent.removeAll(where: sameCorner)
        recent.append(news)
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }
        var combined = news
        if let previous = items.first(where: sameCorner) {
            let history = histories.removeValue(forKey: previous.id) ?? History(count: 1, deltas: [Self.updateLine(previous.summary)])
            let deltas = Array(([Self.updateLine(news.summary)] + history.deltas).prefix(3))
            let increment = history.count.addingReportingOverflow(1)
            guard !increment.overflow, increment.partialValue < Int.max else {
                throw storageError("News history count exhausted; prior news preserved.")
            }
            let count = increment.partialValue
            histories[news.id] = History(count: count, deltas: deltas)
            let omitted = count - deltas.count
            combined.summary = "\(count) updates (newest first):\n" + deltas.map { "• " + $0 }.joined(separator: "\n")
                + (omitted > 0 ? "\n\(omitted) older updates omitted." : "")
        }
        combined.summary = ContextSecretContentPolicy.redactedFragment(combined.summary)
        // Keep only the latest notice per corner so rapid source edges cannot starve other corners.
        items.removeAll(where: sameCorner)
        items.append(combined)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        retainHistories()
        return news
    }
    public func latest(limit: Int = 20) -> [SenseNews] {
        prune()
        let ordered = items.sorted { $0.at > $1.at }
        return Array(((storageNotice.map { [$0] } ?? []) + ordered).prefix(max(0, limit)))
    }
    /// Acknowledge immutable notices only after provider output proves delivery; newer events at the same address must survive.
    public func acknowledge(_ ids: Set<UUID>) async {
        let previousItems = items
        let previousHistories = histories
        items.removeAll { ids.contains($0.id) }
        retainHistories()
        guard items != previousItems || histories != previousHistories else { return }
        defer { NotificationCenter.default.post(name: Self.presentationDidChange, object: nil) }
        // Persist removal before publication; failed bookkeeping cannot promise restart safety.
        do { try persist() } catch {
            items = previousItems
            histories = previousHistories
            fail(error)
        }
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "sense-news", stableID: "served", operation: .changed,
            reason: "sense_news_seen", occurredAt: Date()))
    }
    private func prune(save: Bool = true) {
        let previousCount = items.count + recent.count
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        let unread = Set(items.map(\.id))
        recent.removeAll { $0.at < cutoff && !unread.contains($0.id) }
        retainHistories()
        if save, previousCount != items.count + recent.count { saveVisible() }
    }
    private func retainHistories() {
        let ids = Set(items.map(\.id))
        histories = histories.filter { ids.contains($0.key) }
    }
    private static func identity(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= bytes - "…".utf8.count else { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }
    private static func updateLine(_ text: String) -> String {
        bounded(text.split(whereSeparator: \.isNewline).joined(separator: " · "), bytes: maximumUpdateBytes)
    }
    private func checkedStorage() throws -> URL {
        guard let storageURL else { throw storageError("Private news storage is not bound.") }
        guard !storageBlocked else { throw storageError(storageFailure ?? "Private news storage is unavailable.") }
        return storageURL
    }
    private func persist() throws {
        let storageURL = try checkedStorage()
        let bytes = try JSONEncoder().encode(Saved(items: items, recent: recent, histories: histories))
        guard bytes.count <= Self.maximumStorageBytes else { throw storageError("Private news storage exceeded its byte bound.") }
        guard NativePrivateFile.write(bytes, to: storageURL) else { throw storageError("Cannot durably write private unread news.") }
        storageFailure = nil
        storageNotice = nil
    }
    private func saveVisible() {
        do { try persist() } catch { fail(error) }
        NotificationCenter.default.post(name: Self.presentationDidChange, object: nil)
    }
    private func storageError(_ message: String) -> NSError {
        NSError(domain: "SenseNewsBoard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func fail(_ error: Error) {
        let message = ContextSecretContentPolicy.redactedFragment(error.localizedDescription)
        if storageFailure != message {
            FileHandle.standardError.write(Data("SenseNewsBoard: \(message)\n".utf8))
        }
        storageFailure = message
        storageNotice = SenseNews(senseID: "sense-news", version: 1, address: "senses:news",
            summary: """
                Unread news persistence unavailable: \(message) Pending news may be lost after restart. raw view · private news storage is unavailable.
                """, at: Date())
    }
}
