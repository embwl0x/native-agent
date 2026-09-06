import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - The carried recollection
//
// A brand-new chat session used to open knowing NOTHING about the
// conversation the human has actually been having.
//
// Continuity lives in the session TRANSCRIPT: the aging lane distils older
// turns into a `compaction_summary` row and the history reader pins it at the
// head of the prompt as `[session recollection] …`. That row exists only in
// the session that aged. Every surface that mints a fresh session per chat —
// iOS does, on every chat — therefore starts with persona plus recall and no
// recollection at all, even while the SAME agent has a long, live main
// conversation elsewhere.
//
// `ConversationAnchor` already names that main conversation. So a session with
// no recollection of its own borrows the anchor's, at the head, marked as
// borrowed:
//
//     [session recollection, carried from your main conversation] …
//
// THREE PROPERTIES, and every one of them is load-bearing:
//
//   1. READ-ONLY. The row is synthesised per turn, in memory, from the
//      anchor's transcript. It is never written into this session's
//      transcript, so the autocompactor never sees it, it can never be folded
//      into a recollection of this session's own, and it never moves this
//      session's aging boundary.
//   2. CACHE-STABLE. It is projected as an ordinary `compaction_summary` row,
//      which puts it ahead of the `HistoryWindowCursor` boundary in the stable
//      head of the replayed prefix — exactly where the session's own
//      recollection sits. Its identity is derived from the ANCHOR'S row id, so
//      the head changes when (and only when) the anchor's recollection does.
//   3. IT YIELDS. The moment this session gets a `compaction_summary` of its
//      own, the carried one is not seeded at all: one recollection, never two.
//
// Failure is not an event. No anchor, an anchor that is this session, an
// unreadable transcript, an anchor that has not compacted yet — all of them
// mean "no seed, carry on". Nothing here throws, and the one diagnostic is a
// single stderr line per session.
enum CarriedAnchorRecollection {
    /// Kill switch. Read exactly the way `chatConversationPrefixShape` and the
    /// autocompactor's own switches are read: absent → on, explicit false →
    /// off. The defaults instance is injectable solely so a test can exercise
    /// the same reader against an isolated domain.
    static let defaultsKey = "chatCarryAnchorRecollection"

    /// `metadata` key stamped on the synthetic row, naming the session the
    /// recollection was carried FROM. Its presence is what makes the row read
    /// as borrowed rather than as this session's own.
    static let carriedFromKey = "carried_from"

    /// The label the projection puts in front of a carried recollection. The
    /// unborrowed one stays `[session recollection]`.
    static let renderPrefix = "[session recollection, carried from your main conversation]"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? true
            : defaults.bool(forKey: defaultsKey)
    }

    /// The rows the v2 prefix projection should admit: `prior` unchanged, or
    /// `prior` with one synthetic recollection row in front of it.
    ///
    /// Called with the rows the reader already returned, so seeding costs at
    /// most two small transcript reads and only for a session that has no
    /// recollection of its own — which is precisely the fresh session this
    /// exists for.
    static func seeded(
        _ prior: [ChatMessage],
        sessionId: String,
        dataRoot: URL,
        defaults: UserDefaults = .standard
    ) -> [ChatMessage] {
        guard let row = syntheticRow(
            sessionId: sessionId, prior: prior, dataRoot: dataRoot, defaults: defaults
        ) else { return prior }
        return [row] + prior
    }

    /// The seed decision, whole, as a value. Nil means "this turn carries
    /// nothing", which is the answer for every session that does not need one.
    static func syntheticRow(
        sessionId: String,
        prior: [ChatMessage],
        dataRoot: URL,
        defaults: UserDefaults = .standard
    ) -> ChatMessage? {
        guard isEnabled(defaults: defaults) else { return nil }
        // A SESSION ID IS A STORAGE KEY AND NOTHING ELSE, and this one arrives
        // from a JSON file on disk. `anchor_pin.json` is written by surface
        // adapters, so a malformed or hostile pin could name `../../…` and
        // every transcript path built from it would resolve outside
        // `chat/messages`. BOTH ids are normalized BEFORE any path exists;
        // anything that fails validation carries nothing.
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            noteUnsafeIdentifier(role: "session", raw: sessionId)
            return nil
        }
        // Its own beats a borrowed one, and the rows in hand answer that for
        // free in the common case.
        guard !prior.contains(where: isOwnRecollection) else { return nil }
        // The anchor names the human's main conversation. A session that IS
        // the anchor has nothing to borrow from.
        guard let published = ConversationAnchor.currentSessionId(dataRoot: dataRoot) else {
            return nil
        }
        guard let anchor = NativeAgentChatSessionID.normalizedPathComponent(published) else {
            noteUnsafeIdentifier(role: "anchor", raw: published)
            return nil
        }
        guard anchor != session else { return nil }
        // The window the reader returned is a TAIL: a long session's own
        // recollection can sit above it. Confirm against the transcript before
        // borrowing, or a session with its own would carry a second one.
        guard newestRecollection(forSession: session, dataRoot: dataRoot) == nil else {
            return nil
        }
        // A transcript that cannot be read, or an anchor that has never
        // compacted, lands here as "nothing to carry" — the honest answer,
        // receipted once.
        guard let carried = newestRecollection(forSession: anchor, dataRoot: dataRoot) else {
            noteNoRecollection(session: session, anchor: anchor)
            return nil
        }
        return row(carrying: carried, into: session)
    }

    // MARK: - The recollection lookup, memoized on the transcript's stat

    /// The newest recollection in one session's transcript, or nil.
    ///
    /// This runs on the HOT PROMPT PATH, twice per eligible turn, and the
    /// underlying accessor reads the WHOLE transcript — unbounded by the
    /// history reader's tail caps. A transcript only changes when a turn is
    /// appended or compaction rewrites it, so an unchanged one must cost a
    /// `stat`, not a read. The key is (path, mtime, size) — the same triple
    /// the doctor's transcript scan memo uses, and the one that still sees a
    /// same-size rewrite in place.
    ///
    /// `sessionId` MUST already be normalized: this builds a path from it.
    static func newestRecollection(
        forSession sessionId: String,
        dataRoot: URL
    ) -> ChatSessionRecollection? {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        // No file, no recollection — and that answer already cost only a stat.
        guard let stamp = stamp(of: path) else { return nil }
        let key = path.path
        cacheLock.lock()
        if let hit = cache.first(where: { $0.key == key && $0.stamp == stamp }) {
            cacheLock.unlock()
            return hit.recollection
        }
        // Counted under the same lock that guards the cache, so the tally
        // cannot race a concurrent miss on another thread.
        transcriptReadCount += 1
        let old = cache.first(where: { $0.key == key })
        cacheLock.unlock()

        // Transcript append retains inode; compaction atomically replaces it.
        // Same-size changes and truncation always rescan. A tail checkpoint
        // additionally rejects a replaced suffix before reusing the cursor.
        let append = old.map {
            $0.stamp.device == stamp.device && $0.stamp.inode == stamp.inode
                && stamp.size > $0.stamp.size && checkpoint(path, size: $0.stamp.size) == $0.checkpoint
        } ?? false
        guard let scan = try? ChatSessionRecollections.scanLatest(
            path: path, sessionId: sessionId,
            offset: append ? old!.nextOffset : 0,
            previous: append ? old?.recollection : nil
        ) else { return nil }
        let newest = scan.recollection
        guard self.stamp(of: path) == stamp else { return newest }

        cacheLock.lock()
        cache.removeAll { $0.key == key }
        cache.append(Entry(key: key, stamp: stamp, recollection: newest,
                           nextOffset: scan.nextOffset, checkpoint: checkpoint(path, size: stamp.size)))
        // Bounded, oldest out first. A handful covers the anchor plus the
        // sessions actually taking turns; this is a memo, not a store.
        if cache.count > cacheCapacity { cache.removeFirst(cache.count - cacheCapacity) }
        cacheLock.unlock()
        return newest
    }

    private static func checkpoint(_ path: URL, size: Int64) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: UInt64(max(0, size - 128)))
            return try file.read(upToCount: Int(min(128, size)))
        } catch { return nil }
    }

    /// stat identity of a file, or nil when it cannot be stat'd — which is
    /// also the "no transcript" answer.
    private static func stamp(of path: URL) -> Stamp? {
        var info = stat()
        guard stat(path.path, &info) == 0 else { return nil }
        return Stamp(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    struct Stamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct Entry {
        let key: String
        let stamp: Stamp
        let recollection: ChatSessionRecollection?
        let nextOffset: UInt64
        let checkpoint: Data?
    }

    private static let cacheCapacity = 8
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Entry] = []

    /// How many times a transcript was actually READ, as opposed to answered
    /// from the memo. Instrumentation for the regression suite: the memo is
    /// otherwise invisible, and an invisible cache is one nobody can prove
    /// still works.
    nonisolated(unsafe) static var transcriptReadCount = 0

    static func resetCache() {
        cacheLock.lock()
        cache.removeAll()
        transcriptReadCount = 0
        cacheLock.unlock()
    }

    /// The synthetic row itself. Shaped like the row the autocompactor writes,
    /// because every layer below reads that shape: `renderable` routes it to
    /// the compaction-summary cap, the window cursor exempts it from the drop
    /// boundary, and the projection leads the oldest replayed user message with
    /// it. Only the `carried_from` marker is new.
    static func row(
        carrying recollection: ChatSessionRecollection,
        into sessionId: String
    ) -> ChatMessage {
        // Identity is the ANCHOR's row id, so the seeded head is a pure
        // function of the anchor's recollection: same row, same bytes, same
        // digest, turn after turn. `messages_replaced` is a stable fallback for
        // a legacy row with no id of its own.
        let key = recollection.rowId ?? "n\(recollection.messagesReplaced)c\(recollection.text.count)"
        let stamp = recollection.createdAt.map(iso8601) ?? ""
        return ChatMessage(
            role: "system",
            content: recollection.text,
            timestamp: stamp,
            extras: .object([
                "id": .string("carried-recollection\u{1F}\(key)"),
                "sessionId": .string(sessionId),
                "metadata": .object([
                    "kind": .string(ChatSessionRecollections.rowKind),
                    carriedFromKey: .string(recollection.sessionId),
                    "messages_replaced": .int(Int64(recollection.messagesReplaced)),
                    "distill": .string(recollection.distilled ? "llm" : "mechanical"),
                ]),
            ])
        )
    }

    // MARK: - Internals

    private static func isOwnRecollection(_ message: ChatMessage) -> Bool {
        guard case .object(let extras)? = message.extras,
              case .object(let metadata)? = extras["metadata"],
              case .string(let kind)? = metadata["kind"]
        else { return false }
        return kind == ChatSessionRecollections.rowKind
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// One stderr line per session, ever. An anchor that names a conversation
    /// with nothing to carry is a legitimate state (it simply has not aged
    /// yet), so this is a receipt, not an error — but a silent one would make
    /// "the seed is off" and "the seed found nothing" indistinguishable from
    /// outside, which is the failure mode worth spending one line on.
    private static let noteLock = NSLock()
    nonisolated(unsafe) private static var notedSessions: Set<String> = []

    /// An id that cannot be a path component is not a near-miss to be repaired
    /// — it is a pin nobody should trust. Say so once, carry nothing, and put
    /// no part of it in the log line: an untrusted string is not a receipt.
    private static func noteUnsafeIdentifier(role: String, raw: String) {
        noteLock.lock()
        let firstTime = notedSessions.insert("unsafe-" + role).inserted
        noteLock.unlock()
        guard firstTime else { return }
        FileHandle.standardError.write(Data(
            "CarriedAnchorRecollection: refusing an unsafe \(role) id (\(raw.count) chars); no recollection carried.\n".utf8
        ))
    }

    private static func noteNoRecollection(session: String, anchor: String) {
        noteLock.lock()
        let firstTime = notedSessions.insert(session).inserted
        noteLock.unlock()
        guard firstTime else { return }
        FileHandle.standardError.write(Data(
            "CarriedAnchorRecollection: session \(session) found no recollection on anchor \(anchor); this turn carries none.\n".utf8
        ))
    }
}
