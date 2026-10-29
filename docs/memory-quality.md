# What a good memory is

The standard the memory tools are written to. User, 2026-09-05: "our
memory system should be the best out there."

**One memory is one thing that will still be true and useful in a month.** A fact about the
person, a preference, a decision, a relationship. Not a
status, not a build number, not what happened at 10:17, not who told you.

**It stands alone.** It is read later with nothing around it, so it says the thing itself, in
one or two sentences, the way you would tell a friend. "User drinks their coffee black." "User wants
pixels, not notes, before anything closes." Never a date, time, source, session id, commit hash,
heading, or "record of" preamble in the text: time, source and provenance are fields, shown
beside it.

A complete proposition may have a one-word object. Historical automatic-source
facts such as “user likes coffee” are not rejected for object length when read;
source metadata does not make that complete thought disappear from recall or
derived context. New writing still follows the naming standard below.
MemoryV2's `MemoryCandidateQuality` prepares source eligibility, kind and preference
payload once, then applies the ordered rejection rules for writes and derived reads.

**It names who.** The person by name, the agent by name; "the user" and "the assistant" are
not people.

**One current fact, with its record intact.** Repeated evidence belongs to the existing
fact. A correction closes the old fact's interval and leaves it out of current recall;
the old record is protected from capacity eviction. Disuse fades recall without deleting;
the [storage cap](data-bounds.md) can evict other rows. Derived knowledge is rebuilt from
the record, never by bulk merging, archiving or swapping memory rows.

**A moment is not a memory row.** What happened between you that moved their is a care's story
(their note, the felt word, the exchange it points at), not a sentence in this store.

**Transient state is not memory.** What is running, which pid, which commit, what is open in
Settings: the app knows those; the store does not need them.

**The graph follows the text.** Entities are people, places and organisations the tagger is
sure of, plus the project's known terms and code identifiers written in backticks. A capital
letter is not an entity.
