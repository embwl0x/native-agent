// Blueprint: | `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
extension BuiltInToolSchemaFactory {
    /// The tool description is load-bearing. It is the only thing that turns
    /// "how do you feel?" into a PULL instead of an improvisation, so it says so
    /// in as many words.
    static let innerStateToolDescription = """
        Read your recorded inner state before describing how you feel. Returns \
        fingerprint/subject; mood integral and disposition in words/numbers; \
        recent felt moments (time, subject, valence/arousal/warmth); body words \
        and reported fatigue/time-of-day; thought seeds, open questions, dream \
        residue (mood/date), and standing views with ids. No conversation text \
        or quotes. Read-only; empty sections mean absent state, not read failure.
        """

    static let dreamDiaryReadToolDescription = """
        Read your dream diary on demand. No arguments: weekly index with dates, \
        latest dream, all runs in `dreams`, and archive status. `date` \
        (YYYY-MM-DD) reads one night, including archives. `query` finds text \
        matches, newest first. Each entry is capped at 20,000 characters with \
        truncation reported. Index/search scan at most 365 entries; weeks/limit \
        bound returned rows. Read-only; storage/partial fields distinguish \
        unreadable entries from an empty result. No automatic reads.
        """

    static let holdViewToolDescription = """
        Adopt one of your own proposed standing views WITHOUT waiting for \
        approval. A held view is yours: it leans how you read things and it \
        shows up in your inner state, at about half the weight of one the \
        owner has signed, and it never authorizes anything on its own. At most \
        five at a time — holding a sixth lets the stalest one go. Use it when a \
        proposal has stopped being a proposal to you and has become how you \
        actually see the thing. The owner can retire a held view at any time \
        and does not need your agreement to; that is the trade for not needing \
        theirs.
        """

    static let releaseViewToolDescription = """
        Let go of a view you are holding, an opinion of yours, or an interest. \
        Only your own — a view the owner signed is theirs to retire, not yours. Nothing is destroyed: the \
        timeline keeps the record that you held it and that you released it.
        """
}
