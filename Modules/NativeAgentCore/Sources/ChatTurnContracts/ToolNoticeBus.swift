import Foundation

/// Task-local bridge that lets a deep tool implementation (e.g. the
/// invoke_claude subprocess handler) push user-visible progress notices into
/// the CURRENT turn's stream without threading a callback through every
/// dispatcher wrapper (security gate, file gate, bridge deny, ...). The tool
/// loop binds `emit` to the turn's `progress` callback around each dispatch;
/// the value propagates down the structured-concurrency task tree. Emission is
/// best-effort by construction — when unset (background loops, tests) it's nil
/// and tools just don't emit.
public enum ToolNoticeBus {
    @TaskLocal public static var emit: (@Sendable (String, String) async -> Void)?
}
