import Testing

// Package.swift declares a testTarget for every subsystem, including
// XConnector — but this directory was EMPTY (and empty dirs don't exist in
// git), so every fresh worktree failed SPM target resolution until someone
// hand-created it. This committed placeholder keeps worktree checkouts
// building; replace it with real XConnector tests when they land.
@Test func xconnectorTestTargetResolves() {
    #expect(Bool(true))
}
