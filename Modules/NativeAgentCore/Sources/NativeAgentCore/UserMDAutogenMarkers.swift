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

import Foundation

public enum UserMDAutogenMarkers {
    /// Opens the human-edited preamble that generation must preserve.
    public static let preambleStart = "<!-- USER_PREAMBLE_START -->"
    /// Closes the human-edited preamble.
    public static let preambleEnd = "<!-- USER_PREAMBLE_END -->"
    /// Opens the machine-generated fact body.
    public static let bodyStart = "<!-- USER_MD_AUTOGEN_START -->"
    /// Closes the machine-generated fact body.
    public static let bodyEnd = "<!-- USER_MD_AUTOGEN_END -->"

    /// Includes the renderer's `# USER\n` heading. Nil core preserves the
    /// whole document until the first pin; an empty core carries only prose.
    public static let promptByteCap = 3_500

    public static func promptText(_ document: String, pinnedCore: [String]?) -> String {
        guard let pinnedCore else { return document }
        let preamble: String
        if let start = document.range(of: preambleStart),
           let end = document.range(of: preambleEnd, range: start.upperBound..<document.endIndex) {
            preamble = String(document[start.upperBound..<end.lowerBound])
        } else if let start = document.range(of: bodyStart) {
            preamble = String(document[..<start.lowerBound])
        } else {
            preamble = document
        }
        let budget = promptByteCap - "# USER\n".utf8.count
        var result = ""
        var bytes = 0
        for character in preamble.trimmingCharacters(in: .whitespacesAndNewlines) {
            let size = String(character).utf8.count
            guard bytes + size <= budget else { break }
            result.append(character)
            bytes += size
        }
        for fact in pinnedCore {
            let line = (result.isEmpty ? "" : "\n\n") + "- " + fact
            guard bytes + line.utf8.count <= budget else { break }
            result += line
            bytes += line.utf8.count
        }
        return result
    }
}
