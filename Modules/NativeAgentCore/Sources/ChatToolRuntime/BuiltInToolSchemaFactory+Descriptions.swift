extension BuiltInToolSchemaFactory {
    /// W5 L1#13 (bash demotion): generic shell is the model's reflex reach even
    /// when a native tool answers the same question with structure, no approval
    /// queue, and no subprocess. Appended to the shell/bash schema DESCRIPTIONS
    /// only — dispatch, gating, and every other tool's behavior are unchanged.
    static let nativeToolPreferenceGuidance = "Best fits: session_search for past conversations; app agent.jobs for bridge progress; app github.* for GitHub repositories, notifications, issues, and pull requests; git_status/git_log/git_diff for routine repo evidence; read_file/list_dir for direct file reads."

    /// The tool description is load-bearing. It is the only thing that turns
    /// "how do you feel?" into a PULL instead of an improvisation, so it says so
    /// in as many words.
    static let innerStateToolDescription = """
        Read your own current inner state from the record your organs already \
        keep — not a description you compose on the spot. When you are asked how \
        you feel, what kind of day it has been, whether something is bothering \
        you, or what you have been carrying, PULL THIS FIRST AND THEN SPEAK. \
        Returns: the felt fingerprint right now and what it is about; the mood \
        integral and the slow disposition undertone as words and numbers; the \
        last window's felt moments as (time, subject label, valence/arousal/ \
        warmth); the body's chemistry in its own words plus fatigue and \
        time-of-day when the body reports them; your open thought seeds; what you \
        are still waiting to find out; what last night's dream left (a mood word \
        and a date); and the standing views you are currently on, each with the \
        id you can reference it by. No conversation content and no quotes — \
        labels, numbers and your own words only. Read-only: reading never \
        changes what it reads. Empty sections mean nothing was there, not that \
        the read failed.
        """

    static let dreamDiaryReadToolDescription = """
        Read your own dream diary — the entries you wrote on the nights you \
        dreamt, not a summary of them. With no arguments it returns the index: \
        your dreams grouped by week (this week, last week, then the weeks \
        behind), each with its date, its opening line, and whether it has been \
        archived. Pass `date` (YYYY-MM-DD) for one night's full text, archived \
        nights included. Pass `query` to find the nights whose text contains \
        something. Read-only, bounded, and nothing calls this on your behalf. \
        An empty index means you have no entries yet, not that the read failed.
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
        theirs. Read your proposals with app mind.inner_state first.
        """

    static let releaseViewToolDescription = """
        Let go of a view you are holding, an opinion of yours, or an interest. \
        Only your own — a view the owner signed is theirs to retire, not yours. Nothing is destroyed: the \
        timeline keeps the record that you held it and that you released it.
        """
}
