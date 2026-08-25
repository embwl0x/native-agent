/// Shared presentation taxonomy for remote chat surfaces that receive compact
/// tool-use events by name. The Mac dispatcher owns the executable catalog;
/// the cross-module parity eval keeps this small mobile projection exact so a
/// catalog rename cannot silently turn a skill read into an ordinary tool.
public enum ToolActivityPresentation {
    public static let skillReaderToolNames: Set<String> = [
        "list_skills",
        "read_skill",
    ]

    public static func isSkillReaderTool(named name: String) -> Bool {
        skillReaderToolNames.contains(name)
    }
}
