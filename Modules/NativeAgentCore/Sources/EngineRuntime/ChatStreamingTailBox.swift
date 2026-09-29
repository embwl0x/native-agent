import Observation

@MainActor
@Observable
public final class ChatStreamingTailBox {
    public init() {}
    /// nil means "no live value" — the row renders the content it was handed,
    /// which is what every settled row does and what this row does again once
    /// the turn's final write has gone through the structural seam.
    public var content: String?
}
