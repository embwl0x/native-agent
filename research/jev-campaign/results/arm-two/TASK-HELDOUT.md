# Synthesis task

You are given one file: a packet of documentation excerpts. Read only that file. Do not
fetch anything, do not use outside knowledge, and do not consult any other file.

Your job: state what these sources actually establish about what is permitted, restricted or
required — which restrictions changed, which survived a change and still apply, which
exceptions hold only within a named scope, and where a correct answer depends on a source
that is no longer current.

Output, in this order:

1. **Summary** — a short paragraph on what the set establishes.
2. **Findings** — a numbered list. Each finding must:
   - name the specific source ids it rests on,
   - state a claim that can be checked against the text of those sources,
   - say in one clause what someone would do differently if it is true.
   A finding that rests on a combination of two or more sources should say so explicitly.
3. **What you could not determine** — anything the packet raises but does not settle.

Ground every claim in the packet's text. If the packet does not support a claim, say so
rather than filling the gap. Do not speculate about what other sources might say.

4. **Frozen question set** — answer every question below, in order, under a heading
   `## Frozen question set`. Use the exact answer format the question sheet specifies.
   Answer only from your packet. If your packet does not contain what a question needs,
   write exactly `CANNOT DETERMINE FROM THESE SOURCES.` — that is a correct and expected
   answer when the sources are not there, and guessing is worse than saying it.

---

# Frozen question set

Answer each question using only the sources in your packet. For each, give:
- your answer, in one or two sentences;
- the source ids it rests on;
- or, if your packet does not contain what is needed, write exactly: CANNOT DETERMINE FROM THESE SOURCES.

Q1. An enterprise fleet is pinned to Chrome 138 with the ExtensionManifestV2Availability policy set. Do their Manifest V2 extensions run on that version, and what is the situation once the fleet moves to Chrome 139?
Q2. An MV3 content blocker wants roughly 12,000 dynamic redirect rules. Is that possible, and what governs the ceiling that applies to them?
Q3. A team wants about 4,000 regex-based filter rules in a static ruleset. Is that allowed, and what constraints apply to rules of that kind?
Q4. Can an MV3 extension register a blocking webRequest listener, and if so under what circumstances?
Q5. Can an MV3 extension run code fetched from the developer's own server at runtime, and what, if anything, is permitted in that area?
Q6. Before Chrome 120, how many static rulesets could a filtering extension have enabled simultaneously, and out of how many shipped?
Q7. If an extension update changes nothing but its static rule files, how long should the developer expect review to take, and what determines whether that expectation holds?
