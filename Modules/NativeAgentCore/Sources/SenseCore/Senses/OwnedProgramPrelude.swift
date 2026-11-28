// Blueprint: | `OwnedProgramPrelude.swift` | Host primitive namespaces, file primitives and named host door actions |
extension OwnedProgramRunner {
    public static let hostPrimitiveNamespaces: Set<String> = ["files", "network", "program", "apps", "model", "ax"]
    public static let layeredHostPrimitives: Set<String> = ["network.websocket.open", "network.websocket.send", "network.websocket.receive",
        "network.websocket.close", "fetch.sse.open", "fetch.sse.next", "fetch.sse.close"]
    /// The stem's own file readers: a snapshot SQLite query, a MIME message read and a directory's names. Every other files.* call is the gated
    /// door action.
    public static let hostFilePrimitives: Set<String> = ["files.query", "files.mime", "files.names"]
    public static let hostDoorActions: Set<String> = [
        "calendar.upcoming", "calendar.create", "calendar.modify", "calendar.delete",
        "reminders.query", "reminders.create", "reminders.update", "reminders.delete",
        "contacts.search", "contacts.save"
    ]
}
