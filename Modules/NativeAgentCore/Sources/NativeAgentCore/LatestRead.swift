import Foundation
// Blueprint: | `LatestRead.swift` | `LatestRead`: one owner's published snapshot; a read returns what it read, and publication moves forward only (a read or write that started later is never replaced by one that started earlier); `refreshDraft` instead applies only the newest-started form refresh, with field-edit protection owned by its caller; cancelled reads apply nothing and do not advance the published boundary; construction is nonisolated for facade assembly, while read/refreshDraft/write remain MainActor-isolated |

/// One owner's snapshot or form-refresh ordering
/// (docs/ARCHITECTURE_BLUEPRINT.md, read models).
///
/// For a published snapshot, every read of the owner's source goes through
/// `read`, and every committed write that changes what the owner shows goes
/// through `write`. Two laws:
///
/// - A read returns what it read. A caller that verifies its own mutation, or
///   serializes for the phone, uses its own result, never whatever happens to
///   be published when it resumes.
/// - Publication moves forward only. Each read or write takes a ticket when it
///   starts; it publishes only if nothing that started later has published
///   already. A slow read that started earlier can never replace a newer
///   snapshot, and a newer read that is still running never blocks an older
///   finished one from publishing in the meantime.
///
/// Readers never hand-roll generation counters: this is the one owner of
/// "which read may publish".
@MainActor
public final class LatestRead {
    private var started: UInt64 = 0
    private var published: UInt64 = 0

    public nonisolated init() {}

    /// Runs `load`, returns its value, and calls `publish` with it unless a
    /// read or write that started later has already published. A cancelled
    /// caller still receives its value but never publishes or advances the boundary.
    public func read<Value>(
        _ load: () async throws -> Value,
        publish: (Value) -> Void
    ) async rethrows -> Value {
        started += 1
        let ticket = started
        let value = try await load()
        if !Task.isCancelled, ticket > published {
            published = ticket
            publish(value)
        }
        return value
    }

    /// A form draft is not a published snapshot: only its newest-started
    /// refresh may apply; older results are blocked while it is pending. The caller
    /// captures the draft before loading and applies only fields the person
    /// has left untouched. Use one owner for all refresh paths of that draft.
    /// Cancellation still returns the read value without applying it.
    public func refreshDraft<Value>(
        _ load: () async throws -> Value,
        apply: (Value) -> Void
    ) async rethrows -> Value {
        started += 1
        let ticket = started
        let value = try await load()
        if !Task.isCancelled, ticket == started {
            published = ticket
            apply(value)
        }
        return value
    }

    /// A committed write publishes what it committed, ahead of every read that
    /// started before it (those can no longer replace it).
    public func write(_ publish: () -> Void) {
        started += 1
        published = started
        publish()
    }
}
