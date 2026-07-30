// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

extension ChatStore {
    // MARK: - Typewriter streaming (chat-smoothness phase 2, 2026-06-12)
    //
    // The Mac batches text_delta BridgeMessages every ~1.5s (iCloud Drive
    // write-rate limit), so true word-by-word can never arrive over the
    // transport. the user's word-flow decision applies to the FEEL: each arriving
    // chunk plays out progressively in ~70ms word steps instead of slamming
    // in as a wall. Catch-up pace scales with backlog so the bubble never
    // lags a full window behind. Streaming ticks suppress persistence — the
    // old path JSON-encoded the whole capped transcript to UserDefaults on
    // every chunk, on the main actor, for a partial bubble that finalize
    // rewrites anyway.


    func cancelTypewriter(_ placeholderId: UUID) {
        typewriterTasks.removeValue(forKey: placeholderId)?.cancel()
        typewriterTargets.removeValue(forKey: placeholderId)
    }

    func cancelAllTypewriters() {
        for task in typewriterTasks.values { task.cancel() }
        typewriterTasks.removeAll()
        typewriterTargets.removeAll()
    }

    private func setStreamingText(_ placeholderId: UUID, _ text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        suppressMessagePersistence = true
        var updated = messages[idx]
        updated.text = text
        updated.isStreaming = true
        messages[idx] = updated
        suppressMessagePersistence = false
    }

    /// Next chunk to reveal: at least `targetLen` characters, extended to the
    /// next word boundary so words never appear half-typed. Backlog-scaled —
    /// a big catch-up takes bigger bites. Internal for tests.
    static func typewriterChunk(of remaining: Substring) -> String {
        let targetLen = max(8, remaining.count / 20)
        if remaining.count <= targetLen { return String(remaining) }
        let start = remaining.index(remaining.startIndex, offsetBy: targetLen)
        if let boundary = remaining[start...].firstIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(remaining[..<remaining.index(after: boundary)])
        }
        return String(remaining)
    }

    func typewriterAdvance(placeholderId: UUID, target: String) {
        typewriterTargets[placeholderId] = target
        guard typewriterTasks[placeholderId] == nil else { return }
        typewriterTasks[placeholderId] = Task { @MainActor [weak self] in
            defer {
                // Clear BOTH maps here, not just in cancelTypewriter — several
                // resolution paths (snapshot merge, retries) remove the
                // placeholder row directly without calling finishPlaceholder,
                // and the target string is a full reply that must not leak.
                self?.typewriterTasks.removeValue(forKey: placeholderId)
                self?.typewriterTargets.removeValue(forKey: placeholderId)
            }
            while !Task.isCancelled {
                guard let self,
                      let target = self.typewriterTargets[placeholderId],
                      let idx = self.messages.firstIndex(where: { $0.id == placeholderId })
                else { return }
                let current = self.messages[idx].text
                guard target.count > current.count, target.hasPrefix(current) else {
                    // Caught up — or the target was rewritten under us (deltas
                    // carry accumulated text, so this means a correction): snap.
                    if target != current { self.setStreamingText(placeholderId, target) }
                    return
                }
                let remaining = target[target.index(target.startIndex, offsetBy: current.count)...]
                self.setStreamingText(placeholderId, current + Self.typewriterChunk(of: remaining))
                try? await Task.sleep(nanoseconds: UInt64(Self.typewriterTickSeconds * 1_000_000_000))
            }
        }
    }

    func streamingHint(for message: ChatMessage) -> String {
        if let hint = streamingHintsByMessageId[message.id], !hint.isEmpty {
            return hint
        }
        if isPollingFallback {
            return "Still working on the Mac"
        }
        return "Typing"
    }
}
