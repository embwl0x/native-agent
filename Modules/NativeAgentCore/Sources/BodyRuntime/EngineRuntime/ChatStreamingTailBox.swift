import Observation
// Blueprint: | `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |

@MainActor
@Observable
public final class ChatStreamingTailBox {
    public init() {}
    /// Nil uses settled row content after the turn’s final write.
    public var content: String?
}
