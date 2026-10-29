import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Transcripts
// Blueprint: | `CarriedAnchorRecollection.swift` | `CarriedAnchorRecollection` enum; `isEnabled`, `seeded` |

// MARK: - The carried recollection
//
// A session with no recollection of its own borrows the main conversation's
// recollection, admitted by the frozen handoff and marked as borrowed:
//
//     [session recollection, carried from your main conversation] …
//
// THREE PROPERTIES, and every one of them is load-bearing:
//
//   1. READ-ONLY. The rows are synthesised per turn, in memory, from the
//      anchor's transcript. They are never written into this session's
//      transcript, so the autocompactor never sees them, they can never be folded
//      into a recollection of this session's own, and they never move this
//      session's aging boundary.
//   2. CACHE-STABLE. Each is projected as an ordinary `compaction_summary` row,
//      which puts it ahead of the `HistoryWindowCursor` boundary in the stable
//      head of the replayed prefix — exactly where the session's own
//      recollection sits. Its identity is derived from the ANCHOR'S row id, so
//      the head changes when (and only when) the anchor's recollection does.
//   3. IT YIELDS. The moment this session gets a `compaction_summary` of its
//      own, no anchor recollections are seeded. All borrowed spans stay in
//      transcript order, including recollections preserved across the dream mark.
//
// Failure is not an event. No anchor, an anchor that is this session, an
// unreadable transcript, an anchor that has not compacted yet — all of them
// mean "no seed, carry on". Nothing here throws, and the one diagnostic is a
// single stderr line per session.
package enum CarriedAnchorRecollection {
    /// Kill switch. Like the autocompactor's own switches: absent → on, explicit false →
    /// off.
    static let defaultsKey = "chatCarryAnchorRecollection"

    /// `metadata` key stamped on the synthetic row, naming the session the
    /// recollection was carried FROM. Its presence is what makes the row read
    /// as borrowed rather than as this session's own.
    static let carriedFromKey = "carried_from"

    /// The label the projection puts in front of a carried recollection. The
    /// unborrowed one stays `[session recollection]`.
    static let renderPrefix = "[session recollection, carried from your main conversation]"

    static func isEnabled() -> Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// The rows the v2 prefix projection should admit: `prior` unchanged, or
    /// `prior` with the anchor's synthetic recollection rows in front of it.
    ///
    /// Called with the rows the reader already returned, so seeding costs at
    /// most two small transcript reads and only for a session that has no
    /// recollection of its own — which is precisely the fresh session this
    /// exists for.
    package static func seeded(
        _ prior: [ChatMessage],
        sessionId: String,
        dataRoot: URL,
        admittedPriorSessionId: String? = nil
    ) -> [ChatMessage] {
        syntheticRows(
            sessionId: sessionId, prior: prior, dataRoot: dataRoot, admittedPriorSessionId: admittedPriorSessionId
        ) + prior
    }

    /// The seed decision, whole, as a value. Empty means this turn carries nothing.
    static func syntheticRows(
        sessionId: String,
        prior: [ChatMessage],
        dataRoot: URL,
        admittedPriorSessionId: String?
    ) -> [ChatMessage] {
        guard isEnabled() else { return [] }
        // A SESSION ID IS A STORAGE KEY AND NOTHING ELSE, and this one arrives
        // from a JSON file on disk. `anchor_pin.json` is written by surface
        // adapters, so a malformed or hostile pin could name `../../…` and
        // every transcript path built from it would resolve outside
        // `chat/messages`. BOTH ids are normalized BEFORE any path exists;
        // anything that fails validation carries nothing.
        guard let session = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            noteUnsafeIdentifier(role: "session", raw: sessionId)
            return []
        }
        // Its own beats a borrowed one, and the rows in hand answer that for
        // free in the common case.
        guard !prior.contains(where: isOwnRecollection) else { return [] }
        // The anchor names the human's main conversation. A session that IS
        // the anchor has nothing to borrow from.
        guard let published = ConversationAnchor.currentSessionId(dataRoot: dataRoot) else {
            return []
        }
        guard let anchor = NativeAgentChatSessionID.normalizedPathComponent(published) else {
            noteUnsafeIdentifier(role: "anchor", raw: published)
            return []
        }
        guard anchor != session else { return [] }
        // Nil is unobserved; an empty admitted donor means the handoff carried no thread.
        guard (admittedPriorSessionId ?? SessionDigestProvider.frozenPriorSessionId(
            sessionId: session, dataRoot: dataRoot
        )) == anchor else { return [] }
        // The window the reader returned is a TAIL: a long session's own
        // recollection can sit above it. Confirm against the transcript before
        // borrowing, or a session with its own would carry a second one.
        guard recollections(forSession: session, dataRoot: dataRoot).isEmpty else {
            return []
        }
        // A transcript that cannot be read, or an anchor that has never
        // compacted, lands here as "nothing to carry" — the honest answer,
        // receipted once.
        let carried = recollections(forSession: anchor, dataRoot: dataRoot)
        guard !carried.isEmpty else {
            noteNoRecollection(session: session, anchor: anchor)
            return []
        }
        return carried.map { row(carrying: $0, into: session) }
    }

    // MARK: - The recollection lookup, memoized on the transcript's stat

    /// Every recollection in one session's transcript, in transcript order.
    ///
    /// Unchanged transcripts cost a stat; validated appends reuse completed
    /// rows and scan from the prior cursor. Replacements and rewrites rescan.
    ///
    /// `sessionId` MUST already be normalized: this builds a path from it.
    static func recollections(
        forSession sessionId: String,
        dataRoot: URL
    ) -> [ChatSessionRecollection] {
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        // No file, no recollection — and that answer already cost only a stat.
        guard let stamp = stamp(of: path), case let .present(device, inode, size, _, _, _, _) = stamp else { return [] }
        let key = path.path
        cacheLock.lock()
        if let hit = cache.first(where: { $0.key == key && $0.stamp == stamp }) {
            cacheLock.unlock()
            return hit.scan.recollections
        }
        let old = cache.first(where: { $0.key == key })
        cacheLock.unlock()

        // Transcript append retains inode; compaction atomically replaces it.
        // Same-size changes and truncation always rescan. A tail checkpoint
        // additionally rejects a replaced suffix before reusing the cursor.
        let appendSource = old.flatMap { entry -> ChatSessionRecollections.Scan? in
            guard case let .present(oldDevice, oldInode, oldSize, _, _, _, _) = entry.stamp,
                  oldDevice == device, oldInode == inode, size > oldSize,
                  checkpoint(path, size: oldSize) == entry.checkpoint else { return nil }
            return entry.scan
        }
        guard let scan = try? ChatSessionRecollections.scan(
            path: path, sessionId: sessionId,
            offset: appendSource?.nextOffset ?? 0,
            previous: appendSource?.completeRecollections ?? []
        ) else { return [] }
        guard self.stamp(of: path) == stamp else { return scan.recollections }

        cacheLock.lock()
        cache.removeAll { $0.key == key }
        cache.append(Entry(key: key, stamp: stamp, scan: scan,
                           checkpoint: checkpoint(path, size: size)))
        // Bounded, oldest out first. A handful covers the anchor plus the
        // sessions actually taking turns; this is a memo, not a store.
        if cache.count > cacheCapacity { cache.removeFirst(cache.count - cacheCapacity) }
        cacheLock.unlock()
        return scan.recollections
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
    private static func stamp(of path: URL) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard stat(path.path, &info) == 0 else { return nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

    private struct Entry {
        let key: String
        let stamp: SnapshotTailOpLog.FileStamp
        let scan: ChatSessionRecollections.Scan
        let checkpoint: Data?
    }

    private static let cacheCapacity = 8
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Entry] = []

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
        let stamp = recollection.createdAt.map(NativeTimestampFormat.fractionalZulu) ?? ""
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
