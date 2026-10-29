# How a body perceives its world

Research on perception, written for Claude on 2026-10-25 as raw material for
the agent design. It covers how a body perceives its world cheaply and
continuously, so that only what is new or surprising reaches awareness; what
an agent that lives on one person's Mac needs from that to see and act in
apps, windows, pages, files and mail without re-reading the whole screen at
every step; and what computer-use agents have tried. Each area ends with the
mechanism an agent would need. It does not propose features.

It leans on [PRACTICE_RESEARCH.md](PRACTICE_RESEARCH.md) for expertise as
perception and for the expectations a routine checks as it runs, on
[MEMORY_RESEARCH.md](MEMORY_RESEARCH.md) for what lasts, and on
[PERSONALITY_RESEARCH.md](PERSONALITY_RESEARCH.md) for appraisal. Where those
documents already cover a finding, this one cites it and moves on. A sibling
question, what the agent notices and when it speaks up, is researched
separately; this document stops at what reaches awareness, not at what gets
said.

How sure each finding is:

- *[meta-analytic]*: a meta-analysis or a very large literature agrees.
- *[replicated]*: independent labs have repeated it.
- *[debated]*: real evidence on both sides, or the effect holds and its
  mechanism is contested.
- *[few studies]*: one lab, small samples or one paradigm.
- *[theory]*: a framework or modelling argument more than an effect.
- *[failed replication]*: a famous finding that did not hold up, said
  plainly.

Engineering facts about operating systems and protocols are taken from the
vendors' own documentation and are marked *[documented]*. For the agent
literature, numbers are the authors' own, on their own benchmarks, usually
judged by their own evaluators. Treat them as directions, not measurements of
this agent.

---

## The answer first

- **Perception is mostly prediction, and what travels onward is the error.**
  A brain keeps a running model of what its senses should be reporting. On
  the best-supported reading, what moves up the hierarchy is the part the
  model failed to predict. Whether cortex literally sends only errors is
  debated. That perception discounts what was predicted, and that a surprise
  is what claims attention, is not.
- **Your own actions are predicted best of all.** A copy of every motor
  command is used to predict its sensory result. That is why you cannot
  tickle yourself, why the world does not jump when your eyes move, and why
  an animal can tell what it did from what happened to it. When the
  prediction is matched, the input is absorbed quietly. When it is not, or
  when something changes that nothing you did predicted, that is news.
- **Senses report differences, not states.** From the retina up, neurons
  adapt to what is constant and fire for change, under an energy budget that
  lets only a small fraction of them be active at once. An image held
  perfectly still on the retina fades within seconds. Event cameras, which
  report only per-pixel changes, show both sides in engineering: microsecond
  latency at a fraction of the bandwidth, and a still scene that is
  invisible until the camera moves itself.
- **The world is kept out there, not in here.** People hold very little of a
  scene in detail; a large change goes unnoticed if it arrives without a
  transient. What they hold is gist, layout, a handful of indexed objects,
  and the knowledge that they can look again. Eyes go where the task needs
  information next, just before it is needed, and how much people memorise
  rather than re-look depends on what a look costs.
- **A familiar place is recognised in a glance and searched by memory of
  where.** The gist of a scene arrives in about a tenth of a second and
  steers where to look. Repeated layouts speed search. But looking again and
  again at an unchanged display builds no better picture of it: speed in a
  familiar place comes from remembering where a thing was found, not from
  having seen everything.
- **Skilled action predicts its own result and checks only at the moments
  that matter.** A skilled hand moves through subgoals marked by discrete
  sensory events it expects (contact, lift-off, release), with gaze arriving
  at the next landmark before the hand. A mismatch triggers correction at
  that point. A man who lost proprioception could still act, but only by
  watching every movement; without vision they could make no new movement at
  all. That is the shape of today's computer-use agents.
- **The body is felt as a cheap standing state, and tools join it.**
  Proprioception and the body schema keep a continuous, mostly unconscious
  model of where the body is and what it can reach, and skilfully used tools
  are folded into it. Interoception holds the body's own variables in range
  and becomes a feeling only when one drifts, or is predicted to.
- **Engineering arrived at the same shape.** Event subscriptions with a
  resync path (file system events, DOM mutation records, accessibility
  notifications), diffs keyed by stable identity (React keys, rsync, video
  keyframes), and control that samples when the error is large rather than
  on a clock. Every working version has a way to say "I lost track; rescan."
- **Computer-use agents mostly do the opposite, and pay for it.** They read
  a full screenshot or accessibility tree before every action and send it,
  usually with the history, to a model. Raw accessibility trees in OSWorld
  run past a million tokens. Leading agents took 2.7 to 4.3 times more steps
  than a person, model calls dominated their latency, and later steps took
  up to three times longer than early ones. They fail by acting on a screen
  that has changed, by assuming an action worked, and by aiming at elements
  that are not where they think. What helped: smaller observations, a report
  of what changed after each action, several actions per model call checked
  against live state, memories of apps, and world models that predict the
  difference an action will make.
- **Where the model sits:** the language model is the slow, general
  interpreter at the top of the hierarchy. It should receive what the levels
  below could not explain (the surprise), what it asked to find, and the gist
  of where it is. It should not receive the parts of the world that are as
  predicted, or the confirmations of its own actions that went as expected.
  The standing model of the world, the predictions and the checks belong to
  the agent, below the model.

---

## 1. Perception as prediction

### Predictive coding: the residual is the message

**It starts in the retina.** Srinivasan, Laughlin and Dubs showed that the
inhibitory surround of retinal neurons can be read as a prediction of each
point's intensity from its neighbours, subtracted before transmission. What
is sent is the residual, which carries the same information in a smaller
range ([Srinivasan, Laughlin & Dubs 1982](https://doi.org/10.1098/rspb.1982.0085)).
*[replicated principle]*

**The cortical version.** Mumford proposed that feedback in the cortex
carries the higher area's best guess about the lower one
([Mumford 1992](https://doi.org/10.1007/BF00198477)). Rao and Ballard built
it: a hierarchy in which each level predicts the activity of the level below
through feedback, and only the residual error is sent forward. Trained on
natural images, the model reproduced "end-stopping" and other surround
effects in visual cortex as consequences of prediction: a neuron goes quiet
when its input is what its context predicts
([Rao & Ballard 1999](https://doi.org/10.1038/4580); review
[Huang & Rao 2011](https://doi.org/10.1002/wcs.142)). *[theory, influential]*

**The general form.** Friston generalised this as the minimisation of
prediction error, or free energy, across the hierarchy
([Friston 2005](https://doi.org/10.1098/rstb.2005.1622);
[Friston 2010](https://doi.org/10.1038/nrn2787); review
[Clark 2013](https://doi.org/10.1017/S0140525X12000477)). Two of its ideas
matter here. Errors are weighted by their expected *precision*, so an error
from a channel known to be noisy counts for less, and attention is the
setting of those weights. And action is another way to reduce error: change
the world to match the prediction, or move the sensor to get the evidence
that settles it. *[theory; broad and hard to falsify]*

**The evidence that surprise is coded.**

- *Mismatch responses.* A rare sound in a stream of identical ones produces
  a distinct brain response, the mismatch negativity, even when the person
  is not attending. It tracks the violated regularity, not just the rare
  sound ([Näätänen et al. 2007](https://doi.org/10.1016/j.clinph.2007.04.026);
  mechanisms reviewed by [Garrido et al. 2009](https://doi.org/10.1016/j.clinph.2008.11.029)).
  *[replicated]*
- *Mismatch neurons.* In mice running through a virtual corridor, many
  neurons in primary visual cortex responded most strongly when the visual
  flow stopped matching their running, that is, to the difference between
  expected and actual feedback ([Keller, Bonhoeffer & Hübener 2012](https://doi.org/10.1016/j.neuron.2012.03.040);
  review [Keller & Mrsic-Flogel 2018](https://doi.org/10.1016/j.neuron.2018.10.003)).
  *[replicated]*
- *Expectation.* The reduced response to a repeated face was larger when
  repetitions were expected ([Summerfield et al. 2008](https://doi.org/10.1038/nn.2163)),
  and expected gratings produced less activity in primary visual cortex but
  a representation decoded more accurately: less signal, sharper content
  ([Kok, Jehee & de Lange 2012](https://doi.org/10.1016/j.neuron.2012.04.034)).
  *[replicated in humans]*

**What did not hold up, and what is contested.** With the Summerfield
design in single neurons of macaque inferior temporal cortex, repetition
probability did not change adaptation ([Kaliukhovich & Vogels 2011](https://doi.org/10.1093/cercor/bhq207)).
*[failed replication in monkey single units]* A review found the evidence
for distinct prediction and error neurons thin, with many findings also
fitting plainer accounts of adaptation and attention
([Walsh et al. 2020](https://doi.org/10.1111/nyas.14321)). *[debated]* The
design needs only the functional claim, which is well supported: the
response to the predicted is reduced, and to a violated prediction
enhanced.

### Efference copy and corollary discharge

**The reafference principle.** In 1950, von Holst and Mittelstaedt, and
independently Sperry, proposed that when an animal moves, a copy of the
motor command (the *efference copy*, or *corollary discharge*) is sent to
the sensory systems to predict the input the movement will cause. Input
caused by one's own action (*reafference*) is cancelled against the copy;
what is left is *exafference*, input caused by the world
([von Holst & Mittelstaedt 1950](https://doi.org/10.1007/BF00622503);
[Sperry 1950](https://doi.org/10.1037/h0055479)). Sperry's fish, with eyes
surgically rotated, swam in endless circles: the copy predicted the wrong
visual motion, so every turn produced an error that called for another turn.
*[replicated]*

**Across the animal kingdom.** Crapse and Sommer's review found corollary
discharge from invertebrates to primates, doing two separate jobs: filtering
self-caused input and keeping track of one's own movements without waiting
for feedback ([Crapse & Sommer 2008](https://doi.org/10.1038/nrn2457)).
*[replicated]* Three examples make the jobs concrete:

- *A singing cricket* would deafen itself with its own chirps. One identified
  interneuron, driven by the singing motor pattern, inhibits the cricket's
  auditory pathway during each chirp and only then, so it can still hear
  other crickets between its own ([Poulet & Hedwig 2006](https://doi.org/10.1126/science.1120847)).
- *An electric fish* senses weak fields with the same organs its own
  discharge floods. A copy of the discharge command produces a "negative
  image" of the expected input, and the image is plastic: it changes to
  match the input that actually follows, so the prediction learns
  ([Bell 1981](https://doi.org/10.1126/science.7291985)).
- *A monkey's eye movements.* A pathway from the superior colliculus through
  the thalamus to the frontal eye field carries a copy of each saccade
  command. Inactivating it made monkeys err on the second of two rapid
  saccades in the way expected if they had lost track of where the first
  had taken their eyes ([Sommer & Wurtz 2002](https://doi.org/10.1126/science.1069590)).
  Neurons in the frontal eye field use the same copy to shift their
  receptive fields to where the eye is about to point, before it moves
  ([Sommer & Wurtz 2006](https://doi.org/10.1038/nature05279);
  [Duhamel, Colby & Goldberg 1992](https://doi.org/10.1126/science.1553535);
  review [Sommer & Wurtz 2008](https://doi.org/10.1146/annurev.neuro.31.060407.125627)).
  Perception around each saccade is also suppressed and distorted, which
  hides the blur the movement makes ([Ross et al. 2001](https://doi.org/10.1016/S0166-2236(00)01685-4)).

The copy lets the system update its own state without looking (where the
eye now points is known from the command), and it is what keeps the world
stable through three or so saccades a second.

### Sensory attenuation of self-made input

**You cannot tickle yourself.** People rate a touch they produce themselves
as less intense and less ticklish than the same touch from outside
([Weiskrantz, Elliott & Darlington 1971](https://doi.org/10.1038/230598a0);
[Blakemore, Wolpert & Frith 1998](https://doi.org/10.1038/2870)).
*[replicated]* The attenuation tracks how good the prediction is. When a
robot interposed between the person's hand and the touch added a delay of a
fraction of a second, or turned the direction of the stroke, the touch
became more ticklish in proportion
([Blakemore, Frith & Wolpert 1999](https://doi.org/10.1162/089892999563607)).
Attenuation is tuned to the expected *event*, not to the movement: a tap was
attenuated when it came at the moment the fingers would have made contact,
less as it was moved earlier or later, and not at all when the movement
stopped short of the sensor ([Bays, Wolpert & Flanagan 2005](https://doi.org/10.1016/j.cub.2005.05.023)).
*[replicated]*

**It has a cost.** Because self-made forces feel weaker, two people matching
each other's push escalate ([Shergill et al. 2003](https://doi.org/10.1126/science.1085327)).
People with schizophrenia attenuate less ([Shergill et al. 2005](https://doi.org/10.1176/appi.ajp.162.12.2384)),
and failing to predict one's own actions has been proposed as why they can
feel caused from outside ([Frith, Blakemore & Wolpert 2000](https://doi.org/10.1098/rstb.2000.0734)).
*[replicated for attenuation; the clinical account is debated]* The sense
of agency draws on this comparison and on inference after the fact
([Haggard 2017](https://doi.org/10.1038/nrn.2017.14)).

**What is contested.** Two challenges are serious.

- *Not only for the self.* When the timing of externally produced sounds was
  made as predictable as one's own, the attenuation reversed: it followed
  predictability, not authorship ([Kaiser & Schütz-Bosbach 2018](https://doi.org/10.1111/ejn.13931)).
  *[debated]*
- *Sharpened, not cancelled.* In fMRI, an avatar hand's movement was decoded
  *more* accurately when it matched the person's own movement, with activity
  suppressed in units tuned away from the expected outcome
  ([Yon et al. 2018](https://doi.org/10.1038/s41467-018-06752-7)). Press, Kok
  and Yon call the conflict the *perceptual prediction paradox*: one family
  of theories says expected input dominates perception, the other says it is
  suppressed. They propose two stages: perception is first biased toward
  what is likely, and then events that are particularly surprising are
  boosted ([Press, Kok & Yon 2020](https://doi.org/10.1016/j.tics.2019.11.003)).
  *[theory]*

The contested findings change the mechanism, not the shape: what is
predicted is handled cheaply, what is surprising is amplified.

**Mechanism for an agent:** Every channel the agent senses should be read
against a running prediction, and what goes onward is the residual, weighted
by how reliable that channel is known to be. Every act the agent performs
should carry a copy that predicts its effects: which events, in which
element, within what time. Effects that match are absorbed where they arrive
and update the agent's sense of its own state (focus moved, window opened,
value set) without anyone needing to look. Two things are news: an effect
that did not match the prediction, and a change that no act of the agent's
predicted, which is the world, or the person, doing something. A broken
copy fails in both directions: the agent's own effects look like someone
else's, or someone else's look like its own.

---

## 2. Efficient coding: why senses report differences

### Redundancy reduction

**Information sits where things change.** Attneave pointed out that most of
an image is predictable from its surroundings, and that information is
concentrated at contours, corners and changes
([Attneave 1954](https://doi.org/10.1037/h0054663)). Barlow turned it into a
principle: sensory relays recode their input to reduce redundancy, so that
each message carries as much as possible
([Barlow 1961](https://doi.org/10.7551/mitpress/9780262518420.003.0013)).

**Barlow changed their mind, usefully.** Forty years later they argued that the
point is not to *remove* redundancy but to *identify* it: to learn the
statistics of the world, because that model is what makes the new and the
unusual detectable and what learning is built on
([Barlow 2001](https://doi.org/10.1080/net.12.3.241.253)). *[theory]* A code
that strips out what is predictable has to keep the predictions.

**Matched to the world.** The contrast-response curve of a fly's
large-monopolar cells matches the cumulative distribution of contrasts in
its natural surroundings, so every level of response is used about equally
often ([Laughlin 1981](https://doi.org/10.1515/znc-1981-9-1040)). Learning a
*sparse* code for natural images, in which few units are active for any
image, produces receptive fields like those of primary visual cortex
([Olshausen & Field 1996](https://doi.org/10.1038/381607a0);
[Olshausen & Field 2004](https://doi.org/10.1016/j.conb.2004.07.007); review
[Simoncelli & Olshausen 2001](https://doi.org/10.1146/annurev.neuro.24.1.1193)).
*[replicated]*

**Energy forces it.** Spikes are expensive
([Attwell & Laughlin 2001](https://doi.org/10.1097/00004647-200110000-00001)).
Lennie estimated from cortex's energy use that perhaps fewer than 1% of its
neurons can be substantially active at the same time, which demands codes
with very few active units and a mechanism, selective attention, to spend
the energy where the task is ([Lennie 2003](https://doi.org/10.1016/S0960-9822(03)00135-0)).
*[theory with estimates]* For a brain the scarce resource is energy. For an
agent it is model calls and tokens, and the arithmetic is the same.

### Adaptation: the baseline moves with the world

**Gain follows the statistics.** Sensory neurons continuously rescale their
response to the range of input they are getting. In the fly's
motion-sensitive H1 neuron the rescaling to a new stimulus variance happened
quickly and kept the information transmitted near its maximum
([Brenner, Bialek & de Ruyter van Steveninck 2000](https://doi.org/10.1016/S0896-6273(00)81205-2)).
Adaptation runs on several time scales at once, and an adapted response is
ambiguous on its own (a strong response could mean a strong input or a quiet
context); the slower adaptation state, carried alongside, resolves it
([Fairhall et al. 2001](https://doi.org/10.1038/35090500); reviews
[Wark, Lundstrom & Fairhall 2007](https://doi.org/10.1016/j.conb.2007.07.001);
[Kohn 2007](https://doi.org/10.1152/jn.00086.2007);
[Webster 2015](https://doi.org/10.1146/annurev-vision-082114-035509)).
*[replicated]* A difference only means something relative to a baseline, so
the baseline is part of the message.

**The retina predicts too.** Retinal ganglion cells change their receptive
fields within seconds of entering an environment with different statistics,
in the direction that makes their predictive coding better for the new scene
([Hosoya, Baccus & Meister 2005](https://doi.org/10.1038/nature03689)). The
retina extrapolates the position of a moving edge to cancel its own delay
([Berry et al. 1999](https://doi.org/10.1038/18678)), and when a periodic
flash sequence skips a beat, some ganglion cells fire strongly and
specifically to the flash that did *not* come
([Schwartz et al. 2007](https://doi.org/10.1038/nn1887); review
[Gollisch & Meister 2010](https://doi.org/10.1016/j.neuron.2009.12.009)).
*[replicated]* The absence of an expected event is an event.

**Rare against frequent.** Neurons in auditory cortex adapt to a frequently
repeated tone and keep responding strongly to the same tone when it is
rare ([Ulanovsky, Las & Nelken 2003](https://doi.org/10.1038/nn1032)).
*[replicated]*

### What never changes disappears

**Stabilised images fade.** When an image is optically fixed to the retina so
that eye movements cannot move it, it fades from view within seconds
([Ditchburn & Ginsborg 1952](https://doi.org/10.1038/170036a0);
[Riggs et al. 1953](https://doi.org/10.1364/JOSA.43.000495)). The small
movements the eyes make even while fixating, including microsaccades, are
what keep a static scene visible ([Martinez-Conde, Macknik & Hubel 2004](https://doi.org/10.1038/nrn1348)).
*[replicated]* A system built to report change must make its own changes to
see what is static.

**Habituation is a model being built.** Sokolov's account of the orienting
reflex held that the nervous system forms a model of a repeated stimulus,
and that the reflex fires on *mismatch* with that model. Habituation is the
model getting good, not fatigue: change any feature, or omit the stimulus,
and the response returns ([Sokolov 1963](https://doi.org/10.1146/annurev.ph.25.030163.002553)).
The behavioural properties of habituation are among the best established in
psychology: it is specific to the stimulus, recovers with time, and is
reversed by a novel stimulus ([Thompson & Spencer 1966](https://doi.org/10.1037/h0022681);
updated by [Rankin et al. 2009](https://doi.org/10.1016/j.nlm.2008.09.012)).
*[replicated]*

### Change captures attention

An abrupt onset draws attention even when it is irrelevant to the search
([Yantis & Jonides 1984](https://doi.org/10.1037/0096-1523.10.5.601)).
*[replicated]* Itti and Baldi defined surprise formally, as how much an
observation shifts the observer's beliefs (the distance between prior and
posterior), which is different from how rare it is. In people watching
television, 72% of gaze shifts went to locations more surprising than
average ([Itti & Baldi 2009](https://doi.org/10.1016/j.visres.2008.09.007)).
*[few studies]* What claims attention is not change as such but change that
moves the model.

### The engineering parallel: event cameras

**A silicon retina.** After analogue chips that mimic the retina
([Mahowald & Mead 1991](https://doi.org/10.1038/scientificamerican0591-76))
came the dynamic vision sensor, which has no frames: each pixel reports,
asynchronously, when the logarithm of its brightness changes by a threshold,
with 120 dB of dynamic range and 15 µs latency in the first widely used one
([Lichtsteiner, Posch & Delbruck 2008](https://doi.org/10.1109/JSSC.2007.914337)).
*[documented]*

**What it buys and what it costs.** The survey by Gallego and colleagues
lists the gains: microsecond timing, very high dynamic range, no motion
blur, low power and low bandwidth, because a static scene sends almost
nothing. It also lists the cost: standard vision algorithms do not apply,
and information about what is static is missing
([Gallego et al. 2022](https://doi.org/10.1109/TPAMI.2020.3008413)).
Engineers answered the cost in the two ways the eye does:

- *Add an occasional full look.* One sensor uses each pixel's change
  detector to trigger an absolute measurement of that pixel only
  ([Posch, Matolin & Wohlgenannt 2011](https://doi.org/10.1109/JSSC.2010.2085952)).
  Another reads out ordinary frames alongside the event stream
  ([Brandli et al. 2014](https://doi.org/10.1109/JSSC.2014.2342715)).
- *Move the sensor.* An event camera fails to see edges parallel to its own
  motion. A rotating wedge prism in front of the lens, an artificial
  microsaccade, made it see static texture steadily while keeping its low
  latency ([They et al. 2024](https://doi.org/10.1126/scirobotics.adj8124)).
  *[few studies]*

**Mechanism for an agent:** A sense should report differences against a
baseline it has learned for that channel, and keep the baseline as part of
what a difference means. It should adapt: what is constant stops being
reported, and a rarer change is reported more strongly than a frequent one.
It must treat an expected event that does not arrive as an event. A sense
that reports only change is blind to what does not change, so it needs a
periodic or self-initiated full look, a keyframe or a microsaccade, to know
the static state and to catch what changed while it was not listening. The
scarce resource for the agent is model attention, and, as for the brain, it
forces a sparse code: few things reported, chosen because they moved the
model.

---

## 3. The world as its own model

### "The world as an outside memory"

O'Regan argued that the visual system does not build a detailed internal
picture of the scene, because it does not need to: the world is there, and
any detail can be had by looking. Seeing is the knowledge of how to get the
information, not a store of it ([O'Regan 1992](https://doi.org/10.1037/h0084327)).
Brooks, building robots, reached the same conclusion from the other side:
"the world is its own best model", so keep it there and sense it often
([Brooks 1991](https://doi.org/10.1016/0004-3702(91)90053-M)). *[theory]*

### Change blindness

**Large changes go unseen without a transient.** When a brief blank is
inserted between two versions of a photograph, people take many alternations
to find even a large change ([Rensink, O'Regan & Clark 1997](https://doi.org/10.1111/j.1467-9280.1997.tb00427.x)).
The same happens when the change coincides with "mudsplashes" that do not
cover it ([O'Regan, Rensink & Clark 1999](https://doi.org/10.1038/17953)),
with an eye movement, or when text alternates case between fixations during
reading ([McConkie & Zola 1979](https://doi.org/10.3758/BF03202990)). In a
real conversation, about half of passers-by giving directions failed to
notice that the stranger they were talking to had been replaced by another
person when a door was carried between them
([Simons & Levin 1998](https://doi.org/10.3758/BF03208840)). *[replicated]*
Attention to something else hides even a gorilla walking through a game
([Simons & Chabris 1999](https://doi.org/10.1068/p281059)). *[replicated]*

**What it shows.** The change is perfectly visible. What is missing is the
transient that would draw attention to it, and the comparison that would
need a stored copy of the old view. Change detection depends on attention
being on the thing at the moment it changes
([Simons & Levin 1997](https://doi.org/10.1016/S1364-6613(97)01080-2);
[Simons & Rensink 2005](https://doi.org/10.1016/j.tics.2004.11.006)).

### But not "nothing is stored"

The strong reading, that vision keeps nothing, is wrong.

- *Attended objects are remembered well.* Memory for objects that had been
  fixated in a scene was accurate, survived many intervening fixations, and
  accumulated in long-term memory as viewing went on
  ([Hollingworth & Henderson 2002](https://doi.org/10.1037/0096-1523.28.1.113);
  [Hollingworth 2004](https://doi.org/10.1037/0096-1523.30.3.519)).
  *[replicated]*
- *What crosses an eye movement is abstract.* Point-by-point images are not
  fused across saccades; a few objects' identities and positions are
  ([Irwin 1991](https://doi.org/10.1016/0010-0285(91)90015-G)). Visual
  working memory holds about four objects
  ([Luck & Vogel 1997](https://doi.org/10.1038/36846); its distinction from a
  brief, large sensory store goes back to [Phillips 1974](https://doi.org/10.3758/BF03203943)).
  *[replicated]*
- *The periphery keeps a summary.* Peripheral vision represents image
  statistics over regions rather than exact detail, so two images with the
  same statistics there look the same ("metamers")
  ([Freeman & Simoncelli 2011](https://doi.org/10.1038/nn.2889);
  [Rosenholtz 2016](https://doi.org/10.1146/annurev-vision-082114-035733)).
  *[replicated]*

**How rich is seeing?** Change blindness shows that what we have is
*access*, the ability to look and get it, not an illusion of richness
([Noë, Pessoa & Thompson 2000](https://doi.org/10.1080/135062800394702)).
People see more than working memory holds, through summary statistics, but
far less than they think ([Cohen, Dennett & Kanwisher 2016](https://doi.org/10.1016/j.tics.2016.03.006));
others argue experience overflows what can be reported
([Block 2011](https://doi.org/10.1016/j.tics.2011.11.001);
[Sperling 1960](https://doi.org/10.1037/h0093759)). *[debated]* No side
disputes what matters here: detail is held for what is attended, a summary
for the rest, and the feeling of a complete world comes from being able to
look again at once.

### Looking just in time

**Block copying.** Ballard, Hayhoe and Pelz asked people to copy a pattern of
coloured blocks from a model. Instead of memorising the model, people looked
at it once to get a block's colour, picked the block, then looked back again
to get its position. They chose not to use the working memory they had, and
put off gathering each piece of information until just before they needed it
([Ballard, Hayhoe & Pelz 1995](https://doi.org/10.1162/jocn.1995.7.1.66)).
*[replicated]*

**Deictic pointers.** Ballard and colleagues proposed that the brain binds the
variables of a task to locations in the world with *pointers*, fixation
being the main one, rather than copying the world inside. A program then
reads "the block I'm looking at" instead of a description of it
([Ballard et al. 1997](https://doi.org/10.1017/S0140525X97001611)). *[theory]*

**What you see is what you need.** When an object's size was changed while a
person was carrying it in virtual reality, they noticed only if size
mattered to the task *at that moment*; they could miss it while looking
straight at the object ([Triesch et al. 2003](https://doi.org/10.1167/3.1.9)).
*[replicated]*

**The price of a look sets the strategy.**

- When the task made it predictable which feature would be needed, people
  stored more in working memory; when it was unpredictable they went back to
  looking just in time ([Droll & Hayhoe 2007](https://doi.org/10.1037/0096-1523.33.6.1352)).
- Gray and colleagues' *soft constraints* hypothesis: at the scale of
  under a second, people mix memory and looking by their time costs. Make
  information slower to see, by a fraction of a second, and they shift
  toward remembering it ([Gray et al. 2006](https://doi.org/10.1037/0033-295X.113.3.461)).
  The same cost-benefit logic explains why people settle into stable but
  suboptimal methods with interactive tools ([Fu & Gray 2004](https://doi.org/10.1207/s15516709cog2806_2)).
  *[replicated within a research programme]*
- When looking is cheap, people search visually even through a scene they
  have memorised, and only use memory when forced to
  ([Oliva, Wolfe & Arsenio 2004](https://doi.org/10.1037/0096-1523.30.6.1132)).
  *[few studies]*

For a person a look costs about a quarter of a second. For an agent today a
full look costs seconds and thousands of tokens. The human evidence predicts
what a rational agent should do at that price: remember far more, and look
far less, and only where the task needs it next.

### Acting in order to see

Tetris players rotate falling pieces more than they need to, because
rotating on screen is faster than rotating in the head. Kirsh and Maglio
called these *epistemic actions*: actions taken to make perception or
computation easier, not to change the world toward the goal
([Kirsh & Maglio 1994](https://doi.org/10.1207/s15516709cog1804_1)). People
also arrange the space around them so that it does part of the thinking
([Kirsh 1995](https://doi.org/10.1016/0004-3702(94)00017-U)). *[few studies;
widely cited]*

### Active vision

**Look where it settles the question.** Problems that are ill-posed for a
passive camera become well-posed for an observer that can choose its
viewpoint ([Aloimonos, Weiss & Bandyopadhyay 1988](https://doi.org/10.1007/BF00133571);
[Bajcsy 1988](https://doi.org/10.1109/5.5968);
[Bajcsy, Aloimonos & Tsotsos 2018](https://doi.org/10.1007/s10514-017-9615-3)).
The eye's high resolution covers about two degrees, so human seeing is a
sequence of chosen looks ([Findlay & Gilchrist 2003](https://doi.org/10.1093/acprof:oso/9780198524793.001.0001)),
and in reading, text outside a small window around each fixation can be
replaced unnoticed ([McConkie & Rayner 1975](https://doi.org/10.3758/BF03203972);
[Rayner 1998](https://doi.org/10.1037/0033-2909.124.3.372)). *[replicated]*

**The task picks the look.** Yarbus showed that the same viewer's eye
movements over a painting changed with the question asked
([Yarbus 1967](https://doi.org/10.1007/978-1-4899-5379-7); replicated
qualitatively by [DeAngelus & Pelz 2009](https://doi.org/10.1080/13506280902793843)).
Decoding the task from eye movements failed in one study
([Greene, Liu & Wolfe 2012](https://doi.org/10.1016/j.visres.2012.03.019))
and succeeded with richer features in another
([Borji & Itti 2014](https://doi.org/10.1167/14.3.29)). *[debated]* Salience
models predict free viewing of pictures ([Itti & Koch 2001](https://doi.org/10.1038/35058500))
and fail during real tasks, where gaze follows what the task needs next
([Tatler et al. 2011](https://doi.org/10.1167/11.5.5)). *[replicated]*

### Affordances

**Perceiving what a thing is for.** Gibson argued that animals directly
perceive *affordances*, the possibilities for action the environment offers
to this body ([Gibson 1979/2014](https://doi.org/10.4324/9781315740218)).
People judge a stair climbable by its height relative to their own leg
length ([Warren 1984](https://doi.org/10.1037/0096-1523.10.5.683)).
*[replicated]* Gaver carried the idea to interfaces
([Gaver 1991](https://doi.org/10.1145/108844.108856)).

**The famous lab effect is small.** Seeing a handled object was said to
prime a grasp with the nearer hand ([Tucker & Ellis 1998](https://doi.org/10.1037/0096-1523.24.3.830)).
After replication failures, a meta-analysis of 88 effects found a small
effect with signs of publication bias ([Azaad, Laham & Shields 2019](https://doi.org/10.1016/j.cognition.2019.04.028)),
part of which may be plain spatial compatibility
([Cho & Proctor 2010](https://doi.org/10.1037/a0019328)). *[failed
replication of the strong form]* Action possibilities scaled to the body
stand; automatic motor priming does not, at its first-reported size.

### Sensorimotor contingencies

**Seeing is knowing what would change if you moved.** O'Regan and Noë
proposed that perceiving is mastery of how input changes with one's own
movement ([O'Regan & Noë 2001](https://doi.org/10.1017/S0140525X01000115)).
*[theory]* Blind people using a camera that drove vibrators on the back
came to perceive objects out in space only when they moved the camera
themselves ([Bach-y-Rita et al. 1969](https://doi.org/10.1038/221963a0);
[Bach-y-Rita & Kercel 2003](https://doi.org/10.1016/j.tics.2003.10.013)),
and kittens that moved themselves developed visually guided behaviour that
littermates carried through the same sights did not
([Held & Hein 1963](https://doi.org/10.1037/h0040546)). *[few studies; the
kitten study is ten pairs, never repeated at scale]*

**Mechanism for an agent:** The agent should not try to keep a copy of the
screen. It should keep what people keep: the gist of where it is, a summary
of everything else, a few things it is working with held by pointer, and the
knowledge of how to look at anything else at once. Each look should be
taken when the task needs that information next, for the information the
task needs, and its price should decide the balance: at today's price, the
agent should remember much more than a person and look much less. Looking
is an action and can be chosen, including actions taken only to see better.
What it perceives should be in terms of what it can do there, scaled to its
own reach. And it should expect to miss any change that came without a
signal while it was attending elsewhere.

---

## 4. Gist, schemas and indexed objects

### Gist in a glance

**Meaning before detail.** Shown a rapid stream of pictures, people can detect
one that matches a name given in advance at around a tenth of a second per
picture, though remembering what they saw takes longer
([Potter 1975](https://doi.org/10.1126/science.1145183);
[Potter 1976](https://doi.org/10.1037/0278-7393.2.5.509)). Brain responses
separate scenes with and without an animal within 150 ms
([Thorpe, Fize & Marlot 1996](https://doi.org/10.1038/381520a0)), and a
single glance yields a surprising amount of what the scene is about
([Fei-Fei et al. 2007](https://doi.org/10.1167/7.1.10)). *[replicated]*

**A failed replication at the extreme.** Potter and colleagues reported
detection above chance at 13 ms per picture
([Potter et al. 2014](https://doi.org/10.3758/s13414-013-0605-z)). With
better masking of each picture by the next, Maguire and Howe found no
detection at 27 ms ([Maguire & Howe 2016](https://doi.org/10.3758/s13414-016-1096-5)).
*[failed replication of the 13 ms claim]* Gist is fast; the limit is not as
low as claimed.

**Global layout, not objects.** Oliva and Torralba showed that a few global
properties of an image, its "spatial envelope" (how open, rough, expanded or
natural it is), are enough to classify scenes, without finding any objects
([Oliva & Torralba 2001](https://doi.org/10.1023/A:1011139631724);
[Oliva & Torralba 2006](https://doi.org/10.1016/S0079-6123(06)55002-2)).
People's rapid categorisation errors follow those global properties, and a
classifier that uses only them matches human rapid categorisation
([Greene & Oliva 2009](https://doi.org/10.1016/j.cogpsych.2008.06.001)).
Recognition runs coarse to fine ([Schyns & Oliva 1994](https://doi.org/10.1111/j.1467-9280.1994.tb00500.x)).
*[replicated]*

**Gist steers the eyes.** A model in which global scene features predict
where a kind of object is likely to be predicted people's first fixations in
search better than image salience did
([Torralba et al. 2006](https://doi.org/10.1037/0033-295X.113.4.766)).
*[replicated]*

### Scene schemas

**Knowing what belongs where.** People detect objects more slowly and less
accurately when they violate the scene's structure: floating without
support, in the wrong place, at the wrong size or in the wrong kind of scene
([Biederman, Mezzanotte & Rabinowitz 1982](https://doi.org/10.1016/0010-0285(82)90007-X)).
Scene context predicts which objects will be present and where
([Bar 2004](https://doi.org/10.1038/nrn1476)). Võ and colleagues separate a
scene's *semantics* (what belongs) from its *syntax* (where it goes), with
different brain signatures, and call the whole a *scene grammar* that guides
search ([Võ & Wolfe 2013](https://doi.org/10.1177/0956797613476955);
[Võ, Boettcher & Draschkow 2019](https://doi.org/10.1016/j.copsyc.2019.03.009);
review [Henderson & Hollingworth 1999](https://doi.org/10.1146/annurev.psych.50.1.243)).
*[replicated]*

**The schema fills in.** People who waited half a minute in an office later
"remembered" objects that offices usually have, such as books, that were not
there ([Brewer & Treyens 1981](https://doi.org/10.1016/0010-0285(81)90008-6)).
*[replicated]* The schema that speeds perception also writes into memory
what was expected rather than what was seen.

**Does the odd object pull the eyes?** One study found that objects that did
not belong drew early fixations ([Loftus & Mackworth 1978](https://doi.org/10.1037/0096-1523.4.4.565));
a later one, with better control, found they did not, though they were
looked at longer once found ([Henderson, Weeks & Hollingworth 1999](https://doi.org/10.1037/0096-1523.25.1.210)).
*[debated]* A violation of the schema is noticed reliably once the eyes are
there; whether it reaches out to grab them from the periphery is less sure.

### A familiar place: memory of where

**Repeated layouts speed search.** When the same arrangement of items recurs
with the target in the same place, people find the target faster, while
being at chance at telling repeated from new arrangements
([Chun & Jiang 1998](https://doi.org/10.1006/cogp.1998.0681)). *[replicated]*
Whether that learning is really unconscious is contested: across 73 studies,
the tests of awareness were too weak to show its absence
([Vadillo, Konstantinidis & Shanks 2016](https://doi.org/10.3758/s13423-015-0892-6)).
*[debated]* That repeated layout guides attention is solid.

**Looking again does not build a better picture.** Wolfe and colleagues had
people search the same unchanging display for new targets trial after trial.
If search was inefficient the first time, it was just as inefficient the
350th time; attending to a display left no representation that made the
next search faster ([Wolfe, Klempen & Dahlen 2000](https://doi.org/10.1037/0096-1523.26.2.693)).
In real scenes, searching for several objects one after another did not get
faster with familiarity, and even 30 seconds spent memorising a scene did
not speed later search for its objects. Searching for the *same* object
again, though, became much faster, even after many other searches in between
([Võ & Wolfe 2012](https://doi.org/10.1037/a0024147)). *[replicated]*

**Recognition is cheap and huge.** People recognise thousands of pictures
seen once ([Standing 1973](https://doi.org/10.1080/14640747308400340)),
including object details ([Brady et al. 2008](https://doi.org/10.1073/pnas.0803390105))
and many details of scenes of a familiar kind
([Konkle et al. 2010](https://doi.org/10.1177/0956797610385359)).
*[replicated]* Knowing *that* this is a place you have been is nearly free.
Knowing what is *in* it comes from having looked for things there.

### Object files and visual indexes

**Objects carry their own records.** Kahneman, Treisman and Gibbs showed that
information seen on an object is reviewed faster when it reappears *on the
same object* after the object moves, as if each object had a file that
moves with it ([Kahneman, Treisman & Gibbs 1992](https://doi.org/10.1016/0010-0285(92)90007-O)).
*[replicated]*

**Pointers before descriptions.** Pylyshyn proposed a small set of visual
indexes, FINSTs ("fingers of instantiation"), that attach to a few objects
and stay attached as they move, before and without any description of what
the objects are. Indexes let the mind ask "what is at that one?" without
searching again ([Pylyshyn 1989](https://doi.org/10.1016/0010-0277(89)90014-0);
[Pylyshyn 2001](https://doi.org/10.1016/S0010-0277(00)00156-6)). People can
track four or five identical items among identical distractors
([Pylyshyn & Storm 1988](https://doi.org/10.1163/156856888X00122)); how
many depends on speed, from about eight when the items move slowly to one
when they move fast ([Alvarez & Franconeri 2007](https://doi.org/10.1167/7.13.14)).
*[replicated; fixed slots against a flexible resource is debated]* See the
review by [Scholl 2001](https://doi.org/10.1016/S0010-0277(00)00152-9).

**Identity by continuity, not by looks.** Whether an object is "the same one"
after a change is decided by where and when it was, its path through space
and time, more than by its features
([Mitroff & Alvarez 2007](https://doi.org/10.3758/BF03193113)).
*[replicated]* An index survives a change of appearance if the path is
continuous, and is lost if the path breaks.

### Rensink's triad

Rensink pulled these findings into one architecture
([Rensink 2000](https://doi.org/10.1080/135062800394667)). *[theory]*

1. *Proto-objects.* Early vision produces a rapidly updated, volatile array of
   structures across the whole field, and keeps nothing.
2. *Coherence.* Focused attention binds a few of them into a coherent,
   persisting object, held only while attended. When attention is released,
   the object dissolves back into proto-objects.
3. *Setting.* A system that runs without attention holds the scene's gist
   and layout and uses them to guide attention to where it should go next.

This is close to the minimal design: a cheap, wide, volatile layer; a narrow,
held layer for the few things in use; and a gist that steers between them.

**The robot's version.** Robots that must recognise places they have been
match the *appearance* of the current view, in a compact code, against
places they know ([Cummins & Newman 2008, FAB-MAP](https://doi.org/10.1177/0278364908090961)).
Recognising "where am I" is done from a summary, not by comparing every
detail.

**Mechanism for an agent:** On arriving anywhere (an app, a window, a page,
a folder) the agent should first recognise *what kind of place this is* from
cheap global features: which app, which kind of window, which state, where
focus is. The recognised kind brings a schema: what belongs here, where it
usually is, what usually comes next. The things it is working with should be
held as indexes that follow the thing by its continuity (the same element
along its path through the app), not as copies of what it looked like. A
familiar place is made fast by remembering where things were *found* there,
not by having read the place before; re-reading builds nothing. A violation
of the schema, something present that does not belong or absent that should
be there, is what deserves a look. The schema will also fill in what was not
seen, so what is remembered about a place needs to say what was seen and
what was assumed.

---

## 5. Acting with prediction

### Two components: launch, then home in

**Two components.** Aiming movements have a planned, largely
ballistic initial impulse and a later phase of "current control" that uses
feedback near the target ([Woodworth 1899](https://doi.org/10.1037/h0092992);
[Elliott, Helsen & Chua 2001](https://doi.org/10.1037/0033-2909.127.3.342);
[Elliott et al. 2010](https://doi.org/10.1037/a0020958)), sized optimally for
speed against accuracy ([Meyer et al. 1988](https://doi.org/10.1037/0033-295X.95.3.340)).
Pointing time grows with the logarithm of distance over target width
([Fitts 1954](https://doi.org/10.1037/h0055392);
[MacKenzie 1992](https://doi.org/10.1207/s15327051hci0701_3)).
*[meta-analytic for Fitts' law; replicated for two components]*

**Feedback is slow.** Using vision to correct a movement takes about 100 to
260 ms, depending on conditions ([Keele & Posner 1968](https://doi.org/10.1037/h0025754);
[Zelaznik, Hawkins & Kisselburgh 1983](https://doi.org/10.1080/00222895.1983.10735298);
[Carlton 1981](https://doi.org/10.1037/0096-1523.7.5.1019)). *[debated in
the numbers]* A movement faster than the loop cannot be steered by it; it
has to be predicted.

### Forward models

**Predicting the body's next state.** Wolpert, Ghahramani and Jordan showed
that people's estimates of where their unseen hand is, during and after a
movement, are explained by a *forward model*: an internal simulation that
predicts the next state from the current state and the motor command, then
corrects the prediction with delayed sensory feedback, as a Kalman filter
does ([Wolpert, Ghahramani & Jordan 1995](https://doi.org/10.1126/science.7569931);
[Miall & Wolpert 1996](https://doi.org/10.1016/S0893-6080(96)00035-4);
[Kalman 1960](https://doi.org/10.1115/1.3662552)). *[replicated]* The same
predictions cancel reafference, as in section 1
([Wolpert & Flanagan 2001](https://doi.org/10.1016/S0960-9822(01)00432-8)).

**Grip anticipates load.** When people move a held object up and down, grip
force rises and falls *in phase with* the load the movement will create, not
after it. The prediction is made from the motor command
([Flanagan & Wing 1997](https://doi.org/10.1523/JNEUROSCI.17-04-01519.1997)).
*[replicated]*

**Errors in prediction drive learning.** Motor adaptation is driven by the
gap between predicted and actual consequence more than by task failure
([Shadmehr, Smith & Krakauer 2010](https://doi.org/10.1146/annurev-neuro-060909-153135);
[Shadmehr & Krakauer 2008](https://doi.org/10.1007/s00221-008-1280-5)).
*[replicated]*

**A predictor for a loop with a delay.** A plant with long dead time is
controlled by acting on a delay-free model's prediction and correcting with
the delayed real output (the Smith predictor), and the cerebellum has been
proposed to work this way ([Miall et al. 1993](https://doi.org/10.1080/00222895.1993.9942050)).
*[theory]* An agent whose interpreter takes seconds is such a plant.

**Many models, chosen by which predicts best.** Wolpert and Kawato's MOSAIC
pairs many forward models with controllers. Each forward model predicts what
will happen in its context (an empty cup, a full one), and control is handed
to the pairs in proportion to how well their forward models are predicting
right now ([Wolpert & Kawato 1998](https://doi.org/10.1016/S0893-6080(98)00066-5);
[Haruno, Wolpert & Kawato 2001](https://doi.org/10.1162/089976601750541778)).
*[theory]* Recognising the context and choosing the model are the same act.

**Correct only what matters.** In optimal feedback control, the best strategy
under noise is not to hold a planned trajectory but to let variability go
where it does not affect the goal and to correct only the deviations that
do: the *minimal intervention principle* ([Todorov & Jordan 2002](https://doi.org/10.1038/nn963)).
*[replicated]*

### Where the eyes go when the hands work

**Eyes lead, at landmarks.** Land and colleagues recorded people's gaze while
they made tea. Gaze was almost always on the object about to be used, very
few fixations were unrelated to the task, the eyes reached each object about
half a second before the hand began to act on it, and they left for the next
object about half a second before the hand finished
([Land, Mennie & Rusted 1999](https://doi.org/10.1068/p2935);
[Land & Hayhoe 2001](https://doi.org/10.1016/S0042-6989(01)00102-X);
[Hayhoe & Ballard 2005](https://doi.org/10.1016/j.tics.2005.02.009)).
*[replicated]* Gaze locates objects for later, guides the hand to a place,
guides one object to another, and checks a state, such as the water level.

**Contact events are the checkpoints.** In Johansson's grasping task, the
places where contact events happened (the grasp site, the target, the
support surface) were obligatory gaze targets. People never looked at their
hand or at the moving bar. Gaze left each landmark at the moment the
expected event happened there, as if checking off a subgoal
([Johansson et al. 2001](https://doi.org/10.1523/JNEUROSCI.21-17-06917.2001)).
*[replicated]* In Johansson and Flanagan's account, manipulation is a chain of
action phases, each ending in a discrete sensory event. The brain predicts
each event, compares the prediction with what arrives, and launches a
correction only when they differ ([Johansson & Flanagan 2009](https://doi.org/10.1038/nrn2621)).
Watching someone else do the task, observers' eyes run ahead to the same
landmarks ([Flanagan & Johansson 2003](https://doi.org/10.1038/nature01861)).
*[replicated]*

**Experts look where the ball will be.** Batsmen jump their gaze to where the
ball will bounce before it arrives ([Land & McLeod 2000](https://doi.org/10.1038/81887)),
drivers look at the tangent point of a bend
([Land & Lee 1994](https://doi.org/10.1038/369742a0)), and squash players'
eye movements are pervasively predictive ([Hayhoe et al. 2012](https://doi.org/10.1007/s00221-011-2979-2)).
*[replicated]* Sports experts make fewer, longer fixations
([Mann et al. 2007](https://doi.org/10.1123/jsep.29.4.457)), with a longer
final "quiet eye" fixation going with better performance
([Vickers 1996](https://doi.org/10.1037/0096-1523.22.2.342);
[Lebeau et al. 2016](https://doi.org/10.1123/jsep.2015-0123)).
*[meta-analytic; why it helps is debated]* See also PRACTICE_RESEARCH.md,
section 5.

**Learning moves gaze from following to predicting.** People learning to
steer a cursor with an unfamiliar mapping first chased the cursor with their
eyes. As they learned, gaze began to mark where the cursor should go, and
finally went straight to the target ([Sailer, Flanagan & Johansson 2005](https://doi.org/10.1523/JNEUROSCI.2658-05.2005)).
*[few studies]* The novice watches the effector. The expert watches the next
place where something will be decided.

### A body without proprioception

Two men who lost large-fibre sensation below the neck show what acting looks
like without a continuous sense of the body. One could still make accurate
movements in the laboratory, but could not sustain a steady force without
looking, and their hands were nearly useless in daily life: they could not
write, button a shirt or hold a cup ([Rothwell et al. 1982](https://doi.org/10.1093/brain/105.3.515)). The
other, who had lived with the loss for more than sixteen years, could
continue a posture or a simple repeated movement for a while, but "no novel movement was possible
without visual feedback"; with their eyes shut they could barely tell 200 g
from 400 g ([Cole & Sedgwick 1992](https://doi.org/10.1113/jphysiol.1992.sp019099)).
*[case studies]* They relearned to walk, but by watching every movement, at a
heavy, constant cost in attention (Cole 1995, *Pride and a Daily Marathon*,
MIT Press).

This is the closest human picture of an agent that must take a screenshot
before every click. It can act, but only by looking at everything, all the
time, and every look goes through the most expensive part of the system.

### Actions are coded by their effects

Ideomotor theory holds that an action is represented by, and selected
through, the perceptual effects it produces, in one code shared by
perception and action ([Hommel et al. 2001](https://doi.org/10.1017/S0140525X01000103);
[Elsner & Hommel 2001](https://doi.org/10.1037/0096-1523.27.1.229); review
[Shin, Proctor & Capaldi 2010](https://doi.org/10.1037/a0020541)).
*[replicated]* An act chosen by its expected effect already carries the
prediction its success can be checked against.

### The engineering parallel: look-then-move and servoing

Robotics separates *look-then-move*, which looks, plans and executes
open-loop, from *visual servoing*, in which the image error drives motion
continuously ([Hutchinson, Hager & Corke 1996](https://doi.org/10.1109/70.538972);
[Chaumette & Hutchinson 2006](https://doi.org/10.1109/MRA.2006.250573)).
Servoing needs a cheap, fast error signal; look-then-move needs a good
model. Skill uses both: ballistic launches from a model, checked at the
events where error can be measured.

**Mechanism for an agent:** Every act should be launched with a prediction of
its effect, stated as the discrete events that should follow, where and
within what time: a focus change, a window, a value, a page load, a file
appearing. A fast inner loop, which is code and not the model, checks those
events. If they arrive, the act is checked off and the agent's model of its
own state moves forward, with no look. The model is consulted at subgoal
boundaries and on mismatch, and nowhere else. A sequence of acts whose
effects are each predicted can be launched together and checked event by
event, stopping at the first that fails. Attention should go to the next
landmark, where the next decision will be made, before it is needed. Which
forward model applies is chosen by which has been predicting well in this
context, which is the same as recognising the context. Deviations that do
not affect the goal are left alone. Because the interpreter is slow, the
agent should act on its predicted state and correct when the real state
arrives, never wait for the interpreter to look at every result.

---

## 6. Body schema and the space of reach

### The body schema

Head and Holmes proposed a *schema*, a continuously updated postural model of
the body, against which every new posture or movement is measured below
awareness ([Head & Holmes 1911](https://doi.org/10.1093/brain/34.2-3.102)).
The schema, used for action, is now distinguished from the *body image*, the
body as perceived and thought about ([de Vignemont 2010](https://doi.org/10.1016/j.neuropsychologia.2009.09.022)).
Proprioception, from muscle spindles, tendon organs and skin, supplies it
continuously and combines with the motor command's copy
([Proske & Gandevia 2012](https://doi.org/10.1152/physrev.00048.2011);
[Tuthill & Azim 2018](https://doi.org/10.1016/j.cub.2018.01.064)).
*[replicated]* It is the cheapest sense a body has: always on, almost never
conscious, and noticed mainly when it fails.

**A schema can outlive the body.** After an amputation, most people feel a
phantom limb, often with posture and movement. The schema persists with no
limb to correct it, and can be updated by giving it false visual feedback
through a mirror ([Ramachandran & Hirstein 1998](https://doi.org/10.1093/brain/121.9.1603)).
*[replicated for phantoms; the treatment evidence is weaker]*

### Tools join the body

**Neurons that extend along the rake.** Iriki and colleagues trained monkeys
to retrieve food with a rake. In parietal cortex, neurons that responded to
touch on the hand and to sights near it extended their visual receptive
fields along the length of the rake while it was being used, and not while
it was merely held ([Iriki, Tanaka & Iwamura 1996](https://doi.org/10.1097/00001756-199610020-00010);
[Maravita & Iriki 2004](https://doi.org/10.1016/j.tics.2003.12.008)).
*[replicated in monkeys]*

**People too.** After using a long grabber, people's arm movements changed
as if their arm had grown ([Cardinali et al. 2009](https://doi.org/10.1016/j.cub.2009.05.009)).
In habitual computer users, holding or using the mouse removed the usual
difference between sounds near the hand and sounds near the screen, as if
the space around the hand extended to where the cursor acts
([Bassolino et al. 2010](https://doi.org/10.1016/j.neuropsychologia.2009.11.009)).
*[few studies]*

**Or attention moves to the tip.** Holmes re-analysed the crossmodal studies
and concluded that tool use does not literally extend the space around the
hand. It shifts attention toward the part of the tool that acts, and the
effects are small and underpowered ([Holmes, Calvert & Spence 2004](https://doi.org/10.1016/j.neulet.2004.09.024);
[Holmes 2012](https://doi.org/10.1007/s00221-012-3042-7)). *[debated]* Both
readings agree on what matters here: a tool in skilled use is attended at
the point where it acts, not where it is held.

**Owning a hand that is not yours.** A rubber hand stroked in time with a
person's hidden hand comes to feel like theirs for many people
([Botvinick & Cohen 1998](https://doi.org/10.1038/35784);
[Ehrsson, Spence & Passingham 2004](https://doi.org/10.1126/science.1097011)),
though how much of the report reflects expectation and suggestibility is
contested ([Lush 2020](https://doi.org/10.1525/collabra.325);
[Lush et al. 2020](https://doi.org/10.1038/s41467-020-18591-6)). *[debated]*

### Space coded by what could be done in it

Neurons in premotor and parietal cortex respond to objects near a body part,
in coordinates that move with that part ([Graziano, Yap & Gross 1994](https://doi.org/10.1126/science.7973661);
[Rizzolatti et al. 1997](https://doi.org/10.1126/science.277.5323.190)), and
some drive defensive movements ([Graziano & Cooke 2006](https://doi.org/10.1016/j.neuropsychologia.2005.09.009)).
Serino reviews this *peripersonal space* as the interface between self and
environment ([Serino 2019](https://doi.org/10.1016/j.neubiorev.2019.01.016)).
Bufacchi and Iannetti argue that it is not one zone with an edge but a set of
graded fields, each describing how relevant an action that makes or avoids
contact would be ([Bufacchi & Iannetti 2018](https://doi.org/10.1016/j.tics.2018.09.004)).
*[replicated for the neurons; the framing is debated]*

### Robots that learn their own bodies

A review of body schemas in robotics found the same split between a fixed,
engineered model and one learned from the robot's own actions and sensations
([Hoffmann et al. 2010](https://doi.org/10.1109/TAMD.2010.2086454)). A
four-legged robot that inferred its own structure from how its actions felt,
then walked using that self-model, re-modelled itself when part of a leg
was removed and found a new gait ([Bongard, Zykov & Lipson 2006](https://doi.org/10.1126/science.1133687)).
*[few studies]*

**Mechanism for an agent:** The agent should hold a cheap, always-current
model of its own body: where its focus and pointer are, which app and window
it is in, what its hands are holding (a selection, a drag, a key down), and
which tools it has and what each can reach. The model is moved forward by
the agent's own commands and confirmed by feedback, not rebuilt by looking.
Tools used skilfully, a browser, a control layer, a sense, become part of
this schema, and attention goes to where each tool acts, not where it is
held. The space around the agent is best coded by what it could do there,
graded by how much doing it would matter. A schema can outlive what it
describes, a phantom control or a window that is gone, so it needs to notice
when feedback stops agreeing with it and re-learn, as the robot did.

---

## 7. Interoception: sensing that stays out of awareness

### Regulation below awareness

**Homeostasis.** Cannon described how the body holds its internal variables,
temperature, glucose, water, oxygen, within range by automatic corrective
loops ([Cannon 1929](https://doi.org/10.1152/physrev.1929.9.3.399)).
*[replicated]* Most of this never reaches awareness. Most fibres in the
vagus nerve carry signals *from* the organs, and most of those signals are
used without ever being felt ([Berthoud & Neuhuber 2000](https://doi.org/10.1016/S1566-0702(00)00215-0)).

**Interoception as a sense.** Craig described a dedicated pathway carrying
the physiological condition of the body to the insula, where it becomes the
basis of feelings ([Craig 2002](https://doi.org/10.1038/nrn894)). Predictive
accounts treat interoception like any other sense: the brain predicts the
body's state, and feelings arise from interoceptive predictions and their
errors ([Seth 2013](https://doi.org/10.1016/j.tics.2013.09.007);
[Barrett & Simmons 2015](https://doi.org/10.1038/nrn3950); computational
models reviewed by [Petzschner et al. 2021](https://doi.org/10.1016/j.tins.2020.09.012);
[Khalsa et al. 2018](https://doi.org/10.1016/j.bpsc.2017.12.004)).
*[theory with growing evidence]*

### Regulation that predicts

**Allostasis.** Sterling argued that regulation is mostly *predictive*: the
body anticipates needs and adjusts before errors arise, rather than waiting
for a variable to leave its range ([Sterling 2012](https://doi.org/10.1016/j.physbeh.2011.06.004)).
Whether this is a different principle or homeostasis described more fully is
argued; Ramsay and Woods propose focusing on the many regulatory loops and
how they interact rather than on set points ([Ramsay & Woods 2014](https://doi.org/10.1037/a0035942)).
*[debated as a concept]*

**Thirst ends before the water arrives.** In mice, thirst-promoting neurons in
the subfornical organ fall silent within moments of drinking, long before
the water changes the blood. They combine signals from the mouth with the
blood's state to predict how drinking will change fluid balance, and adjust
behaviour in advance ([Zimmerman et al. 2016](https://doi.org/10.1038/nature18950)).
Hunger neurons reverse their activity when food is merely seen or smelled,
before any is eaten ([Chen et al. 2015](https://doi.org/10.1016/j.cell.2015.01.033)),
and their activity works as a teaching signal with negative valence
([Betley et al. 2015](https://doi.org/10.1038/nature14416)). *[replicated in
mice]* The body's own monitors predict; they do not merely threshold.

**A good regulator is a model.** Conant and Ashby proved that every good
regulator of a system must be a model of that system
([Conant & Ashby 1970](https://doi.org/10.1080/00207727008920220)).
*[theorem, under its assumptions]*

### Feeling is not the same as measuring

**The standard measure failed.** For decades, interoceptive accuracy was
measured by asking people to count their heartbeats. Counting scores turned
out to depend on knowledge and beliefs about heart rate more than on sensing
it, and they do not agree with a detection task that measures sensing
directly ([Zamariola et al. 2018](https://doi.org/10.1016/j.biopsycho.2018.06.006);
[Desmedt, Luminet & Corneille 2018](https://doi.org/10.1016/j.biopsycho.2018.09.004);
[Ring & Brener 2018](https://doi.org/10.1111/psyp.13084)). *[failed
validity]* Accuracy, self-rated sensibility and metacognitive awareness of
interoception are three dissociable things
([Garfinkel et al. 2015](https://doi.org/10.1016/j.biopsycho.2014.11.004)).
*[replicated]* A body's report of its own state is a poor witness of the
state.

**Mechanism for an agent:** The agent's own variables, its resources, its
permissions, its connections, the health of its senses, whether its person
is present, should be held in range by loops that run below the model and
never wake it while they are in range. They should predict, adjusting before
a variable leaves its range when its course is foreseeable. A variable
should reach awareness as a feeling only when it is out of range, or about
to be, and the feeling should be computed from the measured state, not from
the agent's own account of it.

---

## 8. Engineering parallels, and agents that use computers

This section is not a template list. It sets out how engineering solved
the same problem wherever bandwidth was scarce, then what computer-use agents
measured, what went wrong for them and what helped.

### Event-driven senses on a Mac and in a browser

**Accessibility notifications.** macOS lets a process observe another app's
accessibility tree through an `AXObserver`, registered per element for named
notifications: focus moved, window created, value changed, element
destroyed, and others for titles, selection, layout and menus
([AXObserver](https://developer.apple.com/documentation/applicationservices/axobserver);
[AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)).
An element can refuse ("does not support notifications"), app switches
arrive on a separate workspace channel
([NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)),
and Electron apps build no tree until a client sets `AXManualAccessibility`
([Electron](https://www.electronjs.org/docs/latest/tutorial/accessibility)).
*[documented]* Only 33% of macOS apps examined offered full accessibility
support ([Muryn et al. 2025, Screen2AX](https://arxiv.org/abs/2507.16704)).
*[few studies]* This agent's own source records one more property: most
element changes never reach an observer registered on the application
alone, so subscriptions have to sit on descendants.

**DOM mutation records.** A `MutationObserver` receives batched records of
changes to a page's tree, attributes and text, delivered after the change
rather than in the middle of it ([DOM standard](https://dom.spec.whatwg.org/#mutation-observers);
[MDN](https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver)).
It replaced mutation *events*, which fired for every change, were slow,
blocked optimisations and caused crashes; Chrome removed them in July 2024
([Chrome for Developers](https://developer.chrome.com/blog/mutation-events-deprecation)).
*[documented]* Per-change callbacks were too expensive; coalesced records
delivered at a safe point were not.

**File system events.** FSEvents works per directory: it "tells you *only*
that something in the directory has changed, but does not tell you *what*
changed", coalesces bursts, and keeps a persistent record so an app can ask
what changed while it was not running
([overview](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/TechnologyOverview/TechnologyOverview.html)).
An app resumes from the last event ID it stored. When events are coalesced
across subdirectories or dropped, the event says `MustScanSubDirs` and the
app must rescan. And "you must start monitoring the directory *before* you
start scanning it" ([Using FSEvents](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)).
Linux's inotify drops events past its queue limit but always says so
(`IN_Q_OVERFLOW`), and merges identical unread events, so it cannot count
([inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html)).
Watchman returns a clock to resume from and an `is_fresh_instance` flag
that means "history lost; treat everything as new"
([Watchman](https://facebook.github.io/watchman/docs/cmd/since)).
*[documented]*

**What every working event system has.** Six rules:

1. Subscribe first, then read, so nothing falls in the gap.
2. Events say *where*, often not *what*; read that place, and only that
   place.
3. Bursts are coalesced; events are not a count.
4. A cursor lets a consumer resume where it was.
5. Loss is reported, and the answer to loss is a rescan.
6. Coverage is partial; what cannot be observed must be looked at.

These are section 2's rules found again: report change, keep a baseline,
keep an honest way to resynchronise.

### Diffs keyed by identity

**A diff needs identity.** The minimum edit between two general trees takes
roughly cubic time ([Zhang & Shasha 1989](https://doi.org/10.1137/0218082);
[Bille 2005](https://doi.org/10.1016/j.tcs.2004.12.030)). React gets a
linear diff from two assumptions: different element types make different
trees, and children with a stable *key* are the same element across renders
([React reconciliation](https://legacy.reactjs.org/docs/reconciliation.html)).
*[documented]* A diff is cheap and meaningful only when identity is carried
through the change, which is what object files do (section 4).

**Send what changed.** rsync sends only the blocks the other end lacks
([Tridgell & Mackerras 1996](https://rsync.samba.org/tech_report/)); web
delta encoding sends the difference from a version the client holds
([Mogul et al. 1997](https://doi.org/10.1145/263105.263162);
[RFC 3229](https://www.rfc-editor.org/rfc/rfc3229)); conditional requests
ask "changed since this tag?" before paying for the whole
([RFC 9110](https://www.rfc-editor.org/rfc/rfc9110)); remote desktops send
only changed rectangles ([Richardson et al. 1998](https://doi.org/10.1109/4236.656066);
[RFC 6143](https://www.rfc-editor.org/rfc/rfc6143)); video codecs send most
frames as a prediction plus a residual, with a periodic keyframe so a
decoder that lost its place can recover
([Wiegand et al. 2003](https://doi.org/10.1109/TCSVT.2003.815165)).
*[documented]* The keyframe is section 2's microsaccade.

**Sample on error, not on the clock.** Sampling when the error crosses a
threshold rather than at fixed intervals can match performance with far
fewer samples ([Åström & Bernhardsson 2002](https://doi.org/10.1109/CDC.2002.1184824)).
*Event-triggered* control acts when the measured error grows too large;
*self-triggered* control uses a model to predict when the next measurement
will be needed ([Tabuada 2007](https://doi.org/10.1109/TAC.2007.904277);
[Heemels, Johansson & Tabuada 2012](https://doi.org/10.1109/CDC.2012.6425820)).
*[theory with proofs]* What all of them watch is the Kalman filter's
*innovation*, the gap between predicted and measured state
([Kalman 1960](https://doi.org/10.1115/1.3662552)). Learners that plan in a
learned model of the world (Dyna, [Sutton 1991](https://doi.org/10.1145/122344.122377))
now learn a compact latent state, predict forward in it and decode to
observations only when needed ([Ha & Schmidhuber 2018](https://arxiv.org/abs/1803.10122);
[Hafner et al. 2025](https://doi.org/10.1038/s41586-025-08744-2)).
*[replicated across benchmarks]* The latent state is the gist.

### What a look costs a language model

**An image is thousands of tokens.** Claude reads an image as 28×28-pixel
patches, so a 1920×1080 screenshot costs about 1,560 visual tokens on the
standard tier and about 2,691 on the high-resolution tier
([Claude vision docs](https://platform.claude.com/docs/en/build-with-claude/vision)).
In an agent loop every request resends the whole conversation, so every
earlier screenshot is paid for again on every step, unless it is dropped.
*[documented]* Reading a cached prefix costs a tenth of the normal input
price or less, but only if the prefix is byte-for-byte identical
([prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)).
*[documented]* A stable prefix with small appended differences is cheap; a
fresh full screen each step is not.

**An accessibility tree can be far more.** OSWorld reports that a raw
accessibility tree in XML usually runs past a million tokens. Even filtered,
a context of about 6,000 tokens was needed to hold 90% of single
observations, and "even just the leaf nodes can have tens of thousands of
tokens" ([Xie et al. 2024, OSWorld](https://arxiv.org/abs/2404.07972)).
*[documented by the benchmark authors]*

**Long contexts are not only expensive.** Models use information in the
middle of a long context worse than at its ends ([Liu et al. 2024](https://doi.org/10.1162/tacl_a_00638)).
Across 18 models, performance became less reliable as inputs grew, even on
deliberately simple tasks, and related but irrelevant material hurt more as
length grew ([Hong, Troynikov & Huber 2025, "Context rot"](https://www.trychroma.com/research/context-rot)).
Matching that needs more than literal overlap degrades sharply with length
([Modarressi et al. 2025, NoLiMa](https://arxiv.org/abs/2502.05167)).
*[replicated across labs]* Re-reading the whole screen at every step does
not only cost more. It buries the change in what did not change.

### Computer-use agents: how they see

- **Screenshots.** Claude's computer use (October 2024) worked from
  screenshots and scored 14.9% on OSWorld's screenshot-only category, 22.0%
  with more steps; Anthropic called it "at times cumbersome and error-prone"
  ([Anthropic 2024](https://www.anthropic.com/news/3-5-models-and-computer-use)).
  OpenAI's screenshot-based Computer-Using Agent reported 38.1% on OSWorld
  in January 2025 ([OpenAI 2025](https://openai.com/index/computer-using-agent/)).
  At OSWorld's release people completed 72.36% of tasks and the best model
  12.24% ([Xie et al. 2024](https://arxiv.org/abs/2404.07972)). A later
  framework passed the human figure, at 72.6%, by running several attempts
  and judging between them, which spends more model calls, not fewer
  ([Gonzalez-Pumariega et al. 2025](https://arxiv.org/abs/2510.02250)).
  Higher 2026 leaderboard figures I could not check against the official
  board.
- **Marks.** Set-of-Mark overlays numbered marks so the model answers with a
  mark, not a coordinate ([Yang et al. 2023](https://arxiv.org/abs/2310.11441)).
  On OSWorld's dense desktop screens it *lowered* GPT-4V's success relative
  to the screenshot plus tree ([Xie et al. 2024](https://arxiv.org/abs/2404.07972)).
- **Pure vision.** Grounding, locating the element an instruction means, was
  the bottleneck for visual agents ([Cheng et al. 2024, SeeClick](https://arxiv.org/abs/2401.10935)).
  UGround argued that HTML and accessibility trees "often introduce noise,
  incompleteness, and increased computational overhead" and beat
  text-using agents with vision alone ([Gou et al. 2024](https://arxiv.org/abs/2410.05243));
  see also OmniParser, CogAgent and UI-TARS
  ([Lu et al. 2024](https://arxiv.org/abs/2408.00203);
  [Hong et al. 2024](https://arxiv.org/abs/2312.08914);
  [Qin et al. 2025](https://arxiv.org/abs/2501.12326)). On high-resolution
  professional software the best grounding model found 18.9% of targets;
  *narrowing the search area* raised it to 48.1% without training, which is
  foveation rediscovered ([Li et al. 2025, ScreenSpot-Pro](https://arxiv.org/abs/2504.07981)).
- **Structure plus vision.** UFO and UFO2 read Windows UI Automation
  alongside screenshots, fuse in visual parsing for controls the API misses,
  and prefer an app's own API to clicking ([Zhang et al. 2024](https://arxiv.org/abs/2402.07939);
  [Zhang et al. 2025](https://arxiv.org/abs/2504.14603)). On macOS the best
  proprietary agents passed 30% and open-source models stayed under 5%
  ([Yang et al. 2025, macOSWorld](https://arxiv.org/abs/2506.04135)), and
  trees rebuilt from screenshots for apps that lack them made an agent 2.2
  times better than native trees ([Muryn et al. 2025](https://arxiv.org/abs/2507.16704)).
  *[few studies]*

### What they measured about cost and steps

**OSWorld-Human** is the first study built to measure efficiency
([Abhyankar et al. 2025](https://arxiv.org/abs/2506.16042)):

- Model calls for planning, reflection and judging accounted for most of the
  end-to-end latency. Screenshots and action execution were the cheapest
  parts.
- Each later step took longer, up to three times the early steps, because
  the prompt at each step carried the whole history, screenshots included.
- Generating an accessibility tree took 3 to 26 seconds per observation,
  depending on how many elements the window held, and added thousands of
  tokens to every prompt. Adding the tree to screenshots *increased* the
  number of steps for most applications.
- Measured against a human-annotated path for every task, even the best of
  16 agents took 2.7 to 4.3 times more steps than necessary.

*[few studies]* Other measured costs: OSWorld found that more text history
helped and more screenshot history did not ([Xie et al. 2024](https://arxiv.org/abs/2404.07972));
MobileGPT cut latency by 62.5% and cost by 68.8% by recalling sub-tasks
instead of re-deriving them ([Lee et al. 2024](https://arxiv.org/abs/2312.03003));
plan caching and learned routines are covered in PRACTICE_RESEARCH.md,
section 8.

### What goes wrong, named

- **Acting on a guess about the screen.** OSWorld's error analysis found
  mouse-click inaccuracy in more than 75% of 550 failed runs, with
  repetitive clicks and clicks that opened pop-ups or other apps following
  from it. One agent's own code comment reads "Assuming the 'No Color'
  option is the first option in the dropdown", followed by a click that
  failed. Moving, shrinking or cluttering the windows at the start of a task
  dropped performance sharply, by 60 to 80% in the authors' account, on
  tasks the agent usually solved
  ([Xie et al. 2024](https://arxiv.org/abs/2404.07972)). *[few studies]*
- **Assuming the action worked.** Anthropic's documentation says plainly:
  "Claude sometimes acts as if its actions succeeded without explicitly
  checking their results", and suggests prompting it to take a screenshot
  and evaluate after every step ([computer use docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)).
  *[documented]* The suggested fix is the deafferented man's: look at
  everything, every time.
- **No model of consequences.** Asked to pick which of two next states an
  action would produce, current models averaged 54.75%, against a chance
  level of 50%, and one frontier model was close to chance. Given the next
  state of each candidate action, the same models chose correct actions far
  more often, GPT-4o going from 53% to 73%
  ([Chae et al. 2024, WMA](https://arxiv.org/abs/2410.13232)). *[few
  studies]* Language models are poor at predicting the effects of their
  actions and much better at choosing once they know them.
- **Time of check to time of use.** An agent that checks the state of the
  world and acts on it later can act on something that changed in between.
  In a benchmark of 66 tasks built to expose this, 12% of executed
  trajectories were vulnerable; the best combination of defences brought
  that to 8% ([Lilienthal & Hong 2025](https://arxiv.org/abs/2508.17155)).
  *[few studies]*
- **Captured by salience.** Adversarial pop-ups, which people would ignore,
  were clicked 86% of the time on average and cut task success by 47%.
  Telling the agent to ignore pop-ups did not help
  ([Zhang, Yu & Yang 2024](https://arxiv.org/abs/2411.02391)). Unrelated but
  harmless content distracts agents too ([Ma et al. 2024](https://arxiv.org/abs/2408.02544)).
  *[few studies]* What is new and bright is not therefore relevant, and an
  agent without a model of what it expects has no defence against it.

### What worked

- **Smaller, task-shaped observations.** Filtering raw HTML with a small
  model first ([Deng et al. 2023, Mind2Web](https://arxiv.org/abs/2306.06070)),
  abstracting away task-irrelevant state ([Zheng et al. 2024, Synapse](https://arxiv.org/abs/2306.07863)),
  and in AgentOccam only refining the observation and action spaces
  (removing repetitive page text, keeping task-relevant elements, dropping
  finished sub-plans from history) raised WebArena success by 26.6 points
  over a plain agent ([Yang et al. 2024](https://arxiv.org/abs/2410.13825)).
  *[replicated in direction]*
- **A report of what changed.** Agent-E's actions return what they changed
  ("As a consequence, a popup has appeared with following elements"),
  observed with MutationObserver; the authors note that returning the new
  elements could spare another full read ([Abuelsaad et al. 2024](https://arxiv.org/abs/2407.13032)).
  *[few studies]*
- **Predict the difference, not the screen.** Predicting the next full
  observation failed on long, repetitive HTML; predicting in words only the
  important differences between steps worked ([Chae et al. 2024](https://arxiv.org/abs/2410.13232)).
  Simulating each candidate action's outcome before committing matched tree
  search at four to five times the efficiency ([Gu et al. 2024, WebDreamer](https://arxiv.org/abs/2411.06559)).
  *[few studies]*
- **Several actions per call, each checked against live state.** UFO2
  predicts a short run of actions in one call, checks each target against
  UI Automation just before acting (still there, enabled, visible), and
  stops at the first failure. On a subset of OSWorld's Windows tasks it cut
  steps by up to 51.5% at the same success rate ([Zhang et al. 2025](https://arxiv.org/abs/2504.14603)).
  A faster model guessing the next action cut latency by up to 20%
  ([Ye et al. 2025](https://arxiv.org/abs/2510.04371)). *[few studies]* The
  check is made by the operating system's structure, not by the model
  looking.
- **Memories of apps.** AppAgent documents an app's elements by exploring or
  watching ([Zhang et al. 2023](https://arxiv.org/abs/2312.13771)); AutoDroid
  explores apps offline into a memory of UI transitions and outperformed its
  GPT-4 baseline's task success by 39.7% ([Wen et al. 2024](https://doi.org/10.1145/3636534.3649379));
  AutoDroid-V2 turns app documentation into scripts a small model writes,
  with fewer tokens ([Wen et al. 2024](https://arxiv.org/abs/2412.18116)).
  *[few studies]*
- **Not looking, when an interface exists.** Agents using a site's API beat
  browsing agents on WebArena, and hybrids gained more than 24 points over
  browsing alone ([Song et al. 2024](https://arxiv.org/abs/2410.16464)).
  *[few studies]*

### What they did not measure

Mostly success rate, on a few hundred tasks, in virtual machines reset before
each task. Some report steps, latency or tokens. Almost none report how much
of each observation was unchanged from the last, how often an agent acted on
a state that had changed since it looked, how often it believed an action
succeeded when it had not, or anything about one person's own machine over
months, where the same apps are used every day and change under the agent
while it works.

**Lesson for an agent:** The systems that did best saw less. They filtered
the observation to what the task needed, returned what an action changed
instead of a new full view, predicted differences rather than states,
checked several predicted actions against live structure without the model,
and remembered apps instead of re-reading them. The failures are the ones
the science predicts for a body that has no efference copy and no standing
model: it must look at everything, it cannot tell its own effects from the
world's, it assumes its acts landed, it is captured by whatever is bright,
and it acts on a world that moved since it last looked. Almost none of these
agents keep a model of the world across steps. Each step starts from a fresh
look.

---

## 9. Synthesis

### One loop

> **A body carries a standing model of its world and of itself. Every sense
> reports against that model, and only the difference travels on. Each act
> is predicted before it is made, so its expected effects are absorbed where
> they arrive and only a mismatch rises. Change that no act predicted is the
> world's doing, and it rises too. Looks are acts, aimed where the task needs
> information next and spent only where looking is cheaper than remembering.
> A familiar place is recognised as a kind in a glance, and the kind brings
> its layout, its usual next states and what can be done there. What reaches
> the slow interpreter at the top is what the levels below could not
> explain, what it asked to find, and the gist of where it is. Everything
> else updates the model below without ever being read.**

Every section says the same thing about cost. A brain processes what it
failed to predict (sections 1 and 2), keeps the world out there and looks
only where and when the task needs it (section 3), recognises places from a
summary and remembers where things were found (section 4), acts on
predictions checked at the events that matter (section 5), and feels its
body and its internal variables as cheap standing states (sections 6 and
7). Engineering reached the same shape wherever bandwidth was scarce
(section 8). Computer-use agents mostly have not, because a model call per
look seemed affordable. Section 8's evidence is that it is not, in money,
in latency, or in accuracy, since a long unchanged observation buries the
change.

### The smallest set of mechanisms

Six, with time running through all of them.

1. **The standing model of the world.** One model, held by the agent and
   carried across steps and turns, in the layers of Rensink's triad and the
   object-file work: the *setting* (which app, which kind of window, which
   state, where focus is, compact enough to carry always); a *summary* of
   everything else that is open, with no detail; the few *indexed things*
   the agent is working with, each followed through changes by its
   continuity; the agent's *body* (focus, pointer, selection, held keys,
   tools), moved forward by its own commands; and a *baseline* per channel,
   so a difference has a meaning. Every entry carries its source and age:
   seen, inferred from an act, assumed from a schema, or reported by an
   event. This is what the agent consults instead of a fresh look.
2. **Event-driven senses with an honest resync.** Senses report change
   against the standing model, by subscription where the platform allows,
   under the six rules of section 8: subscribe before reading; read only
   where an event points; coalesce; resume from a cursor; answer loss with a
   rescan; and know the coverage, which sources cannot be observed (an app
   with no tree, content drawn as pixels). Where no event can reach,
   sampling follows need and predicted error, not a clock. After any gap in
   attention (the model thinking, the person working, the machine asleep)
   the first thing is a keyframe, a comparison of model and world, because
   a change without a signal is otherwise invisible.
3. **The efference copy.** Every act is launched with a prediction of its
   effect: which events, in which element, within what time. A checker below
   the model compares what arrives. A match is absorbed: body and world
   model move forward, the act is checked off, nothing is looked at. A
   mismatch becomes an error, with what was predicted, what arrived and the
   local state. A change no act predicted is *exafference*, the world or the
   person acting, reported as such and never taken for the agent's own
   effect. For familiar acts the prediction comes from what the agent knows
   about this app, chosen by which model of it has been predicting well
   (MOSAIC, section 5); for a new act the model states it. It must be
   specific, because an expected event that does not arrive is an error and
   a vague prediction hides failure.
4. **Recognition and the schema.** On arriving anywhere the agent recognises
   the kind of place from cheap global features before reading detail, and
   the kind brings a schema: what belongs here, where it usually is, which
   states follow, what can be done. For a familiar place the schema is the
   agent's memory of it: where things were found, which transitions were
   seen, what each control did. It guides the look and supplies mechanism
   3's predictions. It is learned by finding and acting, not by reading.
   Its violations are surprises, and what it fills in is marked assumed
   until confirmed.
5. **Attention as chosen looks.** A look is an act with a price. The model
   sets templates, what it is looking for and waiting on, and the levels
   below report when they are met. A look is narrowed to the region that
   matters, made at the next landmark before the decision there is due, and
   preferred over memory only when cheaper. Errors are weighted by the
   channel's reliability; harmless repeats habituate; and a small share of
   attention stays outside the task, because a strong schema and a narrow
   task are how a gorilla goes unseen.
6. **Background regulation.** The agent's own variables (resources,
   permissions, connections, the health of each sense, whether its person is
   present) are held in range by loops below the model, predicting where
   they can, and reach awareness as a feeling only when out of range or
   about to be, computed from the measured state.

**Clocks.** Events and checks run in milliseconds; the model in seconds per
call; the standing model of the world lasts a working session and carries
across turns; schemas and what is known about each app last days to months
and are re-learned when an app changes.

### What the model receives, and what it never receives

**It receives** the gist, in a line, when a decision starts and whenever it
changes; each surprise, with the local state around it and no more;
exafference, change the agent did not cause, with its likely cause; the
answers to what it asked the levels below to find or wait for; a real look
at full resolution in the region in question when a schema breaks,
recognition fails or the stakes call for it; and its own body state when it
bears on the decision.

**It never receives** what is unchanged since it last knew it; a whole screen
or tree at every step; item-by-item confirmation of effects that went as
predicted, beyond a short receipt; pixels where structure is available, or
structure where an app's own interface answers directly; a history of past
screenshots, which the standing model replaces; or background variables in
range. This is a cortical hierarchy's division of labour: the top receives
residuals and sets templates and predictions.

**How a step goes.** In a familiar app the decision starts from the gist the
agent already holds. The model chooses a short run of acts, each with its
predicted effect. The checker launches them in turn, confirms each target
against live structure at the moment of acting (the defence against
time-of-check to time-of-use), compares each act's events with its
prediction, and stops at the first mismatch. If all match, the model gets a
receipt and the new gist; if one fails, it gets the failure, the local
state and what completed. It never reads the parts that did what was
expected. In an unfamiliar app the loop is the same with weaker predictions,
so more looks reach the model, and every confirmed or failed prediction
teaches the schema. Familiarity is the shift from many looks to few, as in
human gaze during learning (Sailer 2005).

### Where the language model sits

- **At the top, slowest and most general.** It sets goals, chooses what to
  look for, interprets surprises and states predictions for acts it has not
  made before, and should get what a cortical hierarchy's top level gets:
  residuals and answers, not raw input.
- **Not where prediction lives.** Models are barely above chance at
  predicting their own actions' effects and much better at choosing once
  told them, and they tend to act as if an action succeeded. The prediction
  for a familiar act, the check and the record of what each control does
  belong below the model, in code checked against the world.
- **Not where the world is kept.** The context is working memory, and long
  contexts degrade: the middle is used worse and distractors hurt more as
  input grows. A standing model outside the context is what keeps the
  change visible, not only what saves tokens.
- **A slow loop that must not steer fast things.** A call takes seconds,
  longer than most interface events. As with a Smith predictor, the agent
  acts on its predicted state and corrects when the real one arrives; the
  checks run without waiting for the model.
- **Skill is how little of the model perception needs.** A novice agent looks
  at everything before every act. An expert recognises the place, acts on
  predictions, and hears from its senses only when something did not go as
  expected: the deafferented man given their proprioception back.

### Key risks

- **A stale model: the phantom limb.** The schema outlives the limb; the
  standing model can describe a window that closed or a control that moved.
  *Follows:* age and source on every entry, known coverage gaps, rescan on
  loss, a keyframe after any gap, and the target confirmed live at the
  moment of action, by the checker.
- **Change blindness built in.** A change with no signal goes unseen, between
  subscriptions, in an app without notifications, while the model thinks.
  *Follows:* subscribe before reading, compare model and world after gaps,
  and never treat silence as proof where a channel has no coverage.
- **Absorbing a real failure.** A loose prediction ("something changed") lets
  a failed act pass as success, the error agents already make. *Follows:*
  predictions specific to element, kind and time; a missing predicted event
  is an error; success judged against the world by something the act cannot
  change (PRACTICE_RESEARCH.md, key risks).
- **Misattribution.** A broken efference copy makes one's own acts feel alien.
  An agent that confuses its effects with the person's will fight its own
  changes or claim someone else's. *Follows:* each act's predictions are
  recorded with it; unpredicted change is labelled as not the agent's.
- **Schema blindness.** Experts miss what the schema does not expect, and the
  schema writes expected things into memory. *Follows:* violations surface,
  assumptions are marked, a share of attention stays outside the task.
- **Capture by salience, and attacks through it.** Onsets capture attention;
  adversarial pop-ups were clicked 86% of the time and instructions to ignore
  them did not help. *Follows:* surprise is measured against the agent's own
  model and task, not by brightness or novelty; what the world shows claims a
  look, never obedience.
- **Hallucinated elements.** An index can outlive its element, and a
  grounding model can place an element where none is. *Follows:* identity by
  continuity; acts only through an index confirmed live; a remembered
  location is a hint about where to look, never a licence to act.
- **Floods and thin gists.** A busy page can emit thousands of events; a gist
  line can say "the inbox" when the decision needs which message.
  *Follows:* coalescing, adapted baselines, habituation and precision
  weights against floods; decisions about specific things made on indexed
  things that were looked at.

### Where the science is weakest

- **Predictive coding as a literal cortical algorithm.** Evidence for distinct
  prediction and error neurons is thin, and some expectation effects failed
  in monkey single units. The functional claim used here, predicted input
  discounted and surprise amplified, is well supported.
- **What attenuation is.** Cancelled or sharpened, self-specific or general to
  anything predictable: unsettled. Both readings support handling predicted
  effects cheaply.
- **How rich seeing is.** The overflow debate has no end in sight. The design
  needs only the agreed part: detail for the attended, statistics for the
  rest.
- **Effects that shrank.** Gist at 13 ms failed at 27 ms with better masking;
  automatic affordance priming is small, with publication bias; unconscious
  contextual cueing may reflect weak awareness tests; task decoding from eye
  movements is mixed; tool use may move attention rather than the body's
  edge; the rubber hand is open to demand characteristics; heartbeat counting
  failed as a measure.
- **Single cases and small samples.** The deafferented men, the kitten
  carousel and sensory substitution are vivid and consistent with larger
  literatures, not proofs.
- **Agent studies.** Short benchmarks in reset virtual machines, mostly judged
  by their authors, with numbers that move every few months. Almost none
  measure what this document is about: how much of each observation was
  unchanged, how often an agent acted on a stale state or believed a failed
  act had worked, or how an agent fares on one person's Mac over months.
- **Transfer from bodies.** A brain is bound by energy and wiring, an agent by
  tokens, latency and which apps can be observed at all. The trade between
  looking and remembering by their costs carries over as rational analysis
  (Gray 2006). Some of what bodies do may be the price of slow neurons, which
  an agent with millisecond events need not pay. Which parts are universal
  and which are biology's workarounds is the least settled question here.

For orientation: much of this already exists in the agent in parts. The
Senses render apps, files and sites as one compact page with named things,
and post news when something changes; live senses subscribe and receive
changes. The Mac control layer's closed loop installs an accessibility
observer before acting, waits for the first notification (its source records
30–32 ms), collects the burst over a short quiet window and diffs the result
against the frame the act started from: an efference copy and its check, in
code. Its graded views (a one-line glance, a structured look, a full stare)
are gist, focal look and keyframe. Waiting by signal, subscribing before
reconciling the baseline and falling back to a slow read only where no
observer can be installed, is the FSEvents rule. The per-app control maps,
verified paths that are a hint about where to look and never a licence to
act without a live read agreeing, are the schema as memory of where things
were found, with the time-of-use check built in. The Chrome extension's page
snapshots are the DOM channel, the presence sense is exafference about the
person, and the subconscious, running without the model, is where the levels
below the interpreter belong. NORTHSTAR's clauses 4 and 5 ask for this
shape: processes that respond because the signal reached them, and a world
that reaches the agent as senses, with tokens spent only on judgement. What
the science adds is aimed at the gap in the real traces, where every look
and act is still a separate model round that re-reads a large state: the
model should receive the residual (the difference from what the act
predicted), the gist and the answers to its searches; every act should carry
its prediction before it runs; a standing model of the world, with age and
source on each entry, should carry across steps and turns in place of
re-reading; coverage gaps should be known and loss answered by a rescan; the
checks at the moment of action belong below the model; and a look is an act,
chosen by its cost and by where the next decision will be.
