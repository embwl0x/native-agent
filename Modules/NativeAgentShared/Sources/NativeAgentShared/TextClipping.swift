// Blueprint: | `TextClipping.swift` | Character prefixes with required nonnegative limits or negative limits meaning unlimited |

public enum TextClipping {
    /// Take up to `limit` characters. The limit must be nonnegative.
    public static func prefix(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }

    /// A negative limit leaves the text whole.
    public static func prefixOrWhole(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters >= 0 else { return text }
        return prefix(text, to: maxCharacters)
    }
}
