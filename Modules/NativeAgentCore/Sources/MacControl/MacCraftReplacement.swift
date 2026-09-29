/// The craft method replaces a complete value. A failed AX replacement must
/// not fall through to typing characters at the cursor.
public enum MacCraftReplacement {
    @TaskLocal public static var required = false
    @TaskLocal public static var documentPath: String?
    @TaskLocal public static var editorDigest: String?
}
