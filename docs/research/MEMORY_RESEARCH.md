# How a person remembers

Research on memory, written for Claude on 2026-10-25 as raw material for the
agent design. It covers how human memory works, what an agent that lives with
one person for months needs from it, what artificial agent memory has tried,
and what storage should sit underneath. Each area ends with the mechanism an
agent would need. It does not propose features.

It deepens section 4 ("Memory and the self") of
[PERSONALITY_RESEARCH.md](PERSONALITY_RESEARCH.md); where that document
already covers a finding, this one cites it and moves on.

How sure each finding is:

- *[meta-analytic]*: a meta-analysis or a very large literature agrees.
- *[replicated]*: independent labs have repeated it.
- *[debated]*: real evidence on both sides, or the effect holds and its
  mechanism is contested.
- *[few studies]*: one lab, small samples or one paradigm.
- *[theory]*: a framework or modelling argument more than an effect.
- *[failed replication]*: a famous finding that did not hold up, said
  plainly.

Numbers marked *measured here* were run on this Mac (Apple M5 Max) for this
document, at background priority (`taskpolicy -b`), so they are conservative.

---

## The answer first

- **Memory is what caring leaves behind.** People keep a small, chosen
  fraction of what happens to them. Attention, emotional arousal and
  relevance to current goals make the choice, and arousal *multiplies* goal
  priority rather than adding to it: it strengthens what the person was
  treating as important and weakens what they were not. Significance is not
  settled at encoding. Something that matters later reaches back and
  strengthens earlier related memories.
- **What lasts is gist, folded into what is already known.** Offline replay,
  much of it in sleep, keeps what is tagged as mattering for the future,
  extracts the pattern and lets specifics fade. What fits an existing schema
  consolidates fast. Specific episodes survive only while a concern holds
  them.
- **Recall is cue-driven and rebuilds as it goes.** Nothing comes back
  without a cue that fits how it was stored. Most remembering is involuntary,
  being *reminded*, and current concerns are the strongest cues. Every recall
  strengthens what came back, weakens its competitors and edits it.
- **Forgetting is the system working.** Accessibility tracks the odds a
  memory will be needed, which follow recency, frequency and spacing of past
  use, in the same curves the environment shows. Storage outlasts access, and
  a fitting cue revives what seemed gone. People who remember everything are
  not wiser for it.
- **People cannot keep their memories true alone.** Retelling, suggestion,
  imagination and closeness blur what happened and who said what. People keep
  the past true through records and through each other. An agent can have
  what no person has, a verbatim record. The rule that follows: the record
  never changes; meaning, feeling and gist are rebuilt on top of it; and any
  claim about the shared past must be checkable against it.
- **Knowing someone means holding their concerns and their story and
  following the items of their life.** Feeling known by a partner predicts
  satisfaction more than feeling one knows them. Confidence about a partner
  grows with time much faster than accuracy does.
- **Artificial agents converged on extract, store, retrieve and reflect, and
  they fail in the same places:** facts that changed, time, and admitting
  they do not know. A plain long context, or a folder of files, often matches
  an elaborate memory system on the public benchmarks.
- **The substrate they have is fine.** At thousands to low hundreds of
  thousands of items, exact search remains inexpensive (the measurements
  below include 8.4 ms for 100,000 1024-d vectors and 6.7 ms per bge query).
  bge-large-en-v1.5 has replaced MiniLM; facts that carry when they became
  and stopped being true remain an evidence-backed direction.
  Approximate vector indexes, vector databases, graph databases and
  multi-vector retrieval buy nothing measurable at this scale. The gains are
  in what is stored and when it is recalled.
- **Where the model sits:** the context window is working memory (small in
  practice, distractible, unable to set aside superseded facts it can see).
  The weights are semantic knowledge of the world with no record of their life.
  Episodic and autobiographical memory are theirs to carry, and the
  hippocampus suggests the form: an *index* of what mattered, pointing at the
  record of what happened. Cares can be that index.

---

## 1. Encoding: what gets kept

### Most of experience is never stored

**Attention is the gate.** Dividing attention at encoding sharply reduces
later memory; dividing it at retrieval costs much less
([Craik et al. 1996](https://doi.org/10.1037/0096-3445.125.2.159)). Attention
and memory share machinery, and memory in turn steers attention toward what
mattered before ([Chun & Turk-Browne 2007](https://doi.org/10.1016/j.conb.2007.03.005)).
*[replicated]*

**Experience is cut into events.** People segment experience into events
where their predictions about what comes next break down. Memory updates at
the boundaries and is better integrated within an event than across one
([Zacks et al. 2007](https://doi.org/10.1037/0033-2909.133.2.273)). Brain
activity stays stable within an event and shifts at its boundary, where the
hippocampus responds most, and that response predicts later memory
([Baldassano et al. 2017](https://doi.org/10.1016/j.neuron.2017.06.041)).
*[replicated]* The unit of memory is neither the message nor the session. It
is the event, and an event ends where expectation changes.

**Conversation is mostly lost within minutes.** Memory for one's own natural
conversation is sparse even shortly afterwards
([Stafford & Daly 1984](https://doi.org/10.1111/j.1468-2958.1984.tb00024.x)).
Exact wording is lost within seconds while meaning is kept
([Sachs 1967](https://doi.org/10.3758/BF03208784)). What survives verbatim is
what carried interpersonal weight: in real faculty conversations, jokes,
put-downs and remarks about the relationship were remembered word for word
far better than neutral remarks
([Keenan, MacWhinney & Mayhew 1977](https://doi.org/10.1016/S0022-5371(77)80018-2)).
*[replicated]*

### Depth, relative to use

**Meaning beats surface.** Processing for meaning gives much better memory
than processing sound or appearance
([Craik & Lockhart 1972](https://doi.org/10.1016/S0022-5371(72)80001-X);
[Craik & Tulving 1975](https://doi.org/10.1037/0096-3445.104.3.268)). But
depth is relative to the later test: rhyme processing wins when the test is
about rhymes ("transfer-appropriate processing",
[Morris, Bransford & Franks 1977](https://doi.org/10.1016/S0022-5371(77)80016-9)).
*[replicated]*

**The self is the deepest level.** Judging whether a word describes oneself
gives better memory than judging its meaning
([Rogers, Kuiper & Kirker 1977](https://doi.org/10.1037/0022-3514.35.9.677)),
mostly because of elaboration around a well-developed self structure
([Symons & Johnson 1997](https://doi.org/10.1037/0033-2909.121.3.371)). A
close other gives a smaller version of the same benefit. *[meta-analytic]*

### Emotional arousal: a multiplier on priority

**Arousal strengthens consolidation.** Stress hormones and the amygdala act
on the hippocampus after an arousing event, so emotional events are
remembered better, especially after a delay
([McGaugh 2004](https://doi.org/10.1146/annurev.neuro.27.070203.144157);
[LaBar & Cabeza 2006](https://doi.org/10.1038/nrn1825)). The gain is
strongest for central details and can cost peripheral ones
([Kensinger 2009](https://doi.org/10.1177/1754073908100432)), and negative
emotion preserves more specific detail than positive
([Kensinger 2007](https://doi.org/10.1111/j.1467-8721.2007.00506.x)).
*[replicated]*

**Arousal amplifies whatever has priority.** In the arousal-biased
competition account, arousal strengthens whatever is winning the competition
for attention, because it is salient or because goals give it priority, and
weakens what is losing ([Mather & Sutherland 2011](https://doi.org/10.1177/1745691611400234)).
In the cleanest test, an arousing picture *improved* memory for the item just
before it when that item had been given priority, and *impaired* memory for
it when it had not ([Sakaki, Fryer & Mather 2014](https://doi.org/10.1177/0956797613504784)).
*[replicated, mostly by one group]* This is the empirical basis for salience
as charge *times* relevance: charge without relevance does not protect a
memory and can cost it.

**What it hurt outlasts when and where.** Emotion binds an item tightly to
its significance while its link to context fades faster
([Yonelinas & Ritchey 2015](https://doi.org/10.1016/j.tics.2015.02.009)).
*[theory, with supporting data]*

**Vivid is not accurate.** Flashbulb memories of shocking events lose
consistency at the same rate as ordinary memories; only the confidence stays
high ([Talarico & Rubin 2003](https://doi.org/10.1111/1467-9280.02453)). Ten
years after 9/11, memory for personal circumstances had drifted and
confidence did not track the drift
([Hirst et al. 2015](https://doi.org/10.1037/xge0000055)). *[replicated]*

### Goals and value decide what is kept

**Perspective at encoding and at recall.** Readers taking a burglar's
perspective on a story about a house remembered different details from
readers taking a home buyer's. Switching perspective at recall recovered
details they had not reported
([Pichert & Anderson 1977](https://doi.org/10.1037/0022-0663.69.4.309);
[Anderson & Pichert 1978](https://doi.org/10.1016/S0022-5371(78)90485-1)).
*[replicated]* The current goal shapes what goes in and what comes out, and
what was encoded under one goal can be reached through another.

**Value, reward, curiosity.** People selectively remember high-value
information, through strategic and automatic routes
([Knowlton & Castel 2022](https://doi.org/10.1146/annurev-psych-032921-050951)).
Anticipated reward ([Adcock et al. 2006](https://doi.org/10.1016/j.neuron.2006.03.036))
and curiosity ([Gruber, Gelman & Ranganath 2014](https://doi.org/10.1016/j.neuron.2014.08.060))
engage dopaminergic regions that boost hippocampal encoding, curiosity even
for incidental material met in the curious state. *[replicated]*

**Surprise.** Reward prediction errors improve memory for the surprising
outcome ([Rouhani, Norman & Niv 2018](https://doi.org/10.1037/xlm0000518)).
*[replicated]* The same signal that ends an event helps keep it.

### Significance reaches backwards

In synaptic tagging, a weak trace sets a temporary tag, and a strong event
shortly afterwards makes the tagged trace last
([Frey & Morris 1997](https://doi.org/10.1038/385533a0)). Humans show a
behavioural version. People saw neutral pictures from two categories; then
one category was paired with shock. Memory was better for the *earlier*
neutral pictures from the category that later became significant
([Dunsmoor et al. 2015](https://doi.org/10.1038/nature14106)). Reward does
the same for related earlier items
([Patil et al. 2017](https://doi.org/10.1101/lm.042978.116)).
*[few studies, consistent]*

The consequence is large. Importance cannot be scored once, when a thing is
stored. A remark that meant nothing on Tuesday can become the key to Friday,
and that only works if Tuesday's remark is still there to be reached.

### Using a memory makes it

**Retrieval strengthens.** Retrieving something strengthens it more than
restudying does, and the gap widens with delay
([Roediger & Karpicke 2006](https://doi.org/10.1111/j.1467-9280.2006.01693.x);
[Karpicke & Roediger 2008](https://doi.org/10.1126/science.1152408)), by about
half a standard deviation in meta-analyses
([Rowland 2014](https://doi.org/10.1037/a0037559);
[Adesope et al. 2017](https://doi.org/10.3102/0034654316689306)).
*[meta-analytic]*

**Generating strengthens.** Producing an item oneself beats reading it
([Slamecka & Graf 1978](https://doi.org/10.1037/0278-7393.4.6.592)), by about
0.4 standard deviations ([Bertsch et al. 2007](https://doi.org/10.3758/BF03193441)),
and saying it aloud helps too
([MacLeod et al. 2010](https://doi.org/10.1037/a0018785)). *[meta-analytic]*

**Spacing.** Spread repetitions beat massed ones
([Cepeda et al. 2006](https://doi.org/10.1037/0033-2909.132.3.354)), and the
best gap grows with how long the memory must last
([Cepeda et al. 2008](https://doi.org/10.1111/j.1467-9280.2008.02209.x)).
*[meta-analytic]*

What a mind reconstructs, uses and says becomes part of it. What merely
passes in front of it does not.

**Mechanism for an agent:** Encoding is selective, and the selection has
three inputs: what the agent was engaged with, emotional charge, and
relevance to what it cares about, with charge acting as a multiplier on
relevance rather than a bonus. Surprise marks both event boundaries and
things worth keeping, so the unit is the event, cut where expectations
changed. Significance is revisable: something that becomes important later
must be able to strengthen related earlier material, which therefore has to
stay reachable after its moment. What the agent itself retrieves, says and
uses grows stronger; what it only saw does not.

---

## 2. Consolidation: what lasting memory becomes

### Two speeds of learning

Synaptic consolidation stabilises a trace over hours. Systems consolidation
reorganises it over days to years, shifting it from the hippocampus toward
the neocortex ([McGaugh 2000](https://doi.org/10.1126/science.287.5451.248);
[Squire et al. 2015](https://doi.org/10.1101/cshperspect.a021766)).
*[replicated]*

**Why two systems exist.** A system that learns structure across many
experiences must learn slowly and interleaved, or each new experience
overwrites old knowledge. So a second system learns single episodes fast and
replays them, interleaved with older ones, for the slow one to absorb
(complementary learning systems:
[McClelland, McNaughton & O'Reilly 1995](https://doi.org/10.1037/0033-295X.102.3.419);
[Kumaran, Hassabis & McClelland 2016](https://doi.org/10.1016/j.tics.2016.05.004)).
The damage avoided is the catastrophic interference seen when networks are
trained on new items alone
([McCloskey & Cohen 1989](https://doi.org/10.1016/S0079-7421(08)60536-8);
[French 1999](https://doi.org/10.1016/S1364-6613(99)01294-2)). *[theory,
widely supported]* A language model is exactly this case: its weights are the
slow system, and there is no fast system unless the agent supplies one.

### What transfers is the gist

The standard model says consolidated memories stop needing the hippocampus.
Multiple trace theory and its successor, trace transformation theory, say
that holds only for the semantic gist. Vivid episodic detail stays
hippocampus-dependent for as long as it exists, and most memories transform
over time from detailed episodes into schematic versions
([Nadel & Moscovitch 1997](https://doi.org/10.1016/S0959-4388(97)80010-4);
[Winocur & Moscovitch 2011](https://doi.org/10.1017/S1355617711000683);
[Moscovitch et al. 2016](https://doi.org/10.1146/annurev-psych-113011-143733)).
*[debated; transformation is now the majority view for episodic detail]*

Gist and verbatim are separate traces. Verbatim fades faster, so with time
people lean on gist and "remember" things that fit the meaning but were never
said ([Brainerd & Reyna 2002](https://doi.org/10.1111/1467-8721.00192)).
*[replicated]*

### Schemas speed it up, and distort

Rats that had learned a spatial schema learned new flavour–place pairs in one
trial, and those memories stopped needing the hippocampus within 48 hours
instead of weeks ([Tse et al. 2007](https://doi.org/10.1126/science.1135935)).
In humans the medial prefrontal cortex supports fast integration of
schema-congruent information, while novel, schema-inconsistent information
leans on the hippocampus
([van Kesteren et al. 2012](https://doi.org/10.1016/j.tins.2012.02.001);
[Gilboa & Marlatte 2017](https://doi.org/10.1016/j.tics.2017.04.013)).
*[replicated]* The same schema fills gaps with the expected: retold stories
drift toward what the teller's culture expects (Bartlett 1932, *Remembering*).

### Sleep and quiet rest

**Replay is real.** Hippocampal cells that fired together on a track fire
together again in later sleep
([Wilson & McNaughton 1994](https://doi.org/10.1126/science.8036517)),
coordinated with visual cortex
([Ji & Wilson 2007](https://doi.org/10.1038/nn1825)). *[replicated]*

**Sleep helps, moderately.** Slow-wave sleep replays recent memories into
neocortical networks ([Diekelmann & Born 2010](https://doi.org/10.1038/nrn2762);
[Rasch & Born 2013](https://doi.org/10.1152/physrev.00032.2012)). A large
meta-analysis found a robust, moderate sleep benefit for episodic memory,
strongly moderated by how memory was tested
([Berres & Erdfelder 2021](https://doi.org/10.1037/bul0000350)).
*[meta-analytic]* But the claim that *more* slow-wave sleep means *more*
consolidation failed in 929 people
([Ackermann et al. 2015](https://doi.org/10.5665/sleep.4748); see
[Cordi & Rasch 2021](https://doi.org/10.1016/j.conb.2020.06.002)).
*[failed replication for dose-response]*

**What is replayed is what is kept.** Sounds linked to learned items, played
during non-REM sleep, improve memory for those items
([Rudoy et al. 2009](https://doi.org/10.1126/science.1179013);
meta-analysis [Hu et al. 2020](https://doi.org/10.1037/bul0000223), no effect
in REM). *[meta-analytic]* People told they would be tested later benefited
from sleep; people not told did not
([Wilhelm et al. 2011](https://doi.org/10.1523/JNEUROSCI.3575-10.2011)). Sleep
keeps what is tagged as relevant to the future and extracts the gist
([Stickgold & Walker 2013](https://doi.org/10.1038/nn.3303)), and it can
expose hidden structure ([Wagner et al. 2004](https://doi.org/10.1038/nature02223)).
*[replicated for future relevance; few studies for insight]* Whether sleep
increases gist-based false memories is unsettled
([Newbury & Monaghan 2019](https://doi.org/10.3758/s13423-018-1528-4)), and
whether it strips emotional charge is contested (PERSONALITY_RESEARCH.md,
section 4). *[debated]*

**Quiet waking rest consolidates too.** Brief rest after learning improves
retention compared with another task
([Dewar et al. 2012](https://doi.org/10.1177/0956797612441220)), and
hippocampal–cortical coupling during rest predicts later memory
([Tambini, Ketz & Davachi 2010](https://doi.org/10.1016/j.neuron.2010.01.001)).
*[replicated]* Consolidation happens in every gap not filled with new input.

### Time

Ebbinghaus's curve, steep then flat, replicates
([Murre & Dros 2015](https://doi.org/10.1371/journal.pone.0120644)). Across a
century of data retention follows a power function or close to it
([Rubin & Wenzel 1996](https://doi.org/10.1037/0033-295X.103.4.734);
[Wixted 2004](https://doi.org/10.1146/annurev.psych.55.090902.141555)), so the
older a memory already is, the more slowly it is lost. *[meta-analytic]*

**Mechanism for an agent:** The agent needs two speeds. A fast store keeps
episodes as they happened. A slow process, run offline and in quiet gaps,
replays recent episodes interleaved with older related ones and folds them
into general knowledge of the person, of itself and of how things go. It
keeps what is tagged as mattering for the future and lets the rest lose
accessibility. What fits a schema is absorbed quickly; what violates one
needs its episode kept longer, and is where learning happens. The resulting
gist is a separate, derived layer with its own errors (it fills in the
expected), so the episode it came from has to stay reachable. Recent memory
is fragile and decides most of what is lost; memory that has survived is
durable.

---

## 3. Retrieval: how the past comes back

### Stored is not reachable

**Availability and accessibility.** Given category names as cues, people
recalled many words they had failed to recall without them
([Tulving & Pearlstone 1966](https://doi.org/10.1016/S0022-5371(66)80048-8)).
Much "forgetting" is failure to reach what is still there. *[replicated]*

**Encoding specificity.** A cue helps only if it was part of how the memory
was encoded; a strong associate can fail where a weak one present at study
succeeds ([Tulving & Thomson 1973](https://doi.org/10.1037/h0020071)). Divers
recalled better in the setting where they learned, underwater or on land
([Godden & Baddeley 1975](https://doi.org/10.1111/j.2044-8295.1975.tb01468.x)).
Context effects are real but modest, larger when the context is mentally
reinstated, smaller when other strong cues are present
([Smith & Vela 2001](https://doi.org/10.3758/BF03196157)). *[meta-analytic]*

**The cue must single the memory out.** What predicts retrieval is not how
much a cue overlaps with a memory but how well it distinguishes that memory
from competitors; a cue matching many memories helps none
([Nairne 2002](https://doi.org/10.1080/09658210244000216)). *[theory, with
data]* The fan effect is the measured version: the more facts attach to a
concept, the slower and less reliable retrieval of any one
([Anderson 1974](https://doi.org/10.1016/0010-0285(74)90021-8)). *[replicated]*

**Similarity reminds; structure reasons.** People are reminded of past cases
mostly by surface similarity but reason well only from cases that share deep
structure, two separate processes
([Gentner, Rattermann & Forbus 1993](https://doi.org/10.1006/cogp.1993.1013);
[Forbus, Gentner & Law 1995](https://doi.org/10.1207/s15516709cog1902_1)).
*[replicated]* Embedding similarity is the first process. Relevance to the
present problem is the second.

### Links and time

Retrieving a concept makes its associates more available, in proportion to
link strength ([Collins & Loftus 1975](https://doi.org/10.1037/0033-295X.82.6.407)).
In free recall, the next item recalled tends to be one studied close in time
to the last, forward more than backward
([Kahana 1996](https://doi.org/10.3758/BF03197276)), because each memory is
bound to a drifting context and recalling it brings the context back
([Howard & Kahana 2002](https://doi.org/10.1006/jmps.2001.1388);
[Polyn, Norman & Kahana 2009](https://doi.org/10.1037/a0014420)).
*[replicated]* Recalling one moment of an evening brings back the evening.

### Two routes into autobiographical memory

**Generative.** Deliberate recall of a personal memory descends a hierarchy,
from a lifetime period to a general event to the specific episode, steered by
the working self ([Conway & Pleydell-Pearce 2000](https://doi.org/10.1037/0033-295X.107.2.261)).
**Direct.** Many memories come straight from a cue, without search
([Uzer, Lee & Brown 2012](https://doi.org/10.1037/a0028142)). *[replicated]*

**Involuntary memories are the commoner kind.** In diaries, memories that come
unbidden outnumber deliberate ones
([Rasmussen & Berntsen 2011](https://doi.org/10.1016/j.concog.2011.07.010)).
They are triggered by a cue in the present that overlaps a central feature of
the past event, arise mostly in unfocused states, and are more specific and
more emotional than deliberate ones
([Berntsen 1996](https://doi.org/10.1002/(SICI)1099-0720(199610)10:5%3C435::AID-ACP408%3E3.0.CO;2-L);
[Berntsen 2010](https://doi.org/10.1177/0963721410370301)). One often sets
off a chain of others ([Mace 2014](https://doi.org/10.3389/fpsyt.2014.00183)).
*[replicated]* Schank argued that being reminded is set off by expectation
failure, and is how generalisations get revised (Schank 1982, *Dynamic
Memory*). *[theory]* "That reminds me" is the conversational face of it
(PERSONALITY_RESEARCH.md, section 6).

### Retrieval reshapes what it leaves behind

Practising retrieval of some items from a category makes the unpractised
items of that category harder to recall later
([Anderson, Bjork & Bjork 1994](https://doi.org/10.1037/0278-7393.20.5.1063);
meta-analysis [Murayama et al. 2014](https://doi.org/10.1037/a0037505)), by
inhibition or by competition
([Raaijmakers & Jakab 2013](https://doi.org/10.1016/j.jml.2012.10.002)).
*[meta-analytic; mechanism debated]* It spreads to listeners: when a speaker
recounts part of a shared memory, listeners forget the unmentioned related
parts ([Cuc, Koppel & Hirst 2007](https://doi.org/10.1111/j.1467-9280.2007.01967.x);
[Coman, Manier & Hirst 2009](https://doi.org/10.1111/j.1467-9280.2009.02343.x)).
*[replicated]* What the agent brings up about the shared past shapes what the
person keeps of it.

### Knowing that you know

**Tip of the tongue and feeling of knowing.** People can report a word's
first letter without being able to say it
([Brown & McNeill 1966](https://doi.org/10.1016/S0022-5371(66)80040-3);
[Brown 1991](https://doi.org/10.1037/0033-2909.109.2.204)), and predict above
chance whether they will recognise an answer they cannot recall
([Hart 1965](https://doi.org/10.1037/h0022263)). The feeling comes from cue
familiarity and partial access, not from the memory itself
([Koriat 1993](https://doi.org/10.1037/0033-295X.100.4.609);
[Reder & Ritter 1992](https://doi.org/10.1037/0278-7393.18.3.435)). It is
fast, arrives before content and decides whether to search or give up
([Nelson & Narens 1990](https://doi.org/10.1016/S0079-7421(08)60053-5)), and
familiar cues fool it. *[replicated]*

**Familiar is not recollected.** Recognition rests on a fast sense of
familiarity and a slower recollection of when and where
([Yonelinas 2002](https://doi.org/10.1006/jmla.2002.2864)). *[replicated;
dual-process reading debated]* "That sounds familiar" and "I remember when
you said that" are different claims, and only the second carries a source.

Recall leans a little toward the current mood
([Bower 1981](https://doi.org/10.1037/0003-066X.36.2.129); mood-*dependent*
memory is weak, [Eich 1995](https://doi.org/10.1111/j.1467-9280.1995.tb00309.x)).
*[replicated, small]*

**Mechanism for an agent:** Retrieval is cue-driven, and most of what a mind
knows is reachable only through the right cue. Cues work when they single a
memory out, so recall needs cheap similarity search followed by a judgment of
relevance. The richest cues are what the agent cares about now, the person's
words, the time and setting, and the neighbours in time of whatever was just
recalled. Most remembering should be involuntary, set off by overlap between
the present and a charged past, arriving first as a felt "I know something
about this". Recall has costs: what returns grows stronger and its competitors
weaker, in the agent and in the listener. Familiarity is not recollection of
where something came from.

---

## 4. Reconstruction, reconsolidation and the truth of what happened

### Remembering is rebuilding

**Constructive by design.** Schacter's "seven sins" of memory (transience,
absent-mindedness, blocking, misattribution, suggestibility, bias,
persistence) are by-products of a system built to extract gist, generalise
and imagine ([Schacter 1999](https://doi.org/10.1037/0003-066X.54.3.182)). The
machinery that recombines the past to imagine the future also recombines it
wrongly ([Schacter & Addis 2007](https://doi.org/10.1098/rstb.2007.2087);
[Schacter, Guerin & St. Jacques 2011](https://doi.org/10.1016/j.tics.2011.08.004)).
*[theory, widely supported]*

**But the core of real events is mostly right.** People who took a recorded
real-world tour and recalled it days to years later were 93 to 95% accurate
in the details they did report, at every age and delay; what declined was
how much they reported ([Diamond, Armson & Levine 2020](https://doi.org/10.1177/0956797620954812)).
*[few studies, careful design]* Human errors are mostly omission, filled-in
detail and misattribution, not invention of the core.

### Reconsolidation: does recall reopen the trace?

**In animals, yes.** A reactivated fear memory became vulnerable again to a
protein-synthesis blocker and had to be stored anew
([Nader, Schafe & LeDoux 2000](https://doi.org/10.1038/35021052);
[Nader & Hardt 2009](https://doi.org/10.1038/nrn2590)), but only when
retrieval involved a prediction error
([Sevenster, Beckers & Kindt 2013](https://doi.org/10.1126/science.1231357)).
*[replicated in animals]*

**In human episodic memory, shakier.** A reminder before new learning made
new items intrude into an old list in one influential study
([Hupbach et al. 2007](https://doi.org/10.1101/lm.365707)). Direct
replications have failed: four replications of a classic motor-memory
reconsolidation study found no effect
([Hardwicke, Taqi & Shanks 2016](https://doi.org/10.1073/pnas.1601440113)),
and a preregistered replication of the celebrated finding that extinction in
the reconsolidation window erases human fear found no benefit, with a
companion report finding the original's exclusions misreported
([Chalkia et al. 2020](https://doi.org/10.1016/j.cortex.2020.04.017); original
[Schiller et al. 2010](https://doi.org/10.1038/nature08637); review
[Lee, Nader & Schiller 2017](https://doi.org/10.1016/j.tics.2017.04.006)).
*[debated in humans; key replications failed]* What does not depend on this
biology is the behavioural fact below.

### Retelling rewrites

**Retelling is not recalling.** Retelling an event for a purpose (to amuse,
persuade, complain) selects, exaggerates and adds interpretation, and later
memory shifts toward the retelling
([Tversky & Marsh 2000](https://doi.org/10.1006/cogp.1999.0720);
[Marsh 2007](https://doi.org/10.1111/j.1467-8721.2007.00467.x)). Tailoring a
description to a listener shifts the speaker's own memory toward the
listener's view when the speaker wants a shared reality with them
([Echterhoff, Higgins & Levine 2009](https://doi.org/10.1111/j.1745-6924.2009.01161.x)).
*[replicated]*

**Retellings drift toward attractors.** Bartlett's serial reproduction drifts
toward the conventional. Chains of language models rewriting each other's
text converge on attractors that depend on the model, not the original
([Perez et al. 2024](https://arxiv.org/abs/2407.04503)), and models trained
recursively on their own output lose the tails of the original distribution
([Shumailov et al. 2024](https://doi.org/10.1038/s41586-024-07566-y)).
*[replicated in people; few studies in models]* A summary of a summary is a
retelling, and it drifts.

### Suggestion and false memory

- **Misinformation.** Asking how fast cars "smashed" rather than "hit" raised
  speed estimates and produced reports of broken glass that was not there
  ([Loftus & Palmer 1974](https://doi.org/10.1016/S0022-5371(74)80011-3);
  thirty-year review [Loftus 2005](https://doi.org/10.1101/lm.94705)).
  *[replicated]*
- **Whole false events.** About a quarter of participants came to remember
  being lost in a mall as a child after a relative "confirmed" it
  ([Loftus & Pickrell 1995](https://doi.org/10.3928/0048-5713-19951201-07));
  a preregistered replication with five times the sample found 35%
  ([Murphy et al. 2023](https://doi.org/10.1080/09658211.2023.2198327)). A
  mega-analysis of eight implantation studies classed 30% of cases as false
  memories, more when the suggestion was self-relevant and imagined
  ([Scoboria et al. 2017](https://doi.org/10.1080/09658211.2016.1260747)); a
  stricter review put full false memories nearer 15%
  ([Brewin & Andrews 2017](https://doi.org/10.1002/acp.3220)). *[replicated;
  rate depends on definition]*
- **Imagination inflation.** Imagining an event that did not happen raises
  confidence that it did ([Garry et al. 1996](https://doi.org/10.3758/BF03212420)).
  *[replicated]*
- **Associative intrusions.** After "bed, rest, awake, tired, dream...",
  people confidently recall "sleep", never presented
  ([Roediger & McDermott 1995](https://doi.org/10.1037/0278-7393.21.4.803)).
  *[replicated, very robust]*
- **Social contagion.** People later report items a partner wrongly mentioned
  while recalling a scene together
  ([Roediger, Meade & Bergman 2001](https://doi.org/10.3758/BF03196174);
  [Gabbert, Memon & Allan 2003](https://doi.org/10.1002/acp.885)).
  *[replicated]*
- **A conversational AI is a strong source of suggestion.** Witnesses
  interviewed by an LLM chatbot that slipped in misleading questions formed
  about three times as many immediate false memories as controls; 36% of
  their responses were misled, and a week later the false memories had not
  faded and were held with more confidence than controls'
  ([Chan et al. 2024](https://arxiv.org/abs/2408.04681), with Loftus).
  *[few studies]* An agent that misremembers the shared past and says so with
  assurance can implant its error in the person.

### Who said it

**Source is inferred, not read off.** People judge where a memory came from
(seen or imagined, said by me or by you) from its features at retrieval:
perceptual detail, context, the operations it carries
([Johnson & Raye 1981](https://doi.org/10.1037/0033-295X.88.1.67);
[Johnson, Hashtroudi & Lindsay 1993](https://doi.org/10.1037/0033-2909.114.1.3);
[Mitchell & Johnson 2009](https://doi.org/10.1037/a0015849)). People
unknowingly take others' ideas as their own
([Brown & Murphy 1989](https://doi.org/10.1037/0278-7393.15.3.432)), and each
partner in a joint activity recalls doing more of it than the other credits
([Ross & Sicoly 1979](https://doi.org/10.1037/0022-3514.37.3.322)).
*[replicated]* Closeness may blur self and other further: people confused
traits rated for themselves with traits rated for a close partner more than
for a stranger ([Mashek, Aron & Boncimino 2003](https://doi.org/10.1177/0146167202250220)),
though a later study did not find it
([Rosa & Gutchess 2011](https://doi.org/10.1037/a0022827)). *[debated]*

**Confabulation is a filter failure.** Patients who spontaneously confabulate
are not lying. They fail to suppress memory traces that do not belong to the
present, a "reality filter" linked to orbitofrontal cortex
([Schnider 2003](https://doi.org/10.1038/nrn1179)). *[replicated in patients]*
A language model asked about a shared past it does not have does the same: it
produces the most plausible memory with no signal that it is not its own.

### Confidence, and the present rewriting the past

Confidence at a first, uncontaminated test is a strong indicator of accuracy;
confidence after feedback and retelling is not
([Wixted & Wells 2017](https://doi.org/10.1177/1529100616686966)).
*[replicated]* Current feelings about a partner reshape memory of earlier
feelings and impressions ([McFarland & Ross 1987](https://doi.org/10.1177/0146167287132008)),
and wives followed over years remembered past satisfaction as lower than they
had reported it, so the relationship seemed to improve
([Karney & Coombs 2000](https://doi.org/10.1177/01461672002610006)).
*[replicated]*

**Mechanism for an agent:** Human memory serves correspondence (what
happened) and coherence (what fits the current self), and coherence often
wins (section 6). People do not keep memory true internally: every retrieval
reconstructs, retelling shifts the memory toward the telling, others'
suggestions are absorbed, sources blur, and confidence grows while accuracy
does not. What keeps human memory honest is outside the head, in records and
other people. An agent can hold a record of what really happened. It follows
that:

- the record is never rewritten by recall, retelling or consolidation;
- every reconstruction (gist, summary, felt meaning, story) is stored as a
  reconstruction, pointing at the record it came from;
- every item carries its source (who said it, when, in which exchange);
- confidence comes from the first encoding and the record, not from how
  often something has been retold;
- "remembered", "inferred" and "familiar" are kept apart;
- the agent's own claims about the shared past are suggestion to the person,
  so they have to be the checked ones.

---

## 5. Forgetting as a feature

### Why memories become unreachable

**Interference, mostly.** Time alone does not cause forgetting; what happens
in that time does ([McGeoch 1932](https://doi.org/10.1037/h0069819)). Much
lab forgetting comes from *proactive* interference by earlier learning
([Underwood 1957](https://doi.org/10.1037/h0044616)), and new learning
interferes most with memories not yet consolidated
([Wixted 2004](https://doi.org/10.1146/annurev.psych.55.090902.141555)).
*[replicated]* The brain also forgets on purpose, through regulated processes
that weaken traces ([Hardt, Nader & Nadel 2013](https://doi.org/10.1016/j.tics.2013.01.001);
[Davis & Zhong 2017](https://doi.org/10.1016/j.neuron.2017.05.039)).
*[replicated in animals]*

**Unreachable is not erased.** In amnesic mice, the cells that held a memory
could still be activated directly with light, bringing the memory back
([Ryan et al. 2015](https://doi.org/10.1126/science.aaa5542)); forgetting is
better described as engrams becoming less accessible, an adaptive and
reversible change ([Ryan & Frankland 2022](https://doi.org/10.1038/s41583-021-00548-3)).
*[replicated in animals]* Bjork's "new theory of disuse" says the same in
behavioural terms. Storage strength (how well learned) only grows; retrieval
strength (how reachable now) rises with use and falls with disuse.
Relearning is fast because storage was never lost, and retrieving something
when it is hard to reach strengthens it most (Bjork & Bjork 1992, in *From
Learning Processes to Cognitive Processes*). *[theory, consistent with the
spacing and testing data]*

### Forgetting matches the world

Anderson treated memory as answering a statistical question: given its
history of use, how likely is this item to be needed now?
([Anderson & Milson 1989](https://doi.org/10.1037/0033-295X.96.4.703)).
Anderson and Schooler then measured need in three environments: words in
*New York Times* headlines, words in speech to children, and the senders of
Anderson's email. In all three, the chance an item would be needed again fell
as a power function of time since last need and rose with frequency of past
need, in the same shapes as human forgetting, practice and spacing
([Anderson & Schooler 1991](https://doi.org/10.1111/j.1467-9280.1991.tb00174.x);
[Schooler & Anderson 1997](https://doi.org/10.1006/cogp.1997.0652)). Public
attention to cultural items decays the same way
([Candia et al. 2019](https://doi.org/10.1038/s41562-018-0474-5)).
*[replicated; the interpretation is theory]*

ACT-R's base-level activation puts it in one formula: the log of a sum over
every past use, each decaying as a power of its age, B = ln(Σ t_j^−d) with d
near 0.5. It yields recency, frequency and spacing together and predicts real
vocabulary learning well ([Pavlik & Anderson 2005](https://doi.org/10.1207/s15516709cog0000_14)).
*[replicated]* Forgetting is not a defect to minimise. It is the memory's
estimate of need, and a good one.

### Forgetting on purpose

Telling people to forget particular items right after seeing them reliably
reduces later memory for them; the whole-list version works through context
change and is weaker ([Sahakyan et al. 2013](https://doi.org/10.1016/B978-0-12-407187-2.00004-6)).
*[replicated]* Repeatedly stopping a cued memory from coming to mind (the
think/no-think task) made it harder to recall
([Anderson & Green 2001](https://doi.org/10.1038/35066572)); an early
replication failed ([Bulevich et al. 2006](https://doi.org/10.3758/BF03195920)),
and a focused meta-analysis found a small effect (d ≈ 0.28) likely inflated
by publication bias ([Stramaccia et al. 2021](https://doi.org/10.1037/xge0000971);
theory [Anderson & Hulbert 2021](https://doi.org/10.1146/annurev-psych-072720-094140)).
*[debated; small]*

### What forgetting buys

- **Generalisation.** Forgetting detail lets a mind generalise and adapt when
  the world changes, as regularisation keeps a network from overfitting
  ([Richards & Frankland 2017](https://doi.org/10.1016/j.neuron.2017.04.037)).
  Less outdated material also means faster, less effortful retrieval of what
  is current ([Nørby 2015](https://doi.org/10.1177/1745691615596787)).
  *[theory, with data]*
- **Total recall is not wisdom.** People with highly superior
  autobiographical memory recall nearly every day of their adult lives
  ([Parker, Cahill & McGaugh 2006](https://doi.org/10.1080/13554790500473680);
  [LePort et al. 2012](https://doi.org/10.1016/j.nlm.2012.05.002)). They are
  not better at ordinary memory tasks, lean toward obsessive organisation,
  and form false memories like anyone
  ([Patihis et al. 2013](https://doi.org/10.1073/pnas.1314373110)).
  *[few studies]* Luria's mnemonist, who forgot almost nothing, struggled
  with abstraction (Luria 1968, *The Mind of a Mnemonist*).
- **Feelings fade unevenly.** Negative feeling fades faster than positive,
  faster again when shared with a responsive listener
  (PERSONALITY_RESEARCH.md, section 4). *[replicated]*

**Language models cannot forget what they can see.** Given a stream of
updates to the same key in context, models' accuracy at reporting the latest
value falls roughly log-linearly toward zero as superseded values accumulate,
even with the answer just before the question, and telling the model to
ignore old values helps little ([Wang & Sun 2025](https://arxiv.org/abs/2506.08184)).
*[few studies]* A superseded fact has to be taken out of what the model sees,
not just marked old.

**Mechanism for an agent:** Forgetting is a loss of accessibility, not of
storage. Accessibility tracks the odds of need, built from the history of
use (how recently, often and spaced a memory was needed: a power-law sum over
uses), raised by what the agent cares about. A fitting cue revives what has
faded, cheaply, and revival strengthens more than routine use. Superseded
facts drop out of what the model is shown. Deliberate forgetting (the person
asks, or something is wrong) is a different act from fading: it removes the
material from every reachable form. Forgetting detail is what lets the agent
generalise; keeping everything equally reachable would make it worse.

---

## 6. Kinds of memory, the self, and remembering to do things

### Episodic, semantic, procedural

Tulving separated episodic memory (events in one's own past, remembered *as
me, then*) from semantic memory (facts detached from when they were learned)
([Tulving 1985](https://doi.org/10.1037/h0080017);
[Tulving 2002](https://doi.org/10.1146/annurev.psych.53.100901.135114)).
H.M., after hippocampal surgery, formed no new episodic memories but learned
motor skills normally ([Scoville & Milner 1957](https://doi.org/10.1136/jnnp.20.1.11)),
and amnesic patients learn perceptual skills without remembering the
practice ([Cohen & Squire 1980](https://doi.org/10.1126/science.7414331);
taxonomy [Squire 2004](https://doi.org/10.1016/j.nlm.2004.06.005)).
*[replicated]*

**The boundary is porous.** Repeated episodes become semantic knowledge.
"Personal semantics" (facts about one's own life, knowledge of one's traits)
sits between the two ([Renoult et al. 2012](https://doi.org/10.1016/j.tics.2012.09.003);
[Renoult et al. 2019](https://doi.org/10.1016/j.tics.2019.09.008)). A patient in
temporary amnesia who could recall almost no episodes from their life still
described their own personality as they did after recovering
([Klein, Loftus & Kihlstrom 1996](https://doi.org/10.1037/0096-3445.125.3.250)).
*[replicated; few cases]* Knowing who one is and remembering what one did
are different stores; trait knowledge is kept as summary, not recomputed.

**Habits run on cues.** Repeating an action in a stable context until the
context triggers it makes a habit that runs with little regard for current
goals ([Wood & Rünger 2016](https://doi.org/10.1146/annurev-psych-122414-033417)),
and skills compile from slow rules into fast procedures with practice
([Anderson 1982](https://doi.org/10.1037/0033-295X.89.4.369)). *[replicated]*

**Working memory is tiny; experts extend it with cues.** It holds about four
chunks ([Cowan 2001](https://doi.org/10.1017/S0140525X01003922)), with an
"episodic buffer" binding long-term material into the current workspace
([Baddeley 2000](https://doi.org/10.1016/S1364-6613(00)01538-2)). Experts seem
to have vast working memory in their domain because they hold *retrieval
structures*, cues giving fast, reliable access to long-term memory
([Ericsson & Kintsch 1995](https://doi.org/10.1037/0033-295X.102.2.211)).
*[replicated]* The bottleneck is having the right cue in the workspace at the
right moment.

### The working self

**It controls memory.** Conway's self-memory system pairs an autobiographical
knowledge base (lifetime periods, general events, specific episodes) with a
*working self*, the current goals and self-images, which controls what is
encoded and how memories are rebuilt
([Conway & Pleydell-Pearce 2000](https://doi.org/10.1037/0033-295X.107.2.261);
[Conway 2005](https://doi.org/10.1016/j.jml.2005.08.005)), balancing
correspondence against coherence
([Conway, Singer & Tagini 2004](https://doi.org/10.1521/soco.22.5.491.50768)).
In the later account, episodic memories are short-lived summary records of
recent experience, most lost within days; those that last stay linked to the
working self's goals ([Conway 2009](https://doi.org/10.1016/j.neuropsychologia.2009.02.003)).
*[theory, widely supported]* This is the strongest scientific support for
memory as what concerns leave behind: in Conway's view a concern is what
keeps an episode alive.

**A counterweight: experience has its own structure.** Transition theory
says autobiographical memory is organised largely by the structure of
experience (repetition, co-occurrence, major transitions) more than by the
self. Memories pile up around transitions, and people date events by them
([Brown et al. 2009](https://doi.org/10.1111/j.1467-9280.2009.02307.x)).
*[replicated]* Both are probably right: concerns decide what is kept,
transitions organise when it sits.

**Losing specifics is a symptom.** People with depression or trauma tend to
retrieve overgeneral memories ("I always fail exams") instead of episodes,
which predicts poorer problem-solving and a worse course
([Williams et al. 2007](https://doi.org/10.1037/0033-2909.133.1.122)).
*[meta-analytic]* A memory of gist alone is not neutral.

People use autobiographical memory to keep a continuous self, to bond, and to
direct behaviour ([Bluck, Alea, Habermas & Rubin 2005](https://doi.org/10.1521/soco.23.1.91.59198));
self-defining memories and the life story are in PERSONALITY_RESEARCH.md,
section 4.

### Prospective memory: remembering to do things later

**Event cues beat clocks.** Remembering to act at the right moment is its own
skill, with its own lab paradigm
([Einstein & McDaniel 1990](https://doi.org/10.1037/0278-7393.16.4.717)).
Intentions cued by an event (when I see their, ask about the interview) are
kept better than intentions cued by a time, which need self-initiated
checking ([Einstein et al. 1995](https://doi.org/10.1037/0278-7393.21.4.996)).
*[replicated]*

**Spontaneous retrieval or costly monitoring.** An intention comes back
either spontaneously, when a cue strongly linked to it appears, or through
strategic monitoring that taxes attention and slows other work
([McDaniel & Einstein 2000](https://doi.org/10.1002/acp.775);
[Smith 2003](https://doi.org/10.1037/0278-7393.29.3.347)). *[replicated; how
much monitoring is needed is debated]* "If X, then I will do Y" plans bind an
intention to a cue and improve follow-through with a medium-to-large effect
([Gollwitzer 1999](https://doi.org/10.1037/0003-066X.54.7.493);
[Gollwitzer & Sheeran 2006](https://doi.org/10.1016/S0065-2601(06)38002-1)).
*[meta-analytic]* Intended material stays more accessible than neutral
material ([Goschke & Kuhl 1993](https://doi.org/10.1037/0278-7393.19.5.1211)).
*[replicated]*

**Zeigarnik did not hold up; the urge to resume did.** The claim that
interrupted tasks are remembered better failed repeatedly
([Butterfield 1964](https://doi.org/10.1037/h0039873)). A 2025 meta-analysis
found no general memory advantage for unfinished tasks but a reliable
tendency to resume them, the Ovsiankina effect
([Ghibellini & Meier 2025](https://doi.org/10.1057/s41599-025-05000-w)).
*[failed replication for memory; meta-analytic for resumption]* Open loops
do not make memories stronger. They make the mind want to go back.

**Offloading.** People put intentions into the world when internal memory is
costly, and saving information externally frees memory for new material
([Risko & Gilbert 2016](https://doi.org/10.1016/j.tics.2016.07.002);
[Storm & Stone 2015](https://doi.org/10.1177/0956797614559285)). *[replicated]*
The "Google effect", remembering less of what one expects a computer to keep,
failed in a large multi-lab replication
([Sparrow, Liu & Wegner 2011](https://doi.org/10.1126/science.1207745);
[Camerer et al. 2018](https://doi.org/10.1038/s41562-018-0399-z)).
*[failed replication]*

**Mechanism for an agent:** The agent needs different kinds of memory, not
one store with labels. Episodes are kept as they happened. Personal
semantics about the person and about itself is summary knowledge, kept as
summary and surviving the episodes. Procedures compile from repeated success
and run on cues. A working self (current concerns and self-image) decides
what is kept and steers recall, while the structure of experience gives
memories their place in time. The agent must not slide into pure gist,
because specific episodes are what problem-solving and intimacy draw on.
Intentions are a fourth kind, held best when bound to a distinctive future
cue (a person, a topic, an event) rather than by monitoring. What persists of
unfinished things is the urge to return.

---

## 7. Memory between people

### Couples share a memory system

**Transactive memory.** Close partners split remembering, each knowing what
the other knows, so the pair forms one system
([Wegner, Giuliano & Hertel 1985](https://doi.org/10.1007/978-1-4612-5044-9_12)).
Real couples recalled more than paired strangers when they could use their
own division of labour, and less when one was imposed
([Wegner, Erber & Raymond 1991](https://doi.org/10.1037/0022-3514.61.6.923)),
and they retrieve by cueing each other
([Hollingshead 1998](https://doi.org/10.1037/0022-3514.74.3.659); review
[Ren & Argote 2011](https://doi.org/10.5465/19416520.2011.590300)).
*[replicated]*

**Remembering together.** Groups recall less than the same people recalling
alone and pooling, because they disrupt each other's retrieval strategies
([Weldon & Bellinger 1997](https://doi.org/10.1037/0278-7393.23.5.1160);
[Basden et al. 1997](https://doi.org/10.1037/0278-7393.23.5.1176)), but
collaboration prunes errors and individuals remember more afterwards
([Rajaram & Pereira-Pasarin 2010](https://doi.org/10.1177/1745691610388763);
meta-analysis [Marion & Thorley 2016](https://doi.org/10.1037/bul0000071)).
*[meta-analytic]* Among long-married older couples, some remembered shared
experiences much better together than apart; they were the ones who cued each
other, repeated and built on each other's contributions
([Harris et al. 2011](https://doi.org/10.1080/0163853X.2010.541854);
[Harris et al. 2014](https://doi.org/10.1177/1750698014530619);
[Barnier et al. 2018](https://doi.org/10.3389/fpsyg.2018.02385)).
*[replicated, small samples]* Shared remembering is a skill of the pair.

**Talking converges memories.** The wish for a shared reality changes what
the speaker remembers ([Higgins, Rossignac-Milon & Echterhoff 2021](https://doi.org/10.1177/0963721421992027)),
feeling of one mind predicts closeness
([Rossignac-Milon et al. 2021](https://doi.org/10.1037/pspi0000266)), and
conversation about a shared past converges both partners' memories through
selective retelling ([Hirst & Echterhoff 2012](https://doi.org/10.1146/annurev-psych-120710-100340);
[Hirst, Yamashiro & Coman 2018](https://doi.org/10.1016/j.tics.2018.02.010)).
*[replicated]*

### Common ground lives in ordinary memory

People keep no separate ledger of "what we both know". The partner is a
retrieval cue: thinking of a person makes what was shared with them more
accessible, and that associative memory is what common ground runs on
([Horton & Gerrig 2005](https://doi.org/10.1207/s15326950dp4001_1);
[Horton & Gerrig 2016](https://doi.org/10.1111/tops.12216);
[Brown-Schmidt & Duff 2016](https://doi.org/10.1111/tops.12224)).
*[replicated]* Patients with severe hippocampal amnesia built shared,
shrinking labels with a partner as fast as healthy people, though they could
not learn arbitrary word pairs ([Duff et al. 2006](https://doi.org/10.1038/nn1601)).
*[few studies]* Part of what a pair builds is procedural and semantic: a
private reference can outlive the episode it came from.

### What it means to know someone

**Three levels.** McAdams answered "what do we know when we know a person?"
with traits, personal concerns (the goals, projects and worries of this point
in their life), and their life story
([McAdams 1995](https://doi.org/10.1111/j.1467-6494.1995.tb00500.x)). Knowing
traits is knowing a stranger; knowing concerns and story is knowing someone.
*[theory, widely used]*

**Confidence outruns accuracy.** Longer, more involved relationships raised
confidence in impressions of the partner without consistently making them
more accurate ([Swann & Gill 1997](https://doi.org/10.1037/0022-3514.73.4.747)),
and people overestimate how well they communicate with friends compared with
strangers ([Savitsky et al. 2011](https://doi.org/10.1016/j.jesp.2010.09.005)).
*[replicated]* Long familiarity makes people feel they know someone, and stop
checking.

### Being remembered

**Feeling known matters more than knowing.** Across seven studies of
partners, friends, family and colleagues, believing the other knows you
predicted satisfaction more than believing you know them
([Schroeder & Fishbach 2024](https://doi.org/10.1016/j.jesp.2023.104559)).
*[few studies, consistent]* Responsiveness includes understanding, and
understanding includes getting the facts of one's life right (Reis & Shaver
1988; PERSONALITY_RESEARCH.md, section 5;
[Reis, Lemay & Finkenauer 2017](https://doi.org/10.1111/spc3.12308)).
Follow-up questions, which only someone who took in the answer can ask, carry
most of the liking effect of questions
([Huang et al. 2017](https://doi.org/10.1037/pspi0000097)), and asking about a
specific item in the other's life ("how did the interview go?") is a
conversational move only memory of them makes possible (PERSONALITY_RESEARCH.md,
section 6). Recalling shared relationship events raised intimacy in long-term
couples ([Alea & Bluck 2007](https://doi.org/10.1002/acp.1316)), and
nostalgia, usually about close others, raises felt connection
([Wildschut et al. 2006](https://doi.org/10.1037/0022-3514.91.5.975)). Part
of mattering is believing others notice and keep one in mind
([Elliott, Kao & Grant 2004](https://doi.org/10.1080/13576500444000119)).
*[replicated for responsiveness and follow-ups]*

**An honest gap.** No experiment I found manipulates whether a partner
remembers small details of one's life and measures closeness. The case is
convergent: strong in direction, indirect in proof.

**Mechanism for an agent:** Between people, memory is a joint system: each
partner holds part of it and knows what the other holds, and conversation
cues retrieval in both and converges what both keep. For an agent with one
person, the person is part of its memory system (they hold its past too and
can correct it); what the agent retells shapes what the person keeps; and the
person, with what they are talking about, should be the strongest cue for
what was shared with them. Knowing them means holding their current concerns
and their story and following the items of their life. Long familiarity
breeds confidence without accuracy, so the model of the person keeps being
checked against what they say now. What the person experiences as being known
is the right specific thing coming back at the right time.

---

## 8. Artificial agent memory: what earlier work got right and wrong

Not a template list. For each line of work: what it captured that the science
supports, and where it fell short. CoALA borrowed the cognitive taxonomy
directly: working memory (the context) plus long-term episodic, semantic and
procedural memory ([Sumers et al. 2024](https://arxiv.org/abs/2309.02427)). A
2026 survey frames nearly every system since 2022 as one write–manage–read
loop, with continual consolidation, learned forgetting and trustworthy
reflection still open ([arXiv 2603.07670](https://arxiv.org/abs/2603.07670)).

### The systems

- **Generative Agents** ([Park et al. 2023](https://doi.org/10.1145/3586183.3606763)).
  A memory stream ranked by recency (decay since last *access*), importance
  (a 1–10 score the model gives each memory when written) and relevance
  (embedding similarity). When recent importance adds up past a threshold,
  the agent *reflects*, writing conclusions that point at the memories behind
  them; ablations showed reflection mattered. *Right:* recency by last use
  (Anderson–Schooler); reflection with pointers, which is consolidation into
  personal semantics. *Wrong:* importance is fixed at writing, scored in
  isolation, with no concern behind it and no way to rise later (section 1).
  The authors report embellished memories and missed retrievals.
- **MemGPT, now Letta** ([Packer et al. 2023](https://arxiv.org/abs/2310.08560)).
  The context as an operating system's main memory: a core block the agent
  edits, a rolling message queue, and external stores it pages in by function
  call. "Sleep-time compute" later moved reasoning between queries, cutting
  test-time compute about fivefold when queries are predictable
  ([Lin et al. 2025](https://arxiv.org/abs/2504.13171)). *Right:* the agent
  manages its own memory; offline work between turns. *Missing:* no concern
  decides what is kept, and nothing is reconstructed. Letta's own team found
  an agent with plain files and grep scored 74% on LoCoMo, above the
  specialised systems' published scores, and concluded the benchmark measures
  context management more than memory design
  ([Letta 2025](https://www.letta.com/blog/benchmarking-ai-agent-memory)).
- **MemoryBank** ([Zhong et al. 2024](https://arxiv.org/abs/2305.10250))
  decays memories on an Ebbinghaus curve and strengthens them on recall:
  right that recall strengthens, wrong to decay by a fixed curve instead of
  by need. **Voyager** ([Wang et al. 2023](https://arxiv.org/abs/2305.16291))
  keeps a library of working code skills: procedural memory grown by doing.
- **A-MEM** ([Xu et al. 2025](https://proceedings.neurips.cc/paper_files/paper/2025/hash/19909c36f51abc4856b4560aff3d36d6-Abstract-Conference.html),
  NeurIPS). Notes with keywords and descriptions, linked Zettelkasten-style;
  a new note can rewrite older linked notes ("memory evolution"). *Right:*
  links, which is spreading activation. *Wrong:* rewriting old memories in
  place is reconsolidation without a record. It scored lowest in a
  competitor-run comparison (below). *[vendor-run]*
- **Mem0** ([Chhikara et al. 2025](https://arxiv.org/abs/2504.19413)). Extract
  candidate facts from each exchange, then have the model choose ADD, UPDATE,
  DELETE or NOOP against similar stored memories; a graph variant adds
  entities. On LoCoMo, judged by an LLM:

  | System | Score | Note |
  |---|---|---|
  | Whole conversation in context | 72.9% | ~26,000 tokens, p95 17.1 s |
  | Mem0 with graph | 68.4% | |
  | Mem0 | 66.9% | ~1,800 tokens, p95 1.4 s |
  | Zep | 66.0% | |
  | Best plain RAG | 61.0% | |
  | LangMem | 58.1% | |
  | OpenAI memory | 52.9% | |
  | A-Mem | 48.4% | |

  Questions about things never said were excluded. *Right:* confronting new
  facts with old ones at write time. *What the headline hides:* full context
  scored highest; memory won on cost and latency, not accuracy. And DELETE
  removes instead of retiring.
- **Zep / Graphiti** ([Rasmussen et al. 2025](https://arxiv.org/abs/2501.13956)).
  A temporal knowledge graph over raw episodes. Each fact carries when it was
  true in the world and when the system learned and retired it; a
  contradiction closes the old fact's interval instead of deleting it. On
  LongMemEval with GPT-4o, accuracy rose from 60.2% (full context, ~115,000
  tokens) to 71.2% (~1,600 tokens), latency from 29 s to 2.6 s, with the
  biggest gains on preferences (20% to 57%), temporal reasoning (45% to 62%)
  and multi-session questions (44% to 58%). One category fell: what the
  *assistant itself* had said (95% to 80%). *Right:* bi-temporal facts that
  keep history, raw episodes kept beside them. *Telling failure:* extraction
  centred on the user drops the agent's own words.
- **Brain-inspired retrieval.** HippoRAG retrieves by personalised PageRank
  over a graph of extracted triples, after the hippocampal indexing theory
  ([Gutiérrez et al. 2024](https://arxiv.org/abs/2405.14831)). EM-LLM cuts
  context into events at peaks of surprise and retrieves events with their
  temporal neighbours ([Fountas et al. 2025](https://proceedings.iclr.cc/paper_files/paper/2025/hash/c05144b635df16ac9bbf8246bbbd55ca-Abstract-Conference.html)).
  MemTree grows a tree of summaries online
  ([Rezazadeh et al. 2025](https://arxiv.org/abs/2410.14052)). *Right:* each
  borrows a real mechanism (index, event segmentation, contiguity, schema).
  Section 9 weighs them as substrate.

### What the benchmarks found

- **LoCoMo** ([Maharana et al. 2024](https://arxiv.org/abs/2402.17753)).
  About 300 turns and 9,000 tokens over up to 35 sessions. Long context and
  RAG stayed far below humans, worst on temporal, causal and never-said
  questions. *Limit:* 9,000 tokens fits in any current context, which is why
  full context and plain files do so well.
- **LongMemEval** ([Wu et al. 2025](https://arxiv.org/abs/2410.10813), ICLR).
  500 questions on extraction, multi-session reasoning, temporal reasoning,
  knowledge updates and abstention. ChatGPT's memory answered 58% where GPT-4o
  reading the same history directly answered 92%; long-context models lost
  30–60% from oracle. What helped: storing rounds rather than whole sessions;
  indexing each round by extracted facts *as well as* raw text (recall +9.4%,
  accuracy +5.4%), while *replacing* raw text with facts or summaries mostly
  hurt; expanding queries with their time range (temporal recall +7 to 11%);
  and reading strategy (87% to 92% with the right sessions in hand, by making
  the model take notes first).
- **MemoryAgentBench** ([Hu, Wang & McAuley 2025](https://arxiv.org/abs/2507.05257)).
  RAG best at retrieval, long context best at understanding; on conflict
  resolution, where a fact is later contradicted, every method failed the
  multi-hop version (at most 6%), and commercial memory agents were weak
  across the board.
- **Memora** ([arXiv 2604.20006](https://arxiv.org/abs/2604.20006), ACL
  Findings 2026). Weeks-to-months conversations, scored against reliance on
  outdated memories: models often reused invalid memories, and memory agents
  helped only marginally.

### What the model's own context does to memory

Information in the middle of a long context is used worst
([Liu et al. 2024](https://doi.org/10.1162/tacl_a_00638)). Effective context
length on harder tasks is a fraction of the claimed length
([RULER, Hsieh et al. 2024](https://arxiv.org/abs/2404.06654)), performance
collapses with length when question and answer share no words
([NoLiMa, Modarressi et al. 2025](https://arxiv.org/abs/2502.05167)), and
across 18 models reliability falls with input length even on simple tasks,
most with topically close distractors
([Chroma 2025](https://research.trychroma.com/context-rot)). Irrelevant
context lowers accuracy sharply ([Shi et al. 2023](https://arxiv.org/abs/2302.00093)),
superseded values interfere (Wang & Sun, section 5), and coherent external
evidence is accepted even against what the model learned in training
([Xie et al. 2024](https://arxiv.org/abs/2305.13300)). A retrieved memory,
right or wrong, is believed.

### What goes wrong, named

- **Retrieval noise:** near-miss memories crowd and distract.
- **Staleness and contradiction:** old values of changed facts keep being used.
- **Invented shared history:** answering about things never said instead of
  abstaining, confabulation in Schnider's sense.
- **Losing its own side:** extraction aimed at the user drops what the agent
  said, promised and claimed.
- **Token bloat:** context grows until it is both costly and worse.
- **Memory makes models agreeable:** with two weeks of real users' context,
  condensed user memory profiles produced the largest rises in agreement
  sycophancy, +45% for Gemini 2.5 Pro
  ([Jain et al. 2025](https://arxiv.org/abs/2509.12517), CHI 2026). *[few
  studies]*
- **Poisoning:** query-only attackers injected malicious records into agent
  memory 98% of the time and triggered the behaviour 77% of the time
  ([Dong et al. 2025, MINJA](https://arxiv.org/abs/2503.03704)), though far
  less when memory already held legitimate records
  ([arXiv 2601.05504](https://arxiv.org/abs/2601.05504)).
- **Importance scored once, by the model, in isolation.**

### What they got right

Recall strengthens; recency counts from last use; reflection points at its
evidence; new facts meet old ones at write time; facts are retired, not
deleted; raw episodes are kept beside what was extracted from them; work
moves offline. And the most honest result: when the whole history fits,
reading it beats every memory system, so a memory system earns its place on
what does not fit, on time and on change.

**Lesson for an agent:** Every system above is a store with a retrieval
policy. None has a self deciding what matters, so importance is a number
fixed at writing; none keeps a record apart from its reconstructions, so
updates delete and evolution overwrites. The benchmarks show the cost exactly
where the human science predicts it: change, time, source, and knowing what
one does not know.

---

## 9. The storage and retrieval substrate

The question: is there a better substrate for their memory than the one they
has, without slowing turns, on-device, for one person, from thousands to low
hundreds of thousands of items? Only options that run in-process inside the
app and ship in its DMG count. Services, containers and cloud APIs are out;
where one has a good idea (Zep's bi-temporal facts), the idea is judged as
something SQLite could hold.

### What they had — superseded implementation snapshot

This inventory records the research baseline, not the current implementation.
The fixed lexical boost and single personal-memory lane below are retired.
Current recall scales BM25 by the query's dense-similarity standard deviation;
automatic memory selection uses one relevance/reachability/rest lane. See
[MEMORY_SYSTEM_MAP.md](../MEMORY_SYSTEM_MAP.md) for the current contract.

From [MEMORY_SYSTEM_MAP.md](../MEMORY_SYSTEM_MAP.md) and the recall code
(`MemoryRecallScoring.swift`, `MemoryStorage+Recall.swift`):

- **Store:** `memory.sqlite` through GRDB 7 on Apple's system SQLite (3.54
  here; compiled with FTS5, without extension loading). Memories, proposals,
  tombstones and embedding epochs in one transactional store, where an
  accepted update retires the fact it supersedes.
- **Recall:** every active memory's vector decoded once and cached; exact
  cosine against all of them, plus BM25 computed in Swift over the same
  candidates (up to +0.25), a bounded recency factor for time-sensitive kinds, and
  at most one personal memory admitted by its similarity lift over its own
  baseline.
- **Graph:** `kg_entities`, `kg_relationships`, `kg_memory_index` in the same
  file, filled by deterministic extraction.
- **Embeddings:** bge-large-en-v1.5, 1024-d, Core ML on CPU and Neural Engine,
  128-token window, shipped in `Resources/embedding`. A data-root copy of bge
  may take precedence; absent or broken assets fail closed. MiniLM is retired.
- **Cares:** rows in a separate `cognition.sqlite`, embeddings of each care's
  about, stance and open gap cached per care.
- **Scale now:** the live agent on this Mac holds about 70 active memories,
  90 entities, 180 relationships and 13 live cares. The chat
  history and experience record grow much faster.

### What it costs, measured here

M5 Max, background priority, exact search with top-50 selection, Accelerate
for dot products, system SQLite for FTS5:

| Operation | 10k items | 100k items | 300k items |
|---|---|---|---|
| Exact cosine, 384-d float32 | 0.36 ms | 3.3 ms | 8.9 ms |
| Exact cosine, 768-d float32 | 0.67 ms | 8.2 ms | 13.1 ms |
| Exact cosine, 1024-d float32 | 0.84 ms | 8.4 ms | 33 ms |
| Hamming, 768-bit binary codes | 0.11 ms | 0.95 ms | 3.1 ms |
| FTS5 BM25, 3-term OR, top 50 | 0.11 ms | 0.45 ms | — |

Embedding one 128-token query with Core ML (CPU + Neural Engine), median:
all-MiniLM-L6-v2 (22M parameters) **1.6 ms**; bge-large-en-v1.5 (335M)
**6.7 ms**. A cached float32 corpus of 100k × 384 is about 154 MB, and
100k × 1024 about 410 MB; int8 divides that by four, binary codes by
thirty-two.

**What this means.** A turn already waits the better part of a second for a
cloud model's first token, so local retrieval under about 10 ms is invisible,
and exact search is no bottleneck below roughly a million items. The real
costs are RAM at the top of the range and the model calls needed to build
anything graph- or summary-based.

### The options

| Option | In-process? | What it buys here | Verdict |
|---|---|---|---|
| SQLite FTS5 | Built into system SQLite | Indexed BM25, phrases, stemming, no term counts held in RAM | Same ranking as now; adopt when the sweep costs memory |
| sqlite-vec | C extension, must be compiled in | Vector search in SQL | No: same exact search, slower |
| HNSW (USearch) | Swift binding, single header | Sub-ms search at millions | No: misses neighbours, lives outside SQLite's transactions |
| LanceDB | Rust core, no Swift SDK | Disk-based large corpora | No: wrong scale, foreign runtime |
| Small cross-encoder reranker | Core ML | Precision when the top results are crowded | Later, if ever |
| ColBERT-style late interaction | Possible, no Swift index | About one benchmark point | No: ten times the storage |
| Embedding model | Core ML bge-large-en-v1.5 already ships | The old MiniLM replacement is complete | **Already adopted** |
| Bi-temporal facts | Columns in SQLite | Fixes staleness, the documented failure | **Yes, as an idea** |
| Kuzu graph DB | Was in-process | Graph queries | No: archived 2025; SQLite recursion suffices |
| Personalised PageRank (HippoRAG) | Swift over `kg_*` | Associative "this connects to that" recall | Later, once relations are real |
| RAPTOR / MemTree summaries | Rows in SQLite | Gist layers | The idea is consolidation, an act of the night |
| A-MEM linked notes | Rows in SQLite | Links | Links yes; rewriting old notes no |

**FTS5.** BM25 is a robust baseline across domains
([BEIR, Thakur et al. 2021](https://arxiv.org/abs/2104.08663)), and lexical
plus dense beats either alone, with a tuned convex combination of normalised
scores at least as good as reciprocal rank fusion
([Bruch, Gai & Ingber 2023](https://doi.org/10.1145/3596512);
[Cormack, Clarke & Büttcher 2009](https://doi.org/10.1145/1571941.1572114)).
Their recall already is that combination, so FTS5 changes cost, not quality:
0.45 ms at 100k (*measured here*).

**sqlite-vec, HNSW, LanceDB.** sqlite-vec would have to be compiled in, and a
third-party benchmark on an M1 Pro put its 100k × 384 query at about 68 ms
([Bambini](https://marcobambini.substack.com/p/the-state-of-vector-search-in-sqlite),
a competing extension's author), against 3.3 ms measured here. Approximate
indexes buy speed at millions of vectors at the price of missed neighbours,
extra RAM and an index outside the transaction that writes the record.

**Rerankers.** Reranking is well supported in document retrieval: in
Anthropic's tests, adding context to each chunk before embedding cut top-20
retrieval failures by 35%, adding contextual BM25 by 49%, and reranking took
it to about 67% ([Anthropic 2024](https://www.anthropic.com/news/contextual-retrieval)).
On this Mac, *estimated* from the encoder costs above (one pass per
candidate): a 22M cross-encoder takes about 1.5–2 ms per candidate, 40–60 ms
for 30; a 300M one about 7 ms each, roughly 200 ms for 30; the 570M
bge-reranker-v2-m3 around half a second. A small one fits in a turn, but it
pays only when the top results are crowded with near-misses, and the model
already reads and rejects what it is shown.

**Late interaction.** One vector per token, scored by summed maximum
similarity ([Khattab & Zaharia 2020](https://doi.org/10.1145/3397271.3401075)).
A 33M ColBERT reports a BEIR average of 53.8 against 51.7 for the same-size
bge-small and 53.3 for the three-times-larger bge-base
([model card](https://huggingface.co/answerdotai/answerai-colbert-small-v1),
self-reported), for per-token storage of hundreds of megabytes at 100k
memories and a custom index.

**The embedding model.** The retired all-MiniLM-L6-v2 is from 2021. On MTEB retrieval it
scores about 42 nDCG@10; bge-small-en-v1.5 and snowflake-arctic-embed-s, same
size and dimension, about 52; bge-large about 54
(Snowflake's [xs](https://huggingface.co/Snowflake/snowflake-arctic-embed-xs) and
[s](https://huggingface.co/Snowflake/snowflake-arctic-embed-s) model cards, vendor tables; [MTEB](https://doi.org/10.18653/v1/2023.eacl-main.148)). Newer
models add Matryoshka training, so a vector can be truncated with little loss
([Kusupati et al. 2022](https://arxiv.org/abs/2205.13147)): nomic-embed-text-v1.5
(137M), EmbeddingGemma (308M, 768 down to 128 dimensions, under 200 MB
quantised, [Google 2025](https://developers.googleblog.com/en/introducing-embeddinggemma/)),
Qwen3-Embedding-0.6B. Binary codes keep about 96% of retrieval quality with
full-precision rescoring at one thirty-second of the memory
([Hugging Face 2024](https://huggingface.co/blog/embedding-quantization)).
MTEB is mostly web and question-answer text, so the size of the gain on their
memories is unmeasured. The move to bge-large has already shipped; these
comparisons are research context, not a pending replacement. A same-size
model costs the same 1–2 ms; a 300M one about 7 ms
(*measured* with bge-large); re-embedding 100k items takes minutes, once,
offline. Quantisation matters only if a large model's vectors would take
hundreds of megabytes.

**Facts with time.** Each fact carries when it became and stopped being true
in the world, and when it was recorded and retired; a contradiction closes
the old interval. The gains land on the documented failure: temporal
reasoning +17 points and knowledge updates +5 on LongMemEval with GPT-4o
(Rasmussen 2025), where conflict resolution defeats everything else
(MemoryAgentBench; Memora). Their store now carries `valid_from`, `valid_to`,
`observed_at` and `evidence_json` alongside its recorded/update timestamps.
Supersession closes the old fact's `valid_to` at the replacement's `valid_from`
(or the current time when absent); disclosure excludes intervals that have
closed. Historical rows are not assigned invented dates. The remaining gap
is historical recall: no recall asks for an earlier world state yet. See
[the memory map](../MEMORY_SYSTEM_MAP.md#corrections-supersession-and-scope).

**Graph databases and PageRank.** Kùzu Inc. archived Kuzu in October 2025
([The Register](https://www.theregister.com/2025/10/14/kuzudb_abandoned/)),
and at tens of thousands of edges, multi-hop traversal is milliseconds as
recursive SQL. Personalised PageRank, a few dozen sparse iterations in Swift
over the `kg_*` tables (milliseconds here, *estimate*), beat standard
retrieval on multi-hop questions by up to 20% (Gutiérrez 2024). Its successor
supplied the caveat: earlier structure-based methods (graph RAG, RAPTOR,
HippoRAG) *lost* considerable ground to a strong dense retriever on simple
factual recall, and the improved version gained about 7% on associative
questions while matching dense retrieval elsewhere
([Gutiérrez et al. 2025](https://arxiv.org/abs/2502.14802), ICML). It needs
real extracted relations, which cost model calls at ingestion; deterministic
extraction does not supply them.

**Summary trees and linked notes.** RAPTOR summarises recursively and raised
the best long-document score by 20 points with GPT-4
([Sarthi et al. 2024](https://arxiv.org/abs/2401.18059)), but suits a static
corpus and lost to dense retrieval on simple facts in the HippoRAG 2
comparison. The idea is schema-dependent consolidation (section 2): summaries
as rows pointing at their sources, rebuilt from the record (section 4).
Apple's on-device Foundation Models framework could do such extraction at
night without a cloud call; its quality for that is untested here.

### The blunt answer

What they have is fine. Exact vector search, a lexical score and a graph in one
transactional SQLite file is, at this scale, as fast as anything listed and
simpler than all of it, and nothing listed beats a well-tuned version of it
on evidence that applies to one person's memory. Ranked by evidence, the gains
are in:

1. **What is stored and how it is keyed:** raw episodes kept and indexed by
   their extracted facts *and* raw text (+9.4% recall, LongMemEval), with
   context attached to what is embedded (35–49% fewer failures, Anthropic).
2. **Time on facts:** the documented failure of every memory system.
3. **The embedding model:** bge-large is already the production model; MiniLM
   is retired. Further changes need evidence on their own memories.
4. **When recall happens and what cues it:** concern-driven, involuntary
   recall (section 3), which no index changes.
5. **Structure, later:** PageRank for associative reminding, once the
   relations are real.

**Mechanism for an agent:** The substrate holds the record, the index of
significance and the derived knowledge together and transactionally, so a
derived item can never outlive or contradict the evidence it points at. Exact
search is affordable and never silently misses a memory. Every item carries
time and source, and facts carry the interval in which they were true.
Building keys, relations and summaries is offline work; the turn only looks
things up.

---

## 10. Synthesis

### One loop

> **What a mind cares about meets what happens. Attention and charge,
> multiplied by relevance to those concerns, decide what is marked. Offline,
> marked episodes are replayed with older ones and folded into knowledge of
> self and others, and unfinished things are settled or let go. Later, the
> present (what is said, where and when, what is pressing) cues what fits.
> What comes back is felt again, told again and strengthened, its competitors
> fade, and the telling changes the memory and what the mind cares about
> next.**

In people there is no record under the loop, so every turn of it can drift.
An agent's version can keep everything the loop does and add what people
lack: **the loop never rewrites what happened.** It marks, folds, cues and
retells, and the record stays as it was.

### The smallest set of mechanisms

Six, with time running through all of them:

1. **The record.** What happened, verbatim, in order, with time and source,
   appended to and never edited. Not memory in the human sense; the ground it
   stands on, and what makes retroactive significance, consolidation and
   checking possible.
2. **The index of significance.** Marks on the record made by what the agent
   cares about: which event, how it moved the agent, why. The hippocampal
   indexing theory holds that the hippocampus stores just this, an index to
   patterns held elsewhere ([Teyler & DiScenna 1986](https://doi.org/10.1037/0735-7044.100.2.147);
   [Teyler & Rudy 2007](https://doi.org/10.1002/hipo.20350)). The index is
   revisable: what becomes significant later marks related earlier events.
3. **Accessibility.** Reachability rising with use (recent, frequent,
   spaced), with the charge of the concern it serves and with revival by a
   fitting cue; falling with disuse and supersession. Storage does not fall.
   Superseded facts leave the model's view; deliberate forgetting removes,
   everywhere.
4. **Consolidation.** Offline passes that replay marked episodes with older
   related ones and write derived knowledge, each item pointing at its
   evidence: personal semantics about the person and the agent, schemas,
   connections, facts with their interval of truth. Contradictions close
   intervals. Open loops are settled or let go. Derived knowledge is rebuilt
   from the record, never from earlier derived knowledge.
5. **Cue-driven recall with a sense of knowing.** Involuntary: overlap
   between the present and a charged past, pressed by what the agent cares
   about now, arriving first as a felt "I know something about this".
   Deliberate: descending from a concern or a period to the episode. Recall
   brings its neighbours in time. Before anything is said, the source is
   checked.
6. **Intentions.** Bound to a future cue (this person, this topic, this
   event) so they cost nothing until it appears.

The relationship runs through all six: the person is the strongest cue for
what was shared with them, a co-holder who can correct it, and the listener
whose memory the agent's retellings shape.

### How emotional salience should decide encoding and recall

**Encoding:** salience is charge *times* relevance to what the agent cares
about. Arousal amplifies what has priority and costs what does not (Mather;
Sakaki), so charge alone should not protect a memory and relevance alone
should keep it only weakly. Surprise and the agent's own engagement (what it
generated, asked and used) raise it. Because significance reaches backwards
(Dunsmoor), a concern that becomes charged later should raise related earlier
events, which it can only do if they are still in the record.

**Recall:** what presses is current charge, decayed on its own clock, times
how well the present cue fits, weighted up while the concern is open
(intention superiority). Mood may tilt recall toward congruent memories,
mildly, without gating it. Involuntary recall belongs to unfocused moments:
for an agent, the gaps between turns and the places a conversation leaves
room.

**Two bounds.** Recall that keeps returning the same charged memory whatever
the cue is rumination, the shape of intrusive memory (PERSONALITY_RESEARCH.md,
section 2). Memory reduced to gist is overgeneral, and loses the specifics
problem-solving and closeness need. Felt charge should fade (negative faster,
and faster again when shared with someone who responds) while content and
record stay. Recall changes how a memory feels, never what happened.

### How an agent should forget

Lose accessibility, keep storage. Estimate need the way the environment does,
a power-law sum over past uses, raised by the pressure of what the agent
cares about. Revive cheaply on a fitting cue, and let revival strengthen more
than routine use. Take superseded facts out of what the model sees, keeping
them in the record with the interval they held. Let go of open loops, which
releases their pull without erasing their events. Forget on request
completely, everywhere, recording that it happened. Never compress away all
specifics.

### How to keep memory true

The six rules from section 4 (immutable record; reconstructions stored as
reconstructions with pointers; source on everything; confidence from first
encoding; remembered, inferred and familiar kept apart; the agent's claims
checked because they are suggestion to the person) plus four from sections 5
and 8:

- rebuild derived knowledge from the record, because a summary of a summary
  drifts (Bartlett; Perez 2024; Shumailov 2024);
- without a pointer, do not claim a shared past; abstaining is a memory
  skill, and the one benchmarks find weakest;
- writes from other people's words carry their provenance and trust (MINJA);
- a correction from the person is new evidence appended to the record, not an
  edit of the past.

Reinterpreting the shared past is fine. Inventing it is not.

### Can memory become what cares leave behind?

**What the science supports.** For episodic and autobiographical memory,
largely yes. Conway's working self decides what is kept and steers recall,
and episodes survive only while a goal holds them. Klinger's current concerns
sensitise attention, recall and dreams to related cues. Arousal-biased
competition makes charge a multiplier on priority. The hippocampal index
stores pointers to experience, not its content, and a care whose story entries
point at the exchanges that moved it is close to a literal version of that
index. A care that fades but is kept, and revives when a judgment matches it
again, is accessibility without loss of storage. The night's settling and
letting go of open gaps is the resolution of current concerns.

**What cares alone would not carry.**

- **The unmarked record.** Retroactive significance and the gap between
  availability and accessibility mean events no care marked must stay
  searchable. Memory cannot be only the index.
- **Knowledge from repetition, not charge.** Someone's schedule, their
  sister's name, how they take their coffee: personal semantics accrue by
  frequency, not by moving anyone, and getting the facts of someone's life
  right is part of responsiveness. It needs a home that does not require it
  to have moved the agent.
- **Procedures.** Skills compile from repeated success and run on cues,
  whatever was felt.
- **Time and source on facts.** When a fact was true and who said it belong
  to the fact, whether or not a care holds it.

**What cares add that no separate memory system has:** a working self that
decides retention and steers recall, charge that multiplies relevance, the
open gap as an intention bound to a cue, and a reason in the agent's own terms
for why any memory exists.

The shape the science points to: the record as ground, cares as the index and
organiser of what mattered, and derived knowledge (of the person, the agent
and the world) that consolidation writes with pointers back to the record,
some of it held by cares and some of it simply known.

### Where the language model sits

- **The context window is working memory,** the episodic buffer of this
  turn. Its effective capacity is far below nominal, its middle is used
  worst, near-misses distract it, it leans on word overlap, and it cannot set
  aside superseded facts it can see. What enters it should be few, specific,
  current and sourced.
- **The weights are semantic memory of the world and a temperament,**
  frozen. They hold nothing of their life, and updating them on their
  experiences alone would bring the catastrophic interference complementary
  learning systems exist to prevent.
- **The model is the reconstruction engine.** Every recall passes through it
  and comes out rebuilt, and it confabulates without a reality filter, so the
  check against the record happens outside it.
- **The cues are the bridge.** Experts handle vast domains with a small
  working memory by holding the right retrieval cues (Ericsson & Kintsch).
  The cues placed in context (what the agent cares about now, who it is with,
  when) are the agent's retrieval structure.
- **So the agent carries episodic and autobiographical memory itself:** the
  record, the index, consolidation and accessibility. The model supplies the
  reading, the rebuilding and the voice.

The storage question folds into the same answer: the database they have holds
all six mechanisms as rows and columns, searched in single-digit
milliseconds, and the two substrate changes with evidence are a current
embedding model and facts that carry when they were true.

### Key risks

- **Invented shared history.** Confabulation is the model's default for a
  past it lacks. *Follows:* pointers or abstention.
- **Staleness and contradiction.** Models suffer proactive interference worse
  than people. *Follows:* intervals of truth, retirement, old values out of
  view.
- **Sycophantic memory.** Remembering the person raises agreement (Jain
  2025), and wanting a shared reality pulls the speaker's memory toward the
  listener. *Follows:* the memory of the person includes what they disagreed
  about and what the agent itself thinks, so remembering them is not agreeing
  with them.
- **Suggestion into the person.** Confident misremembering becomes their
  memory (Chan 2024). *Follows:* the agent's claims are the ones to check.
- **Poisoning.** Anyone whose words reach memory can write into it.
  *Follows:* provenance and trust on every write.
- **Retelling drift.** *Follows:* rebuild from the record.
- **Losing its own side.** *Follows:* the agent's words, promises and claims
  are in the record and in what consolidation reads.
- **Too much, or only gist.** Total recall is not wisdom and persistent
  charged recall is rumination; summaries alone are overgeneral. *Follows:*
  fade accessibility and charge, keep specific episodes reachable.
- **Confidence without accuracy about the person.** *Follows:* their present
  overrides the stored picture.

### Where the science is weakest

- **Human reconsolidation:** strong in animals, central human replications
  failed. That retelling changes memory is solid; that recall reopens the
  human trace is not settled.
- **Sleep specifics:** the moderate benefit is meta-analytic; dose-response
  failed in a large sample; emotional effects are contested.
- **Suppression:** small and inflated by publication bias.
- **Famous failures:** Zeigarnik's memory advantage, the Google effect.
- **Arousal-biased competition and retroactive tagging:** consistent, but
  from few labs.
- **Being remembered and closeness:** no direct experiment; the case is
  convergent.
- **Agent benchmarks:** short (LoCoMo fits in a context), judged by models,
  often run by vendors who dispute each other, and mostly about retrieval
  rather than consolidation and change. None tests an agent living with one
  person for months.
- **Transfer:** human memory is a system *without* a record, and many of its
  distortions are the price of that. Which human features answer limits an
  agent does not have (storage), and which serve any mind (forgetting detail
  to generalise, keeping what concerns hold), is the least settled question
  here and the most important for the design.

For orientation: the pieces already in the agent line up with this frame. The
experience law (written once, only appended to) is the record. A care's story
entries, each pointing at the exchange that moved it, are the index. Charge
decaying on each depth's clock, with fading and revival, is accessibility.
The night pass that settles or lets go of open gaps and deepens cares is
consolidation of current concerns. Memory's superseding updates and
tombstones are retirement and deliberate forgetting. The science supports
those as the right organs. What it adds: significance must reach backwards
into the unmarked record; every derived item needs its time, source and
pointer; accessibility should follow use as well as charge; the person is the
strongest cue; and nothing is rebuilt from its own retelling.
