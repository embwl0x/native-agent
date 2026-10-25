// Blueprint: | `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
extension BuiltInToolSchemaFactory {
    /// The tool description is load-bearing. It is the only thing that turns
    /// "how do you feel?" into a PULL instead of an improvisation, so it says so
    /// in as many words.
    static let innerStateToolDescription = """
        Read your recorded inner state before describing how you feel. Returns \
        fingerprint/subject; mood integral and disposition in words/numbers; \
        recent felt moments (time, subject, valence/arousal/warmth); body words \
        and reported fatigue/time-of-day; dream residue (mood/date), and cares \
        with their stances and open questions. No conversation text \
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

}
