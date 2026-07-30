// The ONE definition of USER.md's section markers.
//
// Three subsystems read or write these strings and none of them can import
// the others:
//
//   * MemoryV2 (`UserMDGenerator`)      — writes them
//   * Context  (`ContextMarkdownCompiler`) — cuts per-fact atoms inside them
//   * Context  (`ContextFlowCoordinator`)  — decides precoverage from them
//
// They used to be three independent literals. A literal that drifts here does
// not fail loudly: the generator keeps writing, the compiler silently stops
// atomizing, and precoverage silently stops applying. Same class of bug as
// `MemoryDisplayText` — two renderers of one string compared for equality —
// so it gets the same treatment: one owner, in the base target both sides
// already depend on.

public enum UserMDAutogenMarkers {
    /// Opens the human-edited preamble that generation must preserve.
    public static let preambleStart = "<!-- USER_PREAMBLE_START -->"
    /// Closes the human-edited preamble.
    public static let preambleEnd = "<!-- USER_PREAMBLE_END -->"
    /// Opens the machine-generated fact body.
    public static let bodyStart = "<!-- USER_MD_AUTOGEN_START -->"
    /// Closes the machine-generated fact body.
    public static let bodyEnd = "<!-- USER_MD_AUTOGEN_END -->"
}
