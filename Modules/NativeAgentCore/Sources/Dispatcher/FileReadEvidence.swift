/// Request complete byte evidence from the ordinary permission-checked file
/// reader. It comes from the same open descriptor as content, never a reopen.
public enum FileReadEvidence {
    @TaskLocal public static var required = false
    @TaskLocal public static var directoryNames: [String]?
}
