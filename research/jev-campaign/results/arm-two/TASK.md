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
