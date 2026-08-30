import Foundation
import Testing
@testable import TelegramBot
import PersistenceCore
import NativeAgentTestSupport

private final class TelegramUpdateInboxScanStub: ConfigurableURLProtocolStub {}

private final class TelegramClaimReadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [TelegramUpdateInbox.ClaimReadKind: Int] = [:]

    func record(_ kind: TelegramUpdateInbox.ClaimReadKind) {
        lock.withLock { counts[kind, default: 0] += 1 }
    }

    func count(_ kind: TelegramUpdateInbox.ClaimReadKind) -> Int {
        lock.withLock { counts[kind, default: 0] }
    }
}

// MARK: - Coverage ledger: telegram.pollLoop.dataRootInference
//                         telegram.updateInbox.pruneTerminalClaims
//                         telegram.updateInbox.perTickFullScan
//
// Every Telegram feed, the state file, the work-card ledger and the durable
// inbox are addressed off a root INFERRED from the offset file's path shape.
// A non-canonical offsetURL silently forks a whole parallel `telegram/` tree
// the Mac UI and the instrument never read: receipts vanish, the settings
// panel shows a dead bot, and the app looks idle rather than broken. That is
// the dataRoot-misread class that has burned this repo before, and it had zero
// pinning.

@Suite struct TelegramUpdateInboxRootTests {

    @Test func inferDataRoot_resolves_the_canonical_offset_path_to_its_root() {
        let root = URL(fileURLWithPath: "/tmp/na-root", isDirectory: true)
        let canonical = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        #expect(
            TelegramPollLoop.inferDataRoot(from: canonical).standardizedFileURL
                == root.standardizedFileURL
        )
        // The durable inbox must land INSIDE the same telegram dir, never a
        // sibling: the loop and the app read this directory by convention.
        #expect(
            TelegramUpdateInbox(offsetURL: canonical).directory.standardizedFileURL
                == root
                    .appendingPathComponent("telegram", isDirectory: true)
                    .appendingPathComponent("update_inbox", isDirectory: true)
                    .standardizedFileURL
        )
    }

    /// The constructed loop must agree with the static inference — a
    /// divergence here is the exact "two trees, one of them unread" bug.
    @Test func pollLoop_dataRoot_matches_inference_and_an_explicit_root_wins() {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offset = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")

        let inferred = TelegramPollLoop(token: "t", offsetURL: offset)
        #expect(inferred.dataRoot.standardizedFileURL == root.standardizedFileURL)
        #expect(
            inferred.telegramDir.standardizedFileURL
                == root.appendingPathComponent("telegram", isDirectory: true).standardizedFileURL
        )

        let explicitRoot = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: explicitRoot) }
        let explicit = TelegramPollLoop(token: "t", dataRoot: explicitRoot, offsetURL: offset)
        #expect(explicit.dataRoot.standardizedFileURL == explicitRoot.standardizedFileURL)
    }

    /// A NON-canonical offset path (parent not named `telegram`) forks the
    /// tree: the root becomes the offset's own parent and the inbox becomes a
    /// `<offsetFile>.inbox` sidecar. Nothing fails; the writes just land where
    /// nothing reads. Pinned as the CURRENT contract so the fork can never
    /// widen unnoticed, and so a future fail-loud fix has to come here first.
    @Test func inferDataRoot_documents_the_non_canonical_fork() {
        let odd = URL(fileURLWithPath: "/tmp/na-root/somewhere/offset.json")

        #expect(
            TelegramPollLoop.inferDataRoot(from: odd).standardizedFileURL
                == URL(fileURLWithPath: "/tmp/na-root/somewhere", isDirectory: true).standardizedFileURL
        )
        let inbox = TelegramUpdateInbox(offsetURL: odd).directory
        #expect(inbox.lastPathComponent == "offset.json.inbox")
        // The fork is REAL and observable: it is not the canonical location.
        #expect(inbox.lastPathComponent != "update_inbox")
    }

    // MARK: prune

    private func seedTerminalClaims(_ inbox: TelegramUpdateInbox, count: Int) async throws {
        for id in 0..<count {
            let update = TelegramUpdate(
                updateId: id,
                message: TelegramMessage(messageId: id, chatId: 77, fromUserId: 11, text: "m\(id)")
            )
            _ = try await inbox.ensurePending(update)
            _ = try await inbox.transition(updateId: id, from: [.pending], to: .completed)
        }
    }

    private func fileNames(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func claimFileNames(_ dir: URL) -> [String] {
        fileNames(dir).filter {
            $0.hasSuffix(".json")
                && Int(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) != nil
        }
    }

    @Test func pruneTerminalClaims_bounds_the_retained_claim_set() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TelegramUpdateInbox(
            offsetURL: root
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("last_offset.json")
        )
        try await seedTerminalClaims(inbox, count: 10)
        let seeded = try await inbox.snapshots()
        #expect(seeded.count == 10)

        await inbox.pruneTerminalClaims(keepingNewest: 4)

        let kept = try await inbox.snapshots()
        #expect(kept.count == 4)
        // Newest survive: retention is by update id order, so a prune that
        // dropped the WRONG end would silently discard live-adjacent work.
        #expect(kept.map(\.updateId) == [6, 7, 8, 9])
        let claimFiles = claimFileNames(inbox.directory)
        #expect(claimFiles.count == 4)
    }

    /// Same adverse race through the actual poll-loop boundary. `/help` is a
    /// completed, non-turn update; its reply transport writes a malformed file
    /// after recovery but before the tick's retention step. The recovered
    /// claims must still be pruned from that one authoritative read.
    @Test func pollTickRetainsFromRecoveryWithoutASecondClaimScan() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offsetURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
        try await seedTerminalClaims(inbox, count: 257)

        let session = TelegramUpdateInboxScanStub.makeSession { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.telegram.org")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let payload = Data(
                #"{"ok":true,"result":[{"update_id":300,"message":{"message_id":300,"chat":{"id":77},"from":{"id":11},"text":"/help","date":1}}]}"#
                    .utf8
            )
            return (response, payload)
        }
        let loop = TelegramPollLoop(
            interval: 60,
            token: "test-token",
            allowedChatIds: [77],
            session: session,
            dataRoot: root,
            offsetURL: offsetURL,
            sendMessage: { _, _, _ in
                try FileManager.default.createDirectory(at: inbox.directory, withIntermediateDirectories: true)
                try Data("malformed after recovery".utf8).write(
                    to: inbox.directory.appendingPathComponent("corrupt-later.json")
                )
            },
            syncCommandMenu: nil,
            voiceDownloader: nil,
            photoDownloader: nil
        )

        let reads = TelegramClaimReadCapture()
        let clock = ContinuousClock()
        let started = clock.now
        await TelegramUpdateInbox.$claimReadObserver.withValue({ kind in
            reads.record(kind)
        }) {
            await loop.tick()
        }
        let elapsed = started.duration(to: clock.now)

        let claimNames = claimFileNames(inbox.directory)
        #expect(claimNames.count == 256)
        #expect(fileNames(inbox.directory).contains("corrupt-later.json"))
        #expect(!claimNames.contains("0.json"))
        #expect(!claimNames.contains("1.json"))
        #expect(claimNames.contains("300.json"))
        // 256 historical terminal claims exist, but this tick only decodes
        // the two mutation reads for update 300. A retained-history scan
        // would make this 258+ and violate the bounded latency contract.
        #expect(reads.count(.recovery) == 0)
        #expect(reads.count(.mutation) <= 2)
        #expect(reads.count(.diagnosticSnapshot) == 0)
        #expect(elapsed < .seconds(2))
    }

    @Test func maintainedIndexRecoversPendingWorkAfterAFreshInboxConstruction() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offsetURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let update = TelegramUpdate(
            updateId: 42,
            message: TelegramMessage(messageId: 42, chatId: 77, fromUserId: 11, text: "resume me")
        )
        let first = TelegramUpdateInbox(offsetURL: offsetURL)
        _ = try await first.ensurePending(update)

        let restarted = TelegramUpdateInbox(offsetURL: offsetURL)
        let recovered = try await restarted.recoverableClaims()
        #expect(recovered.map(\.updateId) == [42])
        #expect(recovered.first?.phase == .pending)
        #expect(recovered.first?.update.message?.text == "resume me")
    }

    @Test func malformedIndexedPendingClaimFailsClosedDuringRecovery() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offsetURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let update = TelegramUpdate(
            updateId: 43,
            message: TelegramMessage(messageId: 43, chatId: 77, fromUserId: 11, text: "do not replay")
        )
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
        _ = try await inbox.ensurePending(update)
        try Data("broken claim bytes".utf8).write(
            to: inbox.directory.appendingPathComponent("43.json")
        )

        let restarted = TelegramUpdateInbox(offsetURL: offsetURL)
        await #expect(throws: TelegramUpdateInboxError.self) {
            _ = try await restarted.recoverableClaims()
        }
    }

    /// CONFIRMED LIVE LEAK (state-lifecycle class). `ensurePending`/`transition`
    /// each run under `withFileLock`, which creates a `<id>.json.lock` sidecar;
    /// prune removes the `.json` and never the sibling. On the live install the
    /// directory holds 256 claims and 315 orphaned `.lock` files, and the lock
    /// count grows without bound for the life of the install.
    @Test func pruneTerminalClaims_should_leave_no_orphan_lock_sidecars() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TelegramUpdateInbox(
            offsetURL: root
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("last_offset.json")
        )
        try await seedTerminalClaims(inbox, count: 10)
        await inbox.pruneTerminalClaims(keepingNewest: 4)

        let names = fileNames(inbox.directory)
        let claims = Set(names.filter { $0.hasSuffix(".json") })
        let orphanLocks = names
            .filter { $0.hasSuffix(".json.lock") }
            .filter { !claims.contains(String($0.dropLast(5))) }

        #expect(orphanLocks.isEmpty)
        // Kept claims may each retain their own live lock sidecar plus the
        // maintained index — the tooth is orphanLocks above, not lock absence.
        #expect(names.count <= claims.count * 2 + 1)
    }
}
