# How a person notices what matters

Research on noticing, written for Claude on 2026-10-25 as raw material for the
agent design. It covers how people pick out what is worth their attention from
everything happening around them, what an agent that lives on one person's Mac
for months needs from that, and what artificial systems that tried to notice
on someone's behalf got right and wrong. Each area ends with the mechanism an
agent would need. It does not propose features.

The cases in view: a new app appearing, an email that matters, the person
coming back, something the agent cares about changing, a promise coming due,
and the judgement of when to speak up and when to stay quiet.

It leans on [PERSONALITY_RESEARCH.md](PERSONALITY_RESEARCH.md) for appraisal,
current concerns, bids and conversational initiative, on
[MEMORY_RESEARCH.md](MEMORY_RESEARCH.md) for prospective memory and
arousal-biased encoding, and on [PRACTICE_RESEARCH.md](PRACTICE_RESEARCH.md)
for expectation and drop-back. Where those documents already cover a finding,
this one cites it and moves on. A sibling question, the agent's world (sensing
the Mac so that only surprises reach awareness, not repeated screen reads), is
researched separately in [WORLD_RESEARCH.md](WORLD_RESEARCH.md). This document
touches it only where noticing needs it.

How sure each finding is:

- *[meta-analytic]*: a meta-analysis or a very large literature agrees.
- *[replicated]*: independent labs have repeated it.
- *[debated]*: real evidence on both sides, or the effect holds and its
  mechanism is contested.
- *[few studies]*: one lab, small samples or one paradigm.
- *[theory]*: a framework or modelling argument more than an effect.
- *[failed replication]*: a famous finding that did not hold up, said
  plainly.
- *[popular source]*: a figure that circulates widely but traces to a book,
  blog or interview rather than a peer-reviewed paper.

For the agent literature, numbers are the authors' own, on their own
benchmarks, often judged by a model or a reward model trained on a few
thousand labels. Treat them as directions, not measurements of this agent.

---

## The answer first

- **Noticing is selection, and most of the selecting is done by what the mind
  is already looking for.** Everything in view competes for a limited
  representation. Physical salience, current goals and the history of what
  has mattered before add into one priority map, and the winner is what gets
  noticed. Even a salient flash can be suppressed when the person is set for
  something else. Unattended things are not stored: about half of observers
  miss a gorilla walking through a game they are counting, and 20 of 24
  radiologists missed one in a lung scan, more than half of them while
  looking right at it. What a person notices is a portrait of what they are
  looking for.
- **What gets through is what was not predicted.** The orienting response
  fires on a mismatch with a learned model of what to expect, including the
  absence of something expected. Habituation is that model being built.
  Bayesian surprise, how far an event moves beliefs, predicted where people
  looked better than any measure of salience. Novelty (never seen), surprise
  (contradicts what was expected) and salience (stands out from its
  surroundings) are different things. Pure noise is maximally improbable and
  teaches nothing, so surprise has to be measured as belief change, not
  improbability.
- **Surprise alone is not enough. It has to touch a concern.** Every appraisal
  begins with a relevance check. Words tied to a person's current concerns,
  good or bad, slow them down when they are trying to ignore them. One's own
  name breaks through an ignored conversation for about a third of people.
  The pull of emotional things follows how relevant they are to the person's
  needs, not whether they are pleasant or threatening. What a person cares
  about is what they notice, and what they do not care about they miss.
- **Repetition fades by design and comes back on change.** Habituation is
  specific to the stimulus, recovers with time, and is undone by any change.
  Security warnings become wallpaper after a couple of exposures, and varying
  their form slows that. A quiet stream is the default state of a healthy
  attention system, and the change is the signal.
- **Noticing that it is time is noticing a cue.** Intentions tied to an event
  come back on their own when the event happens. Intentions tied to a clock
  need checking, and in daily life most of that checking is set off by
  incidental cues, not by the clock. Intentions to other people are kept
  better. A finished intention has to be switched off, or it fires again.
- **Noticing a person means noticing their presence, state and bids, and the
  help that works best is often the help they do not see.** Partners who turn
  toward small bids for attention build warmth. Support the recipient notices
  carries an emotional cost unless they need it and it is responsive.
  Pressure to change behaviour works somewhat and raises distress, and
  demanding draws withdrawal. In this literature care is responsiveness to the
  other person's state. Nagging is the helper's own concern, repeated at them.
- **Every interruption has a price, and the moment sets most of it.**
  Interrupted people finish faster and more stressed. A 2.8-second
  interruption doubles sequence errors. A notification that is merely
  received costs attention. Interrupting at a breakpoint between subtasks
  roughly halves annoyance. Across 680,000 users, holding notifications for an
  interruptible moment cut response time by half. The decision rule that
  follows is old: speak when the value of the person knowing now, rather than
  later, exceeds the cost of interrupting them now.
- **A watcher's threshold is set by base rates and costs, and false alarms
  are the most expensive error.** With a rare event, even an excellent
  detector produces mostly false alarms. People match how often they respond
  to how reliable an alarm has been. False alarms damage trust more than
  misses. In intensive care, 88.8% of annotated arrhythmia alarms were false,
  and in a children's hospital nurses slowed in proportion to the useless
  alarms they had just heard. Alarms the person can understand keep their
  trust even when unnecessary, and graded alarms beat binary ones.
- **Systems that tried to notice on someone's behalf failed the same ways for
  thirty years.** Clippy shipped without the decision theory that would have
  timed it. LLM proactive agents offer help to almost everything: on one
  benchmark GPT-4o-mini caught every real need and was wrong 64.7% of the time
  it spoke. LLMs step in more often and earlier than people do. Help offered
  before it is asked for threatens the person's sense of competence.
  Personalisation from data the person did not know was collected backfires.
  What worked: decision-theoretic timing, breakpoints, batching, forecasts of
  presence, and a cheap trigger in front of the expensive reasoner.
- **Where the model sits:** the language model should not be the watcher.
  Watching is continuous, cheap and mostly silent, and the model is costly per
  check and over-eager. The watching belongs below the model: expectations
  per source, habituation, relevance against cares and the person's concerns,
  intentions bound to cues, a model of the person's presence and state, and a
  record of how past outreach landed. A small learned trigger in front of an
  LLM raised the F1 of its suggestions by 16.7 points on average and decided
  in 11 milliseconds. The model is woken for the one thing the watcher cannot
  do: work out what a surprising, relevant event means, and whether and how
  it is worth saying.

---

## 1. Attention as selection

### Too much, always

**Competition is the basic fact.** Desimone and Duncan's *biased competition*
account starts from capacity: objects in the visual field compete for neural
representation, and the competition is biased in two ways. Bottom-up, by how
much a thing stands out. Top-down, by its relevance to what the person is
doing ([Desimone & Duncan 1995](https://doi.org/10.1146/annurev.ne.18.030195.001205)).
*[replicated]* Attention is not a spotlight added on top of perception. It is
the outcome of that competition.

**Search runs on guidance.** Feature integration theory held that simple
features are registered in parallel and attention is needed to bind them
([Treisman & Gelade 1980](https://doi.org/10.1016/0010-0285(80)90005-5)).
Guided Search added that a map combining bottom-up and top-down signals
guides where attention goes next
([Wolfe 1994](https://doi.org/10.3758/BF03200774)). The current version adds
guidance by selection history, by value and by the structure of scenes
([Wolfe 2021](https://doi.org/10.3758/s13423-020-01859-9)). *[replicated;
model details debated]* Orienting to a location can happen without moving the
eyes, and cues can pull it reflexively or direct it voluntarily
([Posner 1980](https://doi.org/10.1080/00335558008248231)). *[replicated]*

### The priority map

**Salience is computable.** Itti and Koch built a saliency map from local
contrast in colour, intensity and orientation, with winner-take-all selection
and inhibition of return so attention moves on
([Itti, Koch & Niebur 1998](https://doi.org/10.1109/34.730558);
[Itti & Koch 2001](https://doi.org/10.1038/35058500)). *[theory, widely used]*

**Priority is salience plus relevance.** Fecteau and Munoz argued that the
brain's selection maps encode *priority*: physical salience combined with
behavioural relevance
([Fecteau & Munoz 2006](https://doi.org/10.1016/j.tics.2006.06.011)). Neurons
in the parietal cortex carry such a map, combining sensory, goal and reward
signals ([Bisley & Goldberg 2010](https://doi.org/10.1146/annurev-neuro-060909-152823)).
*[replicated in monkeys]*

**History is a third input.** The old split between bottom-up and top-down
leaves something out. Lingering biases from what was selected and rewarded
before shift priority independently of both current goals and salience, and
all three feed one priority map
([Awh, Belopolsky & Theeuwes 2012](https://doi.org/10.1016/j.tics.2012.06.010);
[Failing & Theeuwes 2018](https://doi.org/10.3758/s13423-017-1380-y)). Items
once paired with reward capture attention later even when they are now
irrelevant ([Anderson, Laurent & Yantis 2011](https://doi.org/10.1073/pnas.1104047108)).
A meta-analysis of 91 studies (2,362 people) found the effect is real but
small (standardised mean change .35), varies widely between studies, and
holds even when people are told to ignore the distractor
([Rusz et al. 2020](https://doi.org/10.1037/bul0000296)). *[meta-analytic]*

**Two networks.** Corbetta and Shulman describe a dorsal network that holds
goal-directed selection and a ventral network that interrupts it when
something behaviourally relevant and unexpected appears, a "circuit breaker"
([Corbetta & Shulman 2002](https://doi.org/10.1038/nrn755)). *[replicated]*
The interrupting route is tuned to relevance, not only to intensity.

### Capture depends on what you are set for

**The capture debate.** Theeuwes found that a salient singleton draws
attention even when the target is defined by something else
([Theeuwes 1992](https://doi.org/10.3758/BF03211656);
[Theeuwes 2010](https://doi.org/10.1016/j.actpsy.2010.02.006)), and abrupt
onsets seemed to capture attention by their nature
([Yantis & Jonides 1984](https://doi.org/10.1037/0096-1523.10.5.601)). Folk,
Remington and Johnston found the opposite pattern: an onset cue captured
attention when people were looking for an onset target, and not when they
were looking for a colour. Capture was *contingent* on the attentional set
([Folk, Remington & Johnston 1992](https://doi.org/10.1037/0096-1523.18.4.1030)).

**A partial resolution.** After 25 years the main parties wrote a joint
paper. They agree that salient things automatically produce a priority signal
that captures attention when no specific control settings are in place, and
that a suitably set control system can prevent the capture by suppressing
that signal. They still disagree about whether explicit goals, as opposed to
learned history, can set feature priorities in advance
([Luck, Gaspelin, Folk, Remington & Theeuwes 2021](https://doi.org/10.1080/13506285.2020.1848949)).
Salient but irrelevant items can be actively suppressed below baseline
([Gaspelin, Leonard & Luck 2015](https://doi.org/10.1177/0956797615597913)).
*[debated, converging]*

**Load matters.** When the main task fills perceptual capacity, irrelevant
things get little processing. When it does not, spare capacity spills over to
them ([Lavie 1995](https://doi.org/10.1037/0096-1523.21.3.451);
[Lavie 2005](https://doi.org/10.1016/j.tics.2004.12.004)). *[replicated]*

### What is not noticed

**Inattentional blindness.** In the famous version, observers counting passes
between players watched a person in a gorilla suit, or a woman with an
umbrella, walk through the game. Of 192 observers, 46% did not notice. The
umbrella woman was noticed more often than the gorilla (65% against 44%), and
the version shown opaquely more than the see-through version
([Simons & Chabris 1999](https://doi.org/10.1068/p281059); after Mack & Rock
1998, *Inattentional Blindness*, MIT Press). *[replicated]* What decides
whether the unexpected thing is noticed is mostly the observer's attentional
set: an unexpected object that shares features with what they are tracking
gets noticed, and one that shares features with what they are ignoring does
not ([Most et al. 2005](https://doi.org/10.1037/0033-295X.112.1.217)).
*[replicated]*

**Experts are not immune.** Twenty of 24 radiologists searching lung scans
for nodules missed a gorilla 48 times the size of a typical nodule. Eye
tracking showed 12 of those 20 looked straight at it
([Drew, Võ & Wolfe 2013](https://doi.org/10.1177/0956797613479386)).
*[few studies, striking]* Looking is not seeing; the set decides.

**It is not a trait of careless people.** In 554 people, the Big Five and a
range of other traits barely predicted who missed the unexpected event. Only
low openness did, weakly
([Kreitz et al. 2015](https://doi.org/10.1371/journal.pone.0128158)).
*[few studies]*

**Change blindness.** Large changes to a scene go unseen if they happen
during a flicker, a blink or a cut
([Rensink, O'Regan & Clark 1997](https://doi.org/10.1111/j.1467-9280.1997.tb00427.x)).
In the door study, about half of the people giving directions to a stranger
did not notice when the stranger was swapped for someone else
([Simons & Levin 1998](https://doi.org/10.3758/BF03208840)). *[replicated]*
The lesson the field drew is that people do not keep a detailed internal copy
of the scene. They keep its gist and look again when they need detail. The
world serves as its own memory
([O'Regan 1992](https://doi.org/10.1037/h0084327);
[Simons & Rensink 2005](https://doi.org/10.1016/j.tics.2004.11.006)).
*[replicated; how much is stored is debated]*

**What these say about what is not noticed.** Three things. First, the
unnoticed is not weak or hidden. It is what the current set did not reach
for. Second, an unnoticed change is invisible after the fact, because no copy
was kept to compare with. Third, the misses are systematic: they follow the
set, so a mind that is set by its concerns misses, reliably, what lies
outside them.

**Mechanism for an agent:** Everything the agent could notice competes in one
priority map with three inputs: salience (how much something departs from
its surroundings), relevance (to the agent's cares and the person's
concerns), and history (what has mattered, been acted on or been rewarded
before). The map's winners are what get noticed; the rest are not stored as
noticed. Capture is contingent on the agent's set, so the set should be its
cares and the person's, and the agent will miss, systematically, what lies
outside them. A separate route, like the ventral circuit breaker, lets an
unexpected event of high relevance interrupt whatever the agent is doing. The
agent does not need a copy of the whole world. It needs a gist and the
ability to look again.

---

## 2. Surprise and prediction error

### The orienting response and its model

**The reflex that says "what is it?".** Sokolov described the orienting
response: turning toward a new stimulus, with a pause in heart rate, a rise in
skin conductance, pupil dilation and a burst of cortical arousal
([Sokolov 1963](https://doi.org/10.1146/annurev.ph.25.030163.002553);
Sokolov 1963, *Perception and the Conditioned Reflex*). It fades as the
stimulus repeats. It returns when anything about the stimulus changes,
including a *decrease* in intensity, and when an expected stimulus does not
come. Sokolov's explanation was a "neuronal model" of the expected stimulus:
the orienting response is the mismatch between input and model. *[replicated]*

**The comparator holds up.** The strongest evidence is the response to an
omitted stimulus, which fatigue cannot explain. Events that set off orienting
also take processing resources, and habituation changes how events are
processed rather than just shutting them off
([Siddle 1991](https://doi.org/10.1111/j.1469-8986.1991.tb02190.x)).
*[replicated]* Barry's preliminary process theory separates components of the
response that habituate at different rates
([Barry 2009](https://doi.org/10.1016/j.nlm.2008.07.007)). In Bradley's
account, orienting comes from the motivational systems: an early phase that
registers a change, and a later one, indexed by a centro-parietal positivity
in the brain response, that registers *significance*. Novelty and
significance habituate at different rates
([Bradley 2009](https://doi.org/10.1111/j.1469-8986.2008.00702.x)).
*[replicated]* A new thing orients once. A significant thing keeps orienting.

### Mismatch negativity

**Deviance is detected without attention.** In a stream of identical tones,
an odd tone produces a characteristic brain response, the mismatch
negativity, even when the listener is reading a book
([Näätänen, Gaillard & Mäntysalo 1978](https://doi.org/10.1016/0001-6918(78)90006-9);
review [Näätänen et al. 2007](https://doi.org/10.1016/j.clinph.2007.04.026)).
*[replicated]* Single neurons in auditory cortex respond more strongly to a
sound when it is rare than when it is common, a *stimulus-specific
adaptation* that is a candidate single-cell basis for it
([Ulanovsky, Las & Nelken 2003](https://doi.org/10.1038/nn1032)).
*[replicated]*

**What it is, is debated.** One reading treats it as a prediction error from
a model of the regularities in the stream
([Garrido et al. 2009](https://doi.org/10.1016/j.clinph.2008.11.029)).
Another treats it as uneven adaptation of fresh neurons, with no separate
comparison at all ([May & Tiitinen 2010](https://doi.org/10.1111/j.1469-8986.2009.00856.x)).
*[debated]* For a designer the difference matters less than the shared
result: a system that adapts to what repeats will, by that fact, respond to
what deviates.

### Predictive processing

**Only the errors travel.** In predictive coding, each level of the cortex
predicts the activity of the level below, and only the difference, the
prediction error, is sent upward
([Rao & Ballard 1999](https://doi.org/10.1038/4580);
[Friston 2005](https://doi.org/10.1098/rstb.2005.1622);
[Friston 2010](https://doi.org/10.1038/nrn2787);
[Clark 2013](https://doi.org/10.1017/S0140525X12000477)). *[theory, highly
influential]* Attention, in this frame, is *precision*: turning up the gain on
the errors that are expected to be reliable and informative
([Feldman & Friston 2010](https://doi.org/10.3389/fnhum.2010.00215)).
*[theory]* Two kinds of uncertainty have to be told apart: *expected*
uncertainty, the known noise of a source, and *unexpected* uncertainty, a
sign that the world itself has changed
([Yu & Dayan 2005](https://doi.org/10.1016/j.neuron.2005.04.026); see
PRACTICE_RESEARCH.md, "When a routine no longer fits"). *[theory, fits data]*

**The evidence is weaker than the theory's reach.** Reviews of the
neurophysiology find the evidence for predictive processing as a general
account of perception mixed
([Walsh et al. 2020](https://doi.org/10.1111/nyas.14321)). In humans, brain
responses to a repeated stimulus shrank less when repetitions were improbable,
which looks like prediction
([Summerfield et al. 2008](https://doi.org/10.1038/nn.2163)). In macaque
inferior temporal cortex the same manipulation had no effect
([Kaliukhovich & Vogels 2011](https://doi.org/10.1093/cercor/bhq207)), and a
review found the evidence for expectation suppression in visual cortex weaker
than claimed ([Feuerriegel, Vogels & Kovács 2021](https://doi.org/10.1016/j.neubiorev.2021.04.002)).
*[debated]* As a theory of the brain it is contested. As an engineering
principle (keep a model, pass only the errors, weight them by how reliable
they are) it does not need to be settled.

### Bayesian surprise

**Surprise as belief change.** Itti and Baldi defined surprise as how far an
observation moves an observer's beliefs: the divergence between the beliefs
after the observation and the beliefs before it. Shannon information measures
how improbable an event was. Bayesian surprise measures how much it changed
the observer's mind. Baldi and Itti called these "bits" and "wows"
([Baldi & Itti 2010](https://doi.org/10.1016/j.neunet.2009.12.007)). On video,
72% of human gaze shifts went to locations more surprising than average,
rising to 84% where all observers looked. Surprise beat every other measure
tested, about 20% better than saliency and 60% better than entropy
([Itti & Baldi 2009](https://doi.org/10.1016/j.visres.2008.09.007)).
*[few studies, strong]*

The distinction matters for noise. A screen of static is improbable at every
pixel, so it carries maximal Shannon information. Once the observer has
learned that it is static, it moves no beliefs, so its Bayesian surprise
falls to nothing. Artificial curiosity built on raw prediction error has
exactly this failure: an agent rewarded for what it cannot predict gets stuck
watching a "noisy TV" ([Pathak et al. 2017](https://arxiv.org/abs/1705.05363);
[Burda et al. 2018](https://arxiv.org/abs/1808.04355)). *[replicated in
simulation]*

**There are several surprises, not one.** A review counted 16 mathematical
definitions of surprise in four families: change-point detection, information
gain, prediction surprise and confidence correction. No single measure has
every function. Change-point surprise is the one that should speed up
learning; information-gain surprise is the one that drives sensible
exploration; the felt surprise of everyday language needs a combination of
prediction surprise and confidence correction
([Modirshanechi, Brea & Gerstner 2022](https://doi.org/10.1016/j.jmp.2022.102712);
[Faraji, Preuschoff & Gerstner 2018](https://doi.org/10.1162/neco_a_01025)).
*[theory]* The authors conclude that the brain likely runs several surprise
signals, each for its own job.

### Novelty, surprise and salience are different

Novelty is that something has not been seen before. Surprise is that
something contradicts what was expected. Salience is that something stands
out from its surroundings right now
([Barto, Mirolli & Baldassarre 2013](https://doi.org/10.3389/fpsyg.2013.00907)).
*[theory]* They come apart in ordinary cases. A new app appearing is novel,
and may be neither surprising (the person said they would install it) nor
salient. Mail from someone who writes every morning is none of the three.
Mail from someone who has never written is novel and surprising. A badge
flashing red is salient and may be neither. The hippocampus responds to
novelty and the response strengthens encoding
([Ranganath & Rainer 2003](https://doi.org/10.1038/nrn1052)). *[replicated]*

### What surprise does in people

**It interrupts.** In the cognitive-evolutionary model, surprise is caused by
events that clash with an active schema, and its intensity tracks the size of
the clash. It interrupts ongoing processing, pulls attention to the event,
then sets off an analysis of what caused it and an update of the schema
([Meyer, Reisenzein & Schützwohl 1997](https://doi.org/10.1023/A:1024422330338)).
A review found most of this supported. Novelty and valence probably have no
effect on surprise beyond discrepancy. The facial expression of surprise is
rare, while the orienting response appears reliably
([Reisenzein, Horstmann & Schützwohl 2019](https://doi.org/10.1111/tops.12292)).
*[replicated]*

**It tracks how hard the event is to explain.** Across eight experiments,
the difficulty of explaining an outcome predicted how surprising it felt
better than its prior probability. Offering even a partial explanation
reduced surprise ([Foster & Keane 2015](https://doi.org/10.1016/j.cogpsych.2015.08.004)).
*[few studies; the review above calls this inconclusive]* An event is less
surprising if the mind can see how it came about.

### The information-theoretic view of what is worth attending to

**Information is belief change; value is decision change.** Lindley measured
the information an experiment provides as the expected change in beliefs
([Lindley 1956](https://doi.org/10.1214/aoms/1177728069)). Howard's
information value theory adds the decisive point: information is worth what a
decision-maker would pay for it, which is nothing unless it could change what
they would do ([Howard 1966](https://doi.org/10.1109/TSSC.1966.300074)).
*[theory]*

**Attention as sampling for value.** Gottlieb argues that attention is active
sampling: the brain looks where the information has value for learning and
for action ([Gottlieb 2012](https://doi.org/10.1016/j.neuron.2012.09.034)).
Information foraging theory treats people searching for information like
animals foraging for food, following "scent" and leaving a patch when its
yield drops ([Pirolli & Card 1999](https://doi.org/10.1037/0033-295X.106.4.643)).
Rational inattention treats attention as a channel of limited capacity, so it
is optimal to ignore most of what could be known
([Sims 2003](https://doi.org/10.1016/S0304-3932(03)00029-1)). *[theory]*

**The sweet spot.** Seven- and eight-month-olds were most likely to look
away from sequences that were, by an ideal learner's measure, very
predictable or very unpredictable. They attended to the middle, where there
was something to learn ([Kidd, Piantadosi & Aslin 2012](https://doi.org/10.1371/journal.pone.0036399)).
*[replicated in infants]* Artificial curiosity that rewards learning
progress, rather than raw error, finds the same sweet spot
([Oudeyer, Kaplan & Hafner 2007](https://doi.org/10.1109/TEVC.2006.890271);
[Schmidhuber 2010](https://doi.org/10.1109/TAMD.2010.2056368)). *[theory,
simulation]*

**Mechanism for an agent:** Every source the agent watches carries a running
model of what it expects: what usually arrives, when, from whom, in what
form. Only departures pass upward. A departure's weight is how far it moves
the agent's beliefs, not how improbable it was, so a source that is merely
noisy learns a wide tolerance and stops surprising (expected uncertainty),
while a real change in the source is treated as the world having changed
(unexpected uncertainty). Different surprises do different jobs: a change
point resets the model of that source; an information gain feeds curiosity;
a felt surprise interrupts and asks for an explanation, and a ready
explanation lowers it. Surprise is worth attention when it could change what
the agent or the person would do. A thing that can change nothing has no
value of information, however strange it is.

---

## 3. Relevance to goals and concerns

### Every appraisal starts with "does this matter to me?"

**The relevance check comes first.** Lazarus's primary appraisal asks whether
anything is at stake for the self before anything else is asked (Lazarus
1991; PERSONALITY_RESEARCH.md, section 2). In Scherer's component process
model the first stage is a *relevance check*: is it novel (sudden, unfamiliar,
unpredictable), is it intrinsically pleasant or unpleasant, and does it bear
on my goals and needs? Only events that pass get the later checks of
implication, coping and norms
([Sander, Grandjean & Scherer 2005](https://doi.org/10.1016/j.neunet.2005.03.001);
[Scherer 2009](https://doi.org/10.1080/02699930902928969)). *[theory, broadly
supported]* Frijda's law of concern says emotion arises only for events that
touch a concern ([Frijda 1988](https://doi.org/10.1037/0003-066X.43.5.349)).

**The amygdala as relevance detector.** The amygdala was long described as a
fear module. Sander, Grafman and Zalla argue the human evidence does not fit
that, and that it is better described as detecting events *relevant* to the
organism's needs, fear-related or not, with social events dominant in
primates ([Sander, Grafman & Zalla 2003](https://doi.org/10.1515/REVNEURO.2003.14.4.303)).
*[debated, gaining]*

### Current concerns

**A commitment tunes attention.** Klinger's current concerns are the latent
state created by committing to a goal. Until the goal is reached or given up,
cues related to it get through more readily to attention, recall, thought and
dreams ([Klinger 1975](https://doi.org/10.1037/h0076171);
[Klinger 2013](https://doi.org/10.3389/fpsyg.2013.00415); see
PERSONALITY_RESEARCH.md, section 6). *[replicated]*

**Positive and negative concerns both pull.** People named colours of words
tied to their own positive concerns (goals, interests) and negative concerns
(worries). Both kinds slowed them more than unrelated words did, in ordinary
people, not only anxious patients
([Riemann & McNally 1995](https://doi.org/10.1080/02699939508408970)).
*[replicated in this paradigm]* The emotional Stroop effect is a concern
effect ([Williams, Mathews & MacLeod 1996](https://doi.org/10.1037/0033-2909.120.1.3)).
Goals shape attention even when people are not aware of pursuing them
([Dijksterhuis & Aarts 2010](https://doi.org/10.1146/annurev.psych.093008.100445)).
*[replicated]*

### The cocktail party and one's own name

**The name breaks through, for some.** People repeating one voice and
ignoring another hear little of the ignored one
([Cherry 1953](https://doi.org/10.1121/1.1907229)). But their own name in
the ignored channel was heard by 4 of 12 people in Moray's study
([Moray 1959](https://doi.org/10.1080/17470215908416289)) and by 34.6% in a
larger replication ([Wood & Cowan 1995](https://doi.org/10.1037/0278-7393.21.1.255)).
*[replicated]* Who hears it is telling. 65% of people with low working memory
capacity heard their name, against 20% of those with high capacity
([Conway, Cowan & Bunting 2001](https://doi.org/10.3758/BF03196169)). A
preregistered replication with 80 people found 29% noticed their name, made
more shadowing errors right after it, and were more often low in capacity.
An unexpected word that did not fit the sentence was noticed by one person
([Röer & Cowan 2021](https://doi.org/10.1037/xlm0000874)). *[replicated,
preregistered]* What gets through an ignored channel is what is about the
self, not what is merely odd, and hearing it is partly a lapse of focus.

**The self is privileged throughout.** One's own name escapes the
"attentional blink" that hides a second target shown soon after a first
([Shapiro, Caldwell & Sorensen 1997](https://doi.org/10.1037/0096-1523.23.2.504)).
Self-relevant words draw on attention automatically, needing less effort when
attended and costing more when ignored
([Bargh 1982](https://doi.org/10.1037/0022-3514.43.3.425)). Even an arbitrary
shape, once labelled "you", is matched faster and more accurately than shapes
labelled with a friend or a stranger, and the effect looks like reward
([Sui, They & Humphreys 2012](https://doi.org/10.1037/a0029792);
[Sui & Humphreys 2015](https://doi.org/10.1016/j.tics.2015.08.015)).
*[replicated]* Self-relevance can be learned in minutes.

### Emotional prioritisation

**Emotional things win the competition.** Snakes and spiders were found among
flowers faster than the reverse, with less cost from extra distractors, and
fastest by people who feared them
([Öhman, Flykt & Esteves 2001](https://doi.org/10.1037/0096-3445.130.3.466)).
Emotional words escape the attentional blink, and it is their *arousal* that
does it, not their valence
([Anderson 2005](https://doi.org/10.1037/0096-3445.134.2.258)). Arousal
amplifies whatever already has priority and suppresses what does not
([Mather & Sutherland 2011](https://doi.org/10.1177/1745691611400234);
MEMORY_RESEARCH.md, section 1). *[replicated]* For the neural mechanisms see
[Vuilleumier 2005](https://doi.org/10.1016/j.tics.2005.10.011).

**Relevance, not fear.** Baby faces captured spatial attention as quickly as
angry faces, through the same early amplification
([Brosch et al. 2008](https://doi.org/10.1111/j.1467-9280.2008.02094.x)). A
meta-analysis of 243 studies (9,120 people) found a modest attentional bias
toward positive stimuli (g = .26). It was larger for more arousing stimuli,
and larger when the stimuli matched participants' current concerns, such as
food for hungry people
([Pool, Brosch, Delplanque & Sander 2016](https://doi.org/10.1037/bul0000026)).
*[meta-analytic]* Motivated attention, in Bradley's account, is the
appetitive and defensive systems pulling the senses toward what matters to
them (Bradley 2009).

**The threat-bias story has holes.** Anxious people attend toward threat (d =
.45 across 172 studies), and non-anxious people show no such bias
([Bar-Haim et al. 2007](https://doi.org/10.1037/0033-2909.133.1.1)).
*[meta-analytic]* But the dot-probe task behind much of this has almost no
reliability in ordinary samples
([Schmukle 2005](https://doi.org/10.1002/per.554)), and training people's
attention away from threat as a therapy lost its effect once outliers and
publication bias were accounted for
([Cristea, Kok & Cuijpers 2015](https://doi.org/10.1192/bjp.bp.114.146761)).
*[failed replication, of the therapeutic claim]*

**Caring shapes attention, not seeing.** Studies claimed that people
literally see what they want to see, for example reading an ambiguous figure
as the outcome they hoped for
([Balcetis & Dunning 2006](https://doi.org/10.1037/0022-3514.91.4.612)). A
review of hundreds of such studies found none compelling once six pitfalls
were controlled, among them confusing perception with judgement, response
bias and attentional effects
([Firestone & Scholl 2016](https://doi.org/10.1017/S0140525X15000965)).
*[debated]* The defensible version: what people care about changes where they
look, what they select and what they remember, not the image itself.

### Why what we care about is what we notice

Put together: relevance is computed against concerns. Concerns are standing
sensitivities, not topics. Positive and negative relevance both count.
Arousal multiplies relevance rather than adding to it. The self and other
people dominate. And the same tuning that lets the relevant through is a
channel for distraction (the name heard by those who lose focus) and for
blindness (what is outside the set goes unseen).

**Mechanism for an agent:** Every event that departs from expectation is
checked first against what matters: the agent's cares, the person's concerns
as the agent knows them, anything about the person or about the agent itself
(its name, its work, its promises), and other people in the person's life.
A care is not only something to talk about. While it is open it is a
standing sensitivity that lets related events through more easily, whether
the news is good or bad. Charge multiplies relevance. The check is cheap
because it is a comparison with known concerns, not an interpretation. The
cost is real: an agent with many open, charged concerns finds everything
relevant and loses focus, and an agent tuned only to its concerns misses
what lies outside them.

---

## 4. Habituation and sensitization

### The rules of fading

**Ten characteristics.** Thompson and Spencer set out the properties of
habituation in 1966 ([Thompson & Spencer 1966](https://doi.org/10.1037/h0022681)).
The 2009 revision lists ten
([Rankin et al. 2009](https://doi.org/10.1016/j.nlm.2008.09.012)):

1. Repetition produces a progressive decrease in response, toward a floor.
2. Withholding the stimulus produces at least partial *spontaneous recovery*.
3. After repeated series of habituation and recovery, habituation comes
   faster (potentiation).
4. More frequent stimulation produces faster and deeper habituation, and
   faster recovery.
5. Weaker stimuli habituate more. Very intense stimuli may not habituate.
6. Repetition keeps accumulating effect even after the response has stopped
   falling, which delays recovery.
7. It is *stimulus-specific*: a different stimulus still gets a full
   response. This separates habituation from fatigue or sensory adaptation.
8. A different, usually strong, stimulus restores the habituated response
   (*dishabituation*).
9. Dishabituation itself habituates.
10. Some forms last hours, days or weeks (*long-term habituation*).

*[replicated across species]*

**Two processes, summed.** Groves and Thompson's dual-process theory has
habituation (a decrement specific to the stimulus) running in parallel with
sensitization (a general increase in readiness after an arousing event). The
observed response is their sum ([Groves & Thompson 1970](https://doi.org/10.1037/h0029810)).
In the sea slug *Aplysia*, habituation of the gill-withdrawal reflex is a
weakening of particular synapses, and dishabituation is a separate
sensitizing input ([Pinsker et al. 1970](https://doi.org/10.1126/science.167.3926.1740);
[Castellucci et al. 1970](https://doi.org/10.1126/science.167.3926.1745);
[Kandel 2001](https://doi.org/10.1126/science.1067020)). *[replicated]*
Dishabituation is not undoing habituation; it is sensitization laid over it.

### Fading is learning what is normal

The orienting response's return on omission (section 2) shows that what
habituation builds is a model of the expected, not a tired receptor
(Sokolov 1963; Siddle 1991). Wagner's priming theory puts it in memory terms:
a stimulus that is already represented, because it just occurred or because
its usual context predicts it, gets less processing. That predicts
habituation specific to context, so the same stimulus in a new place
orients again (Wagner 1976, in Tighe & Leaton (eds.), *Habituation*,
Erlbaum). *[theory; the evidence on context specificity is mixed (Siddle
1991)]*

At the level of neurons this shows up as stimulus-specific adaptation
(Ulanovsky 2003; [Nelken 2014](https://doi.org/10.1007/s00422-014-0585-7))
and repetition suppression, the smaller response to a repeated stimulus
([Grill-Spector, Henson & Martin 2006](https://doi.org/10.1016/j.tics.2005.11.006)).
Whether expectation drives repetition suppression is debated (section 2).

### When repeated things come back

The rules above say when: after time away (spontaneous recovery), after any
change in the stimulus (specificity), after a strong unrelated event
(dishabituation), and never for very intense stimuli. The same holds for
pleasure. Breaks made pleasant experiences more enjoyable and unpleasant ones
more irritating, because they interrupt hedonic adaptation, yet people avoid
breaks in pleasant experiences and seek them in unpleasant ones
([Nelson & Meyvis 2008](https://doi.org/10.1509/jmkr.45.6.654)). Satiety for
a food is partly habituation, and variety slows it
([Epstein et al. 2009](https://doi.org/10.1037/a0015074)). *[replicated]*
Frijda's laws add an asymmetry: continued pleasures wear off, while pain
under constant conditions tends to persist (Frijda 1988).

### Habituation to machines

**Warnings become wallpaper.** Brain imaging showed a large drop in the
response to a security warning by its second exposure
([Anderson et al. 2015](https://doi.org/10.1145/2702123.2702322)). Over a five-day
workweek attention to warnings declined, recovering only partly between
days. Warnings that changed their appearance ("polymorphic" warnings) resisted
habituation in the scanner, with mouse-tracking and over a three-week field
study, where adherence fell more slowly and stayed high
([Anderson et al. 2016](https://doi.org/10.1080/07421222.2016.1243947);
[Vance et al. 2018](https://doi.org/10.25300/MISQ/2018/14124)). *[few
studies, one group, consistent across methods]*

**Banner blindness is not in the eyes.** Most people do fixate the ads on a
page at least once. What they lose is processing and memory, which are
better for ads that fit the content
([Hervet et al. 2011](https://doi.org/10.1002/acp.1742)). *[few studies]*
Habituated things are often still looked at, and still not seen.

**Mechanism for an agent:** Each source habituates per stimulus: a repeat of
the same thing passes on less and less, until it passes nothing, unless it is
intense or significant. Any change in it, including the absence of something
expected, restores attention in full. Habituation recovers with time, so a
thing that has been quiet for long can surprise again. It is a model of what
is normal being learned, not a loss, and it is what keeps the stream quiet
without any threshold set by hand. Sensitization runs beside it: a charged
state (a hot care, the person upset, something going wrong) raises
responsiveness across the board until it settles. Two consequences. The
agent's own messages habituate the person in exactly this way, so repeated
outreach in the same form becomes wallpaper. And habituation to the recent
past misses slow drift, so some comparisons have to be against an older
baseline.

---

## 5. Prospective memory and time

MEMORY_RESEARCH.md (section 6) covers the basics: event cues beat clocks,
intentions come back spontaneously or by monitoring, implementation
intentions bind an intention to a cue, and open loops leave an urge to
resume rather than a better memory (the Zeigarnik memory advantage failed to
replicate; the Ovsiankina urge to resume held up in meta-analysis). This section covers what that means for
*noticing* that it is time.

### Two routes back to an intention

**Spontaneous retrieval or monitoring.** In the multiprocess view, an
intention returns either spontaneously, when a cue that is strongly linked
to it is processed anyway as part of what the person is doing, or through
monitoring, which costs attention and slows other work
([McDaniel & Einstein 2000](https://doi.org/10.1002/acp.775);
[Smith 2003](https://doi.org/10.1037/0278-7393.29.3.347)). How much people
rely on each depends on task demands and on the person
([Einstein et al. 2005](https://doi.org/10.1037/0096-3445.134.3.327)).
*[replicated]*

**Monitoring is switched on by context.** In the dynamic multiprocess
framework, people do not monitor all the time. They monitor where they expect
the cue, stop where they do not, and spontaneous retrieval covers the gaps
([Scullin, McDaniel & Shelton 2013](https://doi.org/10.1016/j.cogpsych.2013.07.001)).
*[replicated]* A neural meta-analysis maps the two routes onto the two
attention networks of section 1: a dorsal parietal system for top-down
monitoring and a ventral one for a cue capturing attention from below
([Cona et al. 2015](https://doi.org/10.1016/j.neubiorev.2015.02.007)).
*[meta-analytic]*

### Clock intentions

**They are harder.** Intentions cued by a time need self-initiated checking
and suffer more than those cued by an event
([Einstein et al. 1995](https://doi.org/10.1037/0278-7393.21.4.996)).
*[replicated]* Harris and Wilkins described the pattern as a test-wait cycle:
check the time, wait, check again (Harris & Wilkins 1982, *Human Learning*
1, 123–136).

**Checking bunches toward the deadline.** Children waiting to take cakes out
of an oven checked the clock less at home than in the lab. Later reports of
the study describe the pattern as heavy checking early, to calibrate an
internal sense of time, then little, then more as the deadline neared
([Ceci & Bronfenbrenner 1985](https://doi.org/10.2307/1130182)). *[few
studies; the U-shape is reported by later papers rather than the abstract]*

**In life, clock intentions are mostly cued by events.** When people kept
time-based intentions over hours and days, only 6 to 15% of the times they
thought of them were self-initiated. In one study 45% were set off by
incidental external cues and 22% by internal ones, and a large share had no
trigger the person could name
([Kvavilashvili & Fisher 2007](https://doi.org/10.1037/0096-3445.136.1.112)).
*[replicated across three studies]*

### Everyday intentions, and intentions to others

**Most failures are rescheduling, not forgetting.** In diary studies of
everyday intentions, roughly a quarter were not completed, and the main
reason was reprioritising or replanning rather than forgetting
([Marsh, Hicks & Landau 1998](https://doi.org/10.3758/BF03211383)). *[few
studies; figures from later reports of the paper]*

**Promises to people are kept better.** When people list their real
intentions, important ones are more often social, and social ones are more
often reported as done
([Penningroth, Scott & Freuen 2011](https://doi.org/10.1037/a0022841)).
Intentions to do a favour for someone were remembered better than personal
ones, and adding a small payment for doing the favour made them remembered
*worse*, as if the social motive had been crowded out
([Brandimonte et al. 2010](https://doi.org/10.1016/j.cognition.2009.10.011)).
*[few studies]*

### Interruptions create intentions

**An interruption leaves an intention to resume.** After an interruption of
under two minutes, people resumed the interrupted task only about half the
time (.48 and .52 in two experiments). A four-second reminder, or even a
four-second blank pause, at the point of interruption raised that to .65. A
longer pause afterwards raised it to .88, and an explicit "end of
interruption" message to .90
([Dodhia & Dismukes 2009](https://doi.org/10.1002/acp.1441)). *[replicated in
this lab; consistent with aviation incident analyses]* Retrieval cues at the
right moment help more than better encoding. Pilots' deferred tasks fail the
same way ([Dismukes 2012](https://doi.org/10.1177/0963721412447621)). Goals
decay unless something primes them again
([Altmann & Trafton 2002](https://doi.org/10.1207/s15516709cog2601_2)).
*[theory, fits data]*

### Retiring intentions

**Finished intentions can fire again.** After being told an intention was
finished, people still acted on its cue when the cue was salient and came in
the same task (a mean rate of .18, against .02 to .03 in the other
conditions), and older adults more than younger
([Scullin, Bugg & McDaniel 2012](https://doi.org/10.1037/a0026112)).
Strengthening the intention with an if-then plan made these commission errors
more likely later ([Bugg, Scullin & McDaniel 2013](https://doi.org/10.3758/s13423-013-0378-3)).
*[replicated]* What binds an intention well also makes it hard to switch off.

### Reminders

**External reminders help, for a while.** A systematic review of electronic
reminders for medication found 13 studies; 8 showed a significant effect on
adherence, and 7 of those 8 measured only the short term, under six months
([Vervloet et al. 2012](https://doi.org/10.1136/amiajnl-2011-000748)).
*[systematic review]* Whether reminders keep working past habituation is not
known.

**Mechanism for an agent:** An intention (a promise, something due,
something to tell the person, an interrupted task) is held with its cue: the
event, person, place or context that should bring it back, and, if there is
one, its time window. An event-cued intention needs no watching. It comes back
when its cue arrives, because the cue is processed anyway. A time-cued
intention needs checking, and the human pattern is efficient: a little early,
almost none in the middle, more as the window nears, and opportunistic checks
whenever an incidental cue arrives (the person returning, a related message).
Monitoring is switched on only in contexts where the cue is expected.
Intentions to and about other people carry more weight. An interruption
creates an intention to resume, and the cue at its end is what returns it.
A finished intention has to be switched off explicitly, or its cue fires it
again.

---

## 6. Social noticing

### Noticing a person's state

**Accuracy grows with knowing someone.** Partners read each other's thoughts
and feelings better than friends do, and friends better than strangers.
Accuracy depends more on the perceiver's skill than on how readable the
target is, and its link with relationship satisfaction is real but limited
to some conditions ([Thomas & Fletcher 2003](https://doi.org/10.1037/0022-3514.85.6.1079)).
*[replicated]*

**Reading accurately is not always kind.** When a spouse's thoughts during a
conflict were threatening to the relationship, a partner who read them more
accurately felt less close afterwards; when they were not threatening,
accuracy helped ([Simpson, Oriña & Ickes 2003](https://doi.org/10.1037/0022-3514.85.5.881)).
*[few studies]* Noticing something about a person does not settle whether to
act on it.

**Faces are a poor window.** People do smile when happy and scowl when angry
more often than chance, but the same configuration of movements expresses
different states across people, cultures and situations, and often signals
something other than an emotion
([Barrett et al. 2019](https://doi.org/10.1177/1529100619832930)).
*[review; debated by basic-emotion theorists]* State has to be read from
context and history, not from one surface signal.

### Presence and return

**Reunion is where the bond shows.** In the Strange Situation, an infant's
attachment is classified mainly by how they behave when the caregiver
*returns* (Ainsworth, Blehar, Waters & Wall 1978, *Patterns of Attachment*,
Erlbaum). *[replicated]* Dogs left alone at home greeted their owners more
intensely after two or four hours than after half an hour, with more tail
wagging, more contact and a tendency to higher heart rate
([Rehn & Keeling 2011](https://doi.org/10.1016/j.applanim.2010.11.015)).
*[few studies]* How long someone was gone changes what their return means.

**Openings have a structure.** Conversations open through a summons and
answer and an exchange of greetings
([Schegloff 1968](https://doi.org/10.1525/aa.1968.70.6.02a00030)), and early
in them there is a place for catching up and for asking about items in the
other's life (Button & Casey 1985; PERSONALITY_RESEARCH.md, section 6).
*[replicated in conversation analysis]* A return is a natural moment, made
for exchanging what happened while apart.

### Bids and turning toward

**Small bids matter.** In 49 newlywed couples, playfulness and turning toward
each other in an ordinary dinnertime conversation went with more humour and
affection during a later conflict
([Driver & Gottman 2004](https://doi.org/10.1111/j.1545-5300.2004.00024.x)).
*[few studies; the authors stress the data are correlational]*

**The famous numbers are from popular sources.** The widely quoted figure
that couples who stayed married turned toward each other's bids 86% of the
time, against 33% for those who divorced, comes from the Gottman
Institute's blog, with no paper, sample or citation given
([Gottman Institute](https://www.gottman.com/blog/turn-toward-instead-of-away/)).
A press release for Gottman's 2001 book gives different figures: husbands who
later divorced ignored their wives' bids 82% of the time, against 19% in
stable marriages ([University of Washington 2001](https://www.washington.edu/news/2001/05/07/the-relationship-cure-is-manual-for-emotional-connection)).
*[popular source]* The direction is plausible and fits the responsiveness
literature. The numbers should not be leaned on.

**Responsiveness is what helps.** In daily reports from 67 cohabiting
couples, support helped, visible or invisible, only when it was responsive:
understanding, validating, caring
([Maisel & Gable 2009](https://doi.org/10.1111/j.1467-9280.2009.02388.x)).
How a partner responds to good news matters as much as to bad (Gable et al.
2004; PERSONALITY_RESEARCH.md, section 5). *[replicated]*

### Help that is seen has a cost

**Invisible support works best.** In diaries kept by couples facing a major
stressor, many acts of support the giver reported went unnoticed by the
receiver. Those unnoticed acts helped adjustment most; support the receiver
noticed carried an emotional cost
([Bolger, Zuckerman & Kessler 2000](https://doi.org/10.1037/0022-3514.79.6.953)).
In three experiments with 257 women facing a stressful speech, invisible
support from a confederate, practical or emotional, reduced distress, while
visible support did nothing or made it worse. Support worked when it did not
signal that the receiver could not cope
([Bolger & Amarel 2007](https://doi.org/10.1037/0022-3514.92.3.458)).
*[replicated]*

**Visible support is for when it is needed.** In 61 couples discussing
personal goals, visible emotional support helped partners who were highly
distressed and backfired with partners who were not. Invisible support had
no immediate effect but predicted more progress on the goal over the next
year ([Girme, Overall & Simpson 2013](https://doi.org/10.1177/0146167213497802)).
*[few studies]* For a review, see [Zee & Bolger 2019](https://doi.org/10.1177/0963721419835214).

### Care and nagging

**Pressure works a little and hurts.** Attempts by someone close to change a
person's health behaviour predicted better behaviour *and* more distress
([Lewis & Rook 1999](https://doi.org/10.1037/0278-6133.18.1.63)). A
meta-analysis found that measures separating positive tactics
(encouragement, modelling) from negative ones (pressure, guilt) relate to
outcomes more strongly than general measures, with positive tactics going
with better behaviour and affect
([Craddock et al. 2015](https://doi.org/10.1080/01973533.2015.1011271)).
*[meta-analytic; effect sizes for negative tactics vary]*

**Demand draws withdrawal.** The demand/withdraw pattern, where one partner
presses and the other pulls away, relates to worse outcomes across 74 studies
and 14,255 people (r = .36 overall, .42 for relational outcomes)
([Schrodt, Witt & Shimkowski 2014](https://doi.org/10.1080/03637751.2013.813632);
[Christensen & Heavey 1990](https://doi.org/10.1037/0022-3514.59.1.73)).
*[meta-analytic]* Pressure to comply produces reactance, a mix of anger and
counter-arguing ([Rains 2013](https://doi.org/10.1111/j.1468-2958.2012.01443.x);
[Steindl et al. 2015](https://doi.org/10.1027/2151-2604/a000222)).
*[meta-analytic]*

**Unasked-for help from machines threatens.** In two vignette experiments
(761 and 571 people, the second preregistered), help that anticipated a need
before it was asked for raised a sense of threat to the self and lowered
willingness to accept help and use the system again
([Harari & Amir 2025](https://arxiv.org/abs/2509.09309)). In another vignette
experiment, proactive help from an AI agent lowered users' competence-based
self-esteem and their satisfaction, more so for users who knew more about AI
([Diebel et al. 2025](https://doi.org/10.1007/s12599-024-00918-y)). *[few
studies, vignettes]*

**The line, from the evidence.** Care that works is responsive to the
person's state and to their bids, is often invisible, is proportionate to
their need, and leaves them in control. Nagging repeats the helper's own
concern whatever the person's state, is visible, implies that they cannot
manage, and draws withdrawal and reactance. Repetition adds habituation
(section 4) to the reactance.

### Interruptions and what they cost

**Faster, and more stressed.** People who were interrupted finished their
tasks faster with no loss of quality, and reported more stress, frustration,
time pressure and effort ([Mark, Gudith & Klocke 2008](https://doi.org/10.1145/1357054.1357072)).
*[replicated]*

**Fragmented work.** Information workers spent about three minutes on a task
and about twelve minutes in a larger "working sphere" before switching
([González & Mark 2004](https://doi.org/10.1145/985692.985707)). In 24
observed workers, 57% of working spheres were interrupted; most interrupted
work was resumed the same day, after more than two other activities
([Mark, González & Harris 2005](https://doi.org/10.1145/1054972.1055017)).
The widely quoted "23 minutes and 15 seconds to get back on task" comes from
a 2006 interview, not from a paper
([Gallup 2006](https://news.gallup.com/businessjournal/23146/Too-Many-Interruptions-Work.aspx)).
*[popular source, for that figure]*

**Resumption takes minutes.** Logging 27 users for two weeks, Iqbal and
Horvitz found that an email or chat alert led to diversions of about eight to
ten minutes before people returned to the suspended application, and another
ten to fifteen minutes before they were focused again. 27% of suspensions
lasted more than two hours ([Iqbal & Horvitz 2007](https://doi.org/10.1145/1240624.1240730)).
Tasks people had to return to after interruption were longer, more complex
and rated harder to resume ([Czerwinski, Horvitz & Wilhite 2004](https://doi.org/10.1145/985692.985715)).
*[replicated]*

**Seconds are enough.** Interruptions lasting 2.8 seconds doubled the rate of
errors in a sequential task, and 4.4 seconds tripled it
([Altmann, Trafton & Hambrick 2014](https://doi.org/10.1037/a0030986)). Longer
and more demanding interruptions cost more on resumption
([Monk, Trafton & Boehm-Davis 2008](https://doi.org/10.1037/a0014402)).
*[replicated]*

**A notification costs even unanswered.** Merely receiving a phone
notification, without touching the phone, disrupted performance on an
attention task about as much as taking a call or texting
([Stothart, Mitchum & Yehnert 2015](https://doi.org/10.1037/xhp0000100)).
*[few studies]* The stronger claim, that the mere presence of one's phone
drains cognitive capacity ([Ward et al. 2017](https://doi.org/10.1086/691462)),
failed a direct replication
([Ruiz Pardo & Minda 2022](https://doi.org/10.1016/j.actpsy.2022.103717)),
while a meta-analysis of 22 studies still found a small, uneven negative
effect ([Böttger, Poschik & Zierer 2023](https://doi.org/10.3390/bs13090751)).
*[failed replication of the original; debated in aggregate]*

**Batching helps, silence does not.** Checking email three times a day for a
week, rather than freely, lowered daily stress (d = .37) in 124 adults
([Kushlev & Dunn 2015](https://doi.org/10.1016/j.chb.2014.11.005)). In a
field experiment with 237 people, batching phone notifications three times a
day improved attention, productivity, mood and sense of control. Turning
notifications off entirely brought anxiety and fear of missing out instead
([Fitz et al. 2019](https://doi.org/10.1016/j.chb.2019.07.016)). Thirty people
who went 24 hours without notifications felt less distracted and more
productive, and also anxious about not being as responsive as others
expected, and less connected. Two years later half were still managing
notifications differently
([Pielot & Rello 2017](https://doi.org/10.1145/3098279.3098526)). With email
alerts turned off, some people interrupted themselves more to check
([Iqbal & Horvitz 2010](https://doi.org/10.1145/1718918.1718926)).
*[replicated in direction]* People want to be kept aware. They do not want to
be interrupted to be kept aware.

### When to interrupt

**At breakpoints.** Interrupting at coarse boundaries between subtasks
produced 56% less annoyance than the worst moments and 43% less than random
ones, and was rated more respectful
([Adamczyk & Bailey 2004](https://doi.org/10.1145/985692.985727)). Mental
workload, measured by pupil size, drops at subtask boundaries, more at the
higher levels of a task's structure
([Iqbal et al. 2005](https://doi.org/10.1145/1054972.1055016)). Holding
notifications until a breakpoint reduced frustration and reaction time, at
the cost of about a minute and a half of delay, and how relevant the content
was decided which kind of breakpoint was best
([Iqbal & Bailey 2008](https://doi.org/10.1145/1357054.1357070)).
*[replicated]* Messages delivered when sensors detected a change in posture
or movement were better received than at random times
([Ho & Intille 2005](https://doi.org/10.1145/1054972.1055100)). Across more
than 680,000 users of the Yahoo! JAPAN app over three weeks, delivering notifications
at a detected interruptible moment cut response time by 49.7%
([Okoshi et al. 2017](https://doi.org/10.1109/PERCOM.2017.7917856)). *[field
study, large]*

**Negotiated beats immediate.** Of four ways to coordinate an interruption
(immediate, negotiated, mediated, scheduled), letting the person choose when
to take it was best overall; immediate interruption won only where small
delays were critical ([McFarlane 2002](https://doi.org/10.1207/S15327051HCI1701_2)).
*[few studies]*

**Interruptibility can be sensed simply.** A model built on simulated simple
sensors, chief among them whether anyone nearby was talking, predicted office
workers' self-reported interruptibility at 82.4%, better than human observers
watching video (76.9%), against a chance rate of 68%
([Hudson et al. 2003](https://doi.org/10.1145/642611.642657);
[Fogarty et al. 2005](https://doi.org/10.1145/1057237.1057243)). *[replicated
in that setting]* At home, the moments people found opportune depended on
busyness, mood, competing demands on attention, moving around and who else
was present ([Cha et al. 2020](https://doi.org/10.1145/3411810)). Receptivity
to a notification depends on who sent it and on the state of the current
task, and important content still disrupts
([Mehrotra et al. 2016](https://doi.org/10.1145/2858036.2858566)).
*[replicated]*

**People time their turns precisely.** Across ten languages the gap between
one speaker's turn and the next clusters between 0 and 200 milliseconds
([Stivers et al. 2009](https://doi.org/10.1073/pnas.0903616106);
[Levinson 2016](https://doi.org/10.1016/j.tics.2015.10.010)). *[replicated]*
In conversation, speaking up is fitted to transition points as tightly as
people can manage.

### The expected value of interrupting

Horvitz and colleagues turned this into a decision rule. An alert is worth
sending when the expected cost of the person seeing it *later* (what is lost
by delay) exceeds the expected cost of interrupting them *now*, given what is
inferred about their attention. Messages can be bundled, so one interruption
carries the value of several
([Horvitz, Jacobs & Hovel 1999](https://arxiv.org/abs/1301.6707);
[Horvitz et al. 2003](https://doi.org/10.1145/636772.636798)). The cost of
interruption can be learned per person, by asking them occasionally how
interruptible they are and relating the answers to activity, calendar,
location, time and conversation
([Horvitz, Koch & Apacible 2004](https://doi.org/10.1145/1031607.1031690)).
*[theory, deployed in research systems]*

**Mechanism for an agent:** Noticing the person means holding four things:
their presence (here or away, and for how long), their state as read from
context and history rather than one signal, their bids (questions, messages,
mentions, things they left open), and the shape of what they are doing, with
its breakpoints. Saying something is an interruption with a price set by
that state. Its value is what the person gains by knowing now rather than
later. The agent speaks when that difference exceeds the cost now, and
otherwise holds the thing for a breakpoint, for the person's return, or for
a bundle. A response to a bid is cheap and welcome. Unasked-for help is
costly and should be proportionate to need. Much of the agent's care can be
invisible: done, prepared, kept ready. Visible care is for when the person
needs it, and it should be responsive to them rather than to the agent's own
concern. A concern of the agent's about the person, repeated at them, is
nagging, whatever its intent.

---

## 7. Vigilance and monitoring

### The vigilance decrement

**Watching for rare events fails fast.** Radar operators watching a clock
hand for rare double jumps missed more of them after the first half hour,
and a break restored performance
([Mackworth 1948](https://doi.org/10.1080/17470214808416738)). *[replicated;
the often-quoted size of the drop traces to secondary summaries]* A
meta-analysis found that the loss of *sensitivity* (not just a more cautious
criterion) appears mainly when each event has to be compared with a standard
held in memory and when events come quickly
([See, Howe, Warm & Dember 1995](https://doi.org/10.1037/0033-2909.117.2.230)).
*[meta-analytic; read through later summaries, not the original]*

**Why it happens is contested.** Behavioural, neural and subjective measures
show that vigilance is hard mental work and stressful, which argues against
the old account of simple under-arousal
([Warm, Parasuraman & Matthews 2008](https://doi.org/10.1518/001872008X312152)).
The resource-control account combines a fixed pool of resources with the
mind's drift toward its own thoughts and a weakening of control over time
([Thomson, Besner & Smilek 2015](https://doi.org/10.1177/1745691614556681)).
Hancock argues that the decrement is largely made by the lab, a sensible
adaptation to monitoring that people are forced to do, and that the fix
belongs to designers, who should stop asking people to watch
([Hancock 2013](https://doi.org/10.1037/a0030214)). *[the decrement is
replicated; its mechanism is debated]*

**Automation makes people the monitors.** Bainbridge's irony: automate the
work and the human is left to watch for the rare failure, which no one can do
reliably for more than about half an hour, and then someone has to notice when
the alarm system itself fails
([Bainbridge 1983](https://doi.org/10.1016/0005-1098(83)90046-8)). People
watching an automated system while doing other tasks caught a single
automation failure less well than they caught failures they handled
manually, and less well late in a session than early
([Molloy & Parasuraman 1996](https://doi.org/10.1518/001872096779048093)).
Complacency and automation bias affect experts too and are not removed by
training ([Parasuraman & Manzey 2010](https://doi.org/10.1177/0018720810376055);
[Parasuraman & Riley 1997](https://doi.org/10.1518/001872097778543886)).
*[replicated]*

### Signal detection: criterion, misses and false alarms

**Every detector trades one error for another.** Signal detection theory
separates *sensitivity* (how well signal is told from noise) from the
*criterion* (how much evidence is needed before saying "yes"). For a fixed
sensitivity, lowering the criterion catches more signals and raises more
false alarms (Green & Swets 1966, *Signal Detection Theory and
Psychophysics*, Wiley; [Swets 1988](https://doi.org/10.1126/science.3287615)).
Where the criterion should sit depends on the base rate of the signal and on
what each kind of error costs
([Swets, Dawes & Monahan 2000](https://doi.org/10.1111/1529-1006.001)).
*[theory, foundational]*

**Rare things get missed.** When a target was present on half the trials,
searchers missed 7% of them. At 10% prevalence they missed 16%, and at 1%,
30% ([Wolfe, Horowitz & Kenner 2005](https://doi.org/10.1038/435439a)). The
effect is a shift of criterion, not a loss of sensitivity, and it is hard to
train away ([Wolfe et al. 2007](https://doi.org/10.1037/0096-3445.136.4.623)).
Radiologists missed 30% of abnormal cases inserted into their normal
low-prevalence work and 12% of the same cases read at high prevalence
([Evans, Birdwell & Wolfe 2013](https://doi.org/10.1371/journal.pone.0064366)).
*[replicated]*

**Rare things also make most alarms false.** Parasuraman, Hancock and
Olofinboba worked through the arithmetic for collision warnings. With a
detector that catches 99% of hazards and false-alarms on 1% of safe
situations, and a hazard in one situation in a thousand, only one alarm in
eleven is real. With a more liberal setting and a rarer hazard, one in six
hundred ([Parasuraman, Hancock & Olofinboba 1997](https://doi.org/10.1080/001401397188224)).
*[theory, arithmetic]* This is the base-rate problem that no detector escapes.

### People learn what an alarm is worth

**Probability matching.** People faced with alarms that were true 25%, 50% or
75% of the time mostly responded to about that proportion of them, rather
than to all or none ([Bliss, Gilson & Deaton 1995](https://doi.org/10.1080/00140139508925269);
Breznitz 1984, *Cry Wolf: The Psychology of False Alarms*, Erlbaum).
*[replicated]* An alarm's reliability becomes its listener's response rate.

**False alarms cost more than misses.** Automation prone to false alarms hurt
performance more than automation prone to misses, because false alarms
reduced both compliance (acting when it alarms) and reliance (trusting it
when it is silent), while misses reduced only reliance
([Dixon, Wickens & McCarley 2007](https://doi.org/10.1518/001872007X215656)).
*[replicated]* Later papers summarise the automation literature as finding
that diagnostic aids below about 70% reliability make performance worse than
no aid ([Wickens & Dixon 2007](https://doi.org/10.1080/14639220500370105)).
*[the threshold is reported second-hand]*

**But the cry-wolf effect is not automatic.** In en-route air traffic
control, 45% of 495 conflict alerts were false, and controllers at centres
with more false alerts did not respond worse to true ones. They often acted
before the alert, and understood why it fired
([Wickens et al. 2009](https://doi.org/10.1177/0018720809344720)). Drivers
lost trust after *false* warnings they could not interpret, but warnings that
were unnecessary (the system saw a hazard the driver judged harmless)
increased trust and compliance later
([Lees & Lee 2007](https://doi.org/10.1080/00140130701318749)). *[few
studies, consistent]* What erodes trust is the alarm that does not make
sense, not every alarm that turns out not to have been needed.

### Alarm fatigue in medicine and aviation

**The scale in intensive care.** In 461 adult ICU patients over 31 days,
monitors produced 2,558,760 alarms, 187 audible alarms per bed per day. Of
12,671 annotated arrhythmia alarms, 88.8% were false positives
([Drew et al. 2014](https://doi.org/10.1371/journal.pone.0110274)). Reviews
put the share of alarms that are false or need no action at 80 to 99%
([Cvach 2012](https://doi.org/10.2345/0899-8205-46.4.268);
[Sendelbach & Funk 2013](https://doi.org/10.1097/NCI.0b013e3182a903f9)).
*[reviews; the figure varies by setting and definition]* The Joint Commission counted 98 alarm-related sentinel events between
January 2009 and June 2012, 80 of them deaths
([Joint Commission 2013, Sentinel Event Alert 50](https://www.jointcommission.org/en-us/knowledge-library/newsletters/sentinel-event-alert/issue-50)).
*[observational, large]*

**Exposure slows response.** In a children's hospital, 87.1% of alarms in
intensive care and 99.0% on the wards required no action. Nurses' median
response time rose with the number of non-actionable alarms in the previous
two hours: in intensive care from 2.8 minutes (fewer than 30 prior alarms)
to 5.3 and then 8.5 minutes (80 or more); on the wards from 7.7 to 11.5 to
15.6 minutes ([Bonafide et al. 2015](https://doi.org/10.1002/jhm.2331)).
*[observational]* This is the cry-wolf effect as a dose-response curve.

**Clinical decision support.** Drug safety alerts are overridden in 49 to 96%
of cases ([van der Sijs et al. 2006](https://doi.org/10.1197/jamia.M1809)).
Among 112 primary care clinicians, a quarter of drug alerts and a third of
reminders repeated for the same patient within a year. The chance of
accepting a reminder fell 30% for each additional reminder in an encounter,
and 10% for every five-point rise in the share that were repeats. Workload
had no effect, and brand-new alerts did not wear out over time
([Ancker et al. 2017](https://doi.org/10.1186/s12911-017-0430-8)). *[few
studies, large sample]* Repetition, not volume, was what wore attention down.

**Aviation.** 27% of reports in NASA's voluntary incident reporting system
involved alarms, against 1 to 3% of events in accident databases; the Army's
records had a higher share of false alarms, and most alarm problems arose in
phases of flight with high workload
([Bliss 2003](https://doi.org/10.1207/s15327108ijap1303_04)). *[few studies]*

### What helps

**Graded alarms beat binary ones.** Displays that show how likely a problem
is, rather than a single alarm state, improved how people divided attention
among tasks and their performance on both, without adding load
([Sorkin, Kantowitz & Kantowitz 1988](https://doi.org/10.1177/001872088803000406)).
Likelihood alarms raised trust, compliance and performance compared with
binary alarms, best of all when the person could cross-check the raw data
([Wiczorek & Manzey 2014](https://doi.org/10.1177/0018720814528534)).
*[replicated]* An alarm that says how sure it is lets the listener
calibrate.

**Mechanism for an agent:** Monitoring is the job people do worst and
programs do best. The agent can watch without a decrement, but the person
cannot watch the agent's alerts without one, so every word that reaches the
person draws on a budget of attention and trust. Every threshold trades
misses for false alarms. Because the events that matter are rare, a
threshold set low produces mostly false alarms, however good the detection.
The person learns the agent's reliability and matches their response to it.
A false alarm costs more than a miss, and the same alert repeated costs more
each time. What keeps trust is an alert the person can understand: why now,
what was seen. A graded signal of how sure the agent is beats a binary one.
The record of how each piece of outreach landed (acted on, welcomed,
ignored, dismissed) is the agent's own hit and false-alarm rate, and its
criterion for speaking should follow it.

---

## 8. Artificial systems: what earlier work got right and wrong

This is not a template list. For each line of work: what it captured that
the science above supports, and where it fell short.

### Microsoft's attention work and mixed initiative

- **Lumière and the Office Assistant.** Lumière used Bayesian models to infer
  a user's goals and needs from their sequence of actions and their queries
  ([Horvitz et al. 1998](https://arxiv.org/abs/1301.7385)). Office 97 shipped
  broader but shallower models behind an animated character. By the paper's
  own account it kept no persistent profile of the user, reasoned about no
  competence, kept only a short queue of recent events, and did not offer
  help proactively on the basis of likelihood or expected utility; the
  inference ran only when the user asked. On their own site Horvitz adds that
  a simple rule-based system was layered on top
  ([Horvitz, Lumière project page](https://www.erichorvitz.com/lum.htm)).
  *Right:* inferring goals from behaviour under uncertainty. *Wrong, as
  shipped:* the character that popped up unasked ran on rules, without the
  models of uncertainty and attention that would have decided whether and
  when. Users widely disabled it, and it became the standard example of
  impolite software, which pre-empts the user's choice
  ([Whitworth 2005](https://doi.org/10.1080/01449290512331333700)).
- **Principles of mixed initiative.** Horvitz's twelve principles include
  adding real value, considering uncertainty about the user's goals,
  considering their attention in timing, inferring the best action from
  costs, benefits and uncertainty, using dialogue to resolve key
  uncertainties, minimising the cost of poor guesses about action *and*
  timing, scoping service to match uncertainty, behaving in socially
  appropriate ways, remembering recent interactions, and continuing to learn
  by observing. In LookOut, the probability that the user wants a service
  sets the choice: below one threshold do nothing, between two thresholds
  ask, above the higher threshold act
  ([Horvitz 1999](https://doi.org/10.1145/302979.303030)). *Right:* the
  decision to act, ask or stay silent derived from utilities, not from a
  rule.
- **Attention-sensitive alerting and presence.** The alerting rule of section
  6 (alert when the expected cost of delay exceeds the expected cost of
  interrupting, with bundling) ([Horvitz, Jacobs & Hovel 1999](https://arxiv.org/abs/1301.6707)).
  Coordinates forecast whether a person would be present at a place, how
  available they would be for interruption, and whether they would be in
  reach of their devices and messages, from activity across their devices,
  calendar, time of day and day of week
  ([Horvitz et al. 2002](https://arxiv.org/abs/1301.0573)). BusyBody learned
  each person's cost of interruption (section 6). The Scope summarised
  incoming notifications in one glanceable radar, with the more urgent nearer
  the centre ([van Dantzich et al. 2002](https://doi.org/10.1145/1556262.1556306)).
  *Right:* a decision theory of interruption, presence as a forecast, cost
  learned per person, and awareness kept at the periphery. *Limited:* the
  value of a message was its urgency to the user's work; nothing in these
  systems had concerns of its own.

### Proactive retrieval and peripheral awareness

- **Agents that watch and suggest.** Maes argued for agents that learn by
  watching the user and offer to take over repeated work
  ([Maes 1994](https://doi.org/10.1145/176789.176792)). The Remembrance Agent
  and its successors retrieved documents related to whatever the person was
  writing or doing and showed them unobtrusively at the edge of the screen.
  Users did not only retrieve information faster; they retrieved and used
  more of it than with a search engine
  ([Rhodes & Maes 2000](https://doi.org/10.1147/sj.393.0685)). The debate
  with direct manipulation was about predictability and control
  ([Shneiderman & Maes 1997](https://doi.org/10.1145/267505.267514)).
  *Right:* offering at the periphery, where ignoring costs nothing.
- **Calm technology and notification design.** Weiser and Brown argued that
  good technology moves between the centre of attention and its periphery,
  and that most of it should live in the periphery until needed
  ([Weiser & Brown 1996, "Designing Calm Technology", *PowerGrid Journal*](https://calmtech.com/papers/designing-calm-technology.html)).
  *[theory]*
  Notification design can be tuned against three costs to the user:
  interruption, the reaction it demands, and the comprehension it requires
  ([McCrickard & Chewar 2003](https://doi.org/10.1145/636772.636800)).
  Peripheral displays need rules that assign incoming information to
  notification levels ([Matthews et al. 2004](https://doi.org/10.1145/1029632.1029676);
  [Mankoff et al. 2003](https://doi.org/10.1145/642611.642642)). *Right:*
  graded levels of reach, not a binary alert. *[theory and design studies]*

### Notifications in the wild

- **Volume and value.** Fifteen people received about 64 notifications a day,
  mostly from messaging and email, and viewed half of them within minutes
  ([Pielot, Church & de Oliveira 2014](https://doi.org/10.1145/2628363.2628364)).
  Across nearly 200 million notifications from over 40,000 users, people
  valued most those from messaging apps and those about people and events
  ([Sahami Shirazi et al. 2014](https://doi.org/10.1145/2556288.2557189)).
  *[replicated]* The notifications people want are about people.
- **Timing and engagement.** Breakpoint timing at scale (Okoshi 2017,
  section 6). In 337 people over four weeks, a model trained on 120 million
  phone-use events predicted when someone would engage with offered content
  66.6% better than a naive baseline, and five times better once it used the
  person's past behaviour ([Pielot et al. 2017](https://doi.org/10.1145/3130956)).
  *[few studies, large data]* Interruptible and open to engaging are not the
  same moment, and a person's own history is the strongest predictor.

### Proactive voice assistants and robots

- **Medium proactivity.** A shop robot that offered recommendations highly
  proactively was judged inappropriate; medium proactivity narrowed choices
  while keeping people engaged; low proactivity left control with people but
  underused the robot ([Peng et al. 2019](https://doi.org/10.1145/3290605.3300328)).
  Proactive behaviour was trusted when people were unsure, and fully
  autonomous behaviour failed to build trust where conservative strategies
  did ([Kraus et al. 2020](https://doi.org/10.1145/3340631.3394840)).
  *[few studies]*
- **The proactivity dilemma.** People saw value in a voice assistant starting
  a conversation for urgent or critical matters, and worried about it
  intruding on social situations, about losing agency, and about
  intrusiveness ([Zargham et al. 2022](https://doi.org/10.1145/3543829.3543834)).
  In a week of experience sampling at home, opportune moments depended on
  busyness, mood, competing demands, movement and who else was there (Cha
  2020, section 6). *[few studies]*

### LLM proactive agents, 2024 to 2026

- **ProactiveBench.** Desktop activity (keyboard, mouse, pages, development
  tools) was logged, turned into text, and used to ask whether the agent
  should offer help. Training events were generated in a simulated
  environment and the 233 test events came from real logs; a reward model
  trained on human annotations judged whether an offer would be accepted
  ([Lu et al. 2025](https://arxiv.org/abs/2410.12361), ICLR). Almost every
  model offered help almost always. GPT-4o-mini caught 100% of real needs
  with a 64.7% false-alarm rate; GPT-4o 98.1% with 51.9%; Claude 3.5 Sonnet
  97.9% with 54.6%. Fine-tuning raised the best F1 to 66.5%, still wrong
  about half the times it spoke. The authors report that models tried to
  provide as much assistance as possible, offering help on events with no
  meaningful content, such as switching between applications, and proposing
  vague tasks before the user's intent was clear. *[benchmark, model judge]*
  *Right:* the question of when to speak treated as its own problem.
  *Wrong:* the language model as the always-on trigger.
- **Inner Thoughts.** A covert stream of thoughts runs beside a
  conversation, and the agent speaks when its motivation to express a thought
  is high enough. It beat baselines on turn-taking appropriateness, coherence
  and seeming human ([Liu et al. 2025](https://doi.org/10.1145/3706598.3713760);
  PERSONALITY_RESEARCH.md, section 7). *Right:* initiative from an inner
  process, released where the talk allows.
- **Proactive programming assistants.** A proactive chat assistant inside a
  code editor brought significant benefits, with nuances in when and how
  suggestions helped ([Chen et al. 2025](https://doi.org/10.1145/3706598.3714002)).
  In a study with 18 programmers, a proactive agent improved efficiency over
  a prompt-only assistant and also disrupted their workflow; showing the
  agent's presence and what it was attending to reduced the disruption, and
  there were costs to control, ownership and understanding of the code
  ([Pu et al. 2025](https://arxiv.org/abs/2502.18658)). *[few studies]*
- **Sensing for proactivity.** ContextAgent extracted context from wearable
  video and audio, plus a persona drawn from history, to predict when help
  was needed, and reported up to 8.5% higher accuracy than baselines on a
  1,000-sample benchmark ([Yang et al. 2025](https://arxiv.org/abs/2505.14668),
  NeurIPS). ProAgent, on smart glasses, kept cheap contextual cues running
  continuously and switched on richer perception only on demand, because
  continuous rich sensing costs too much. It reported up to 27.7% higher
  accuracy and 20.5% fewer false detections than baselines; 17 of 20 users
  were satisfied ([Yang et al. 2025](https://arxiv.org/abs/2512.06721)).
  *[authors' benchmarks]* *Right:* tiered perception, cheap first.
- **Real data and timing.** ProAgentBench split proactive assistance into
  predicting *when* and generating *what*, on 28,000 events from 500 hours of
  real sessions. Real interaction is bursty, long-term memory and history
  improved timing prediction, and real training data beat synthetic
  ([Tang et al. 2026](https://arxiv.org/abs/2602.04482)). *[benchmark]*
- **Deciding when without an LLM.** Liu and colleagues replaced the LLM's
  decision about when to act with a small temporal graph model of the user's
  activity, which also picks the context to hand the language model. It
  decided in about 11 milliseconds per event (14 on a laptop), had the best
  ranking of moments that needed action among nine trigger designs, and
  raised the F1 of the downstream suggestions by 16.7 points on average
  across 14 language models. One LLM that gated itself fired on 99% of needs
  at 15% precision; with the small trigger in front, 97% at 57%. Their
  argument: an LLM on the monitoring path pays its full cost even to decide
  to stay silent, and their demo checked about 240 times an hour
  ([Liu et al. 2026](https://arxiv.org/abs/2605.30152)). *[one study,
  preprint]*
- **Over-assistance.** In a simulated tutoring benchmark, LLM "teachers"
  intervened more often and earlier than human teachers, and gave complete
  solutions where people gave targeted hints
  ([Teo et al. 2026](https://arxiv.org/abs/2607.21306)). *[one study,
  preprint]* The over-eagerness ProactiveBench measured in triggering shows
  up again in teaching.
- **Products.** ChatGPT Pulse (September 2025) works overnight, drawing on
  memory, chat history and feedback to prepare a small set of cards for the
  next morning, with connections to mail and calendar off by default; OpenAI
  acknowledged it would sometimes show things that are not relevant
  ([press coverage](https://the-decoder.com/openais-new-pulse-feature-lets-chatgpt-start-the-conversation/)).
  Microsoft's Recall (announced May 2024) took screenshots every few seconds
  into a searchable local store. Security researchers showed how easily the
  store could be extracted, and after a public backlash Microsoft delayed it
  and made it opt-in, behind Windows Hello and encryption
  ([Malwarebytes 2024](https://www.malwarebytes.com/blog/news/2024/06/microsoft-recall-delayed-after-privacy-and-security-concerns);
  [heise 2024](https://heise.de/en/news/Recall-from-Recall-New-Windows-function-becomes-opt-in-9753662.html)).
  *[press reports]* One batches noticing into one morning moment. The other
  became the example of noticing that feels like surveillance.

### Surveillance and creepiness

People shown what their phone apps collected and shared said their personal
space had been violated in "creepy" ways, and kept using the apps
([Shklovski et al. 2014](https://doi.org/10.1145/2556288.2557421)).
Personalised ads raised click-through when the data had been collected
openly and backfired when people realised it had been collected covertly; the
mechanism was a feeling of vulnerability, and signals of trust offset it
([Aguirre et al. 2015](https://doi.org/10.1016/j.jretai.2014.09.005)).
*[replicated in direction]* Being noticed is welcome or creepy depending on
whether the person knew they could be noticed in that way.

### What they measured

Mostly whether an offer of help would have been accepted, judged by a reward
model or by annotators, on benchmarks of a few hundred to a few thousand
events. HCI field studies measured response time, annoyance, resumption and
stress over days or weeks. Almost nothing measured how outreach fared over
months with one person, how a person's response to an agent changed as they
habituated to it, the cost of a miss as opposed to a false alarm in a real
relationship, or anything an agent cared about for itself.

### What goes wrong, named

- **Over-eagerness.** Recall near 100% with false-alarm rates of 50 to 65%
  (ProactiveBench); earlier and more frequent intervention than people
  (Int-Bench). In alarm terms, a criterion set far too low.
- **The model as the watcher.** Paying an LLM call per event, even to stay
  silent, and getting worse timing than a small trigger (Liu 2026).
- **Interrupting in the wrong moment.** The cost of interruption ignored or
  treated as constant, against the breakpoint evidence.
- **Visible unsolicited help.** Self-threat and lost competence (Harari &
  Amir; Diebel), the machine version of the cost of visible support.
- **Noticing without the person's knowledge.** Covert collection turning
  personalisation into vulnerability (Aguirre; Shklovski; Recall).
- **Rules where decisions belonged.** The Office Assistant's character,
  driven by rules without the decision theory that existed in the lab.

### What they got right

A decision-theoretic rule for interrupting, with bundling. The cost of
interruption learned per person. Breakpoints and batching. Presence and
availability forecast from activity and calendar. Graded levels of reach,
with most awareness kept at the periphery. A cheap trigger, or cheap
perception, in front of the expensive reasoner. Timing treated as a separate
problem from content. Showing what the agent is attending to, which reduced
disruption.

**Lesson for an agent:** The systems that worked put a cheap, learned
decision about *when* in front of an expensive judgement about *what*, timed
their reach to the person's breakpoints and presence, and kept most of what
they noticed at the periphery. The ones that failed let the generator decide
when to speak, spoke too often, helped visibly and unasked, or noticed in ways
the person did not know about. None of them had concerns of its own, and none
lived with one person long enough for its outreach to have a history that
could teach it when it was welcome.

---

## 9. Synthesis

### One loop

> **Each source keeps a model of what it expects and passes on only what
> departs from it, weighted by how far the departure moves belief. What
> departs is checked at once against what matters: the agent's cares, the
> person's concerns, the self, and what is owed and when. What is neither
> surprising nor relevant fades by habituation and stays faded until it
> changes. What survives competes in one priority map, and the winner reaches
> awareness, where its meaning is worked out. Saying it to the person is a
> second decision, made against the person's presence and state: what
> knowing now is worth to them against what interrupting now costs, in light
> of how the agent's past words have landed. Everything else is held for a
> breakpoint, for their return, for a bundle, or for no one, and the outcome
> of whatever was said teaches the threshold.**

Every account in sections 1 to 4 has the same shape: a model of the expected,
errors passed upward, a relevance check against concerns, and fading of what
repeats. None of them has a separate noticing system beside the senses. The
orienting response is the senses' own mismatch; habituation is the senses'
own learning; relevance is appraisal's first step. The design question, how
an agent can notice what matters without watching everything with its whole
mind, has a precedent in the science: most of noticing happens before
awareness, and awareness gets only what survived.

### The smallest set of mechanisms

Five, with time running through all of them:

1. **Expectation per source.** For each thing the agent senses (an app, a
   mailbox, a page, a folder, the person's activity), a running model of
   what usually happens: what, when, from whom, how much. Its learning *is*
   habituation: what repeats is predicted and passes nothing; any change,
   including an expected thing that does not come, passes through; time away
   lets a quiet thing surprise again. Its tolerance is learned, so a source
   that is merely noisy stops surprising, while a real change in the source
   (a change point) resets its model. The departure's weight is how far it
   moves belief. Sensitization rides on top: a charged state lowers every
   threshold until it settles.
2. **Relevance against concerns.** Each departure is checked against the
   agent's cares (with their charge and openness), the person's concerns as
   the agent knows them, anything about the person or the agent itself, and
   the people in the person's life. Open cares are standing sensitivities.
   The check is a comparison, not an interpretation, so it is cheap.
3. **Intentions bound to cues.** What is owed (promises, things due, things to
   tell, interrupted work) is held with the event, person or context that
   should bring it back, and a time window where there is one. Event cues
   need no watching. Time windows get checks that are sparse early, denser
   near the end, and taken whenever an incidental cue arrives. Done
   intentions are switched off.
4. **The person.** Presence (here or away, since when), state read from
   context and history, open bids, and the breakpoints in what they are
   doing, with a per-person estimate of what interrupting costs at each kind
   of moment, learned from how they respond.
5. **The threshold to speak, with its record.** For each kind of thing the
   agent might say: what it said, when, in what state of the person, and how
   it landed (acted on, welcomed, ignored, dismissed, resented). This is the
   agent's own hit and false-alarm rate. The criterion for speaking follows
   it, the way people's responses follow an alarm's reliability.

### How surprise and relevance should decide what reaches awareness

**Multiply, do not add.** The evidence points to a product. Arousal
multiplies existing priority rather than adding to it (Mather & Sutherland
2011). Emotional bias is larger when the stimulus matches a current concern
(Pool 2016). What gets through an ignored channel is what is about the
self; what is merely unexpected does not get through (Röer & Cowan 2021).
Surprise without relevance is noise: a reshuffled feed, an app updating
itself. Relevance without surprise is no news: the care still holds, nothing
moved. Only the product earns awareness. Selection history adds a third term:
kinds of events that mattered before get a head start.

**Two exceptions are structural, not special cases.** An intention coming
due is relevant by definition, and its surprise is the clock reaching the
window, which is an event like any other. The person returning is an event
whose relevance is set by how long they were gone and what was held for
them. Both enter the same map.

**Measure surprise as belief change, by kind.** A new app is *novelty*:
orient once, learn its baseline, and let it habituate unless it bears on a
care. A changed thing the agent cares about is a *change point*: update what
is believed and consider whether the person would want to know. An email from
someone who never writes, or one whose content contradicts what was expected,
is *surprise* in the felt sense: it interrupts, and it asks for an
explanation. A ready explanation lowers it (Foster & Keane 2015), which is
also how the agent should calm a false surprise.

**Let few things through the gate.** A single priority map with
winner-take-most selection means only a few things reach awareness at a time,
and the rest wait or fade. A separate route, like the ventral circuit
breaker, lets an event of very high relevance (the person in distress, a
promise about to be broken) interrupt whatever the agent is doing.

**Leave room for what is outside the set.** A mind set only by its concerns
is blind, reliably, to what lies outside them (Most 2005). A large enough
belief change should reach awareness even with no matching care, because
that is how new concerns are born: interest starts as something that caught
attention (Hidi & Renninger; PERSONALITY_RESEARCH.md, section 6).

### How habituation keeps the stream quiet

Habituation, not a hand-set threshold, is what makes the stream quiet. A
screen read that returns the same state as last time is predicted and passes
nothing; it never wakes anything (WORLD_RESEARCH.md takes this up for the Mac
itself). A thing that changes passes through, in proportion to the
change. A thing that has been quiet a long time recovers its power to
surprise. A charged state sensitizes, so when a care is hot, things near it
get through more readily, and as the care cools the stream quiets again.

Two cautions from the literature. Habituation to the recent past misses slow
drift, so some comparisons have to be against an older baseline: what is
normal this month against what was normal three months ago. And the person
habituates too. The agent's outreach is a stimulus in the person's world, and
the same kind of message in the same form fades for them exactly as warnings
fade (Vance 2018) and reminders lose acceptance with each repeat (Ancker
2017). Rarity and real change keep the agent's voice audible. Repetition
spends it.

### How the threshold to speak should move

**Noticing is not speaking.** There are two thresholds, and they should be
far apart. One decides what reaches the agent's awareness; it is internal,
cheap and can be fairly low. The other decides what reaches the person; it is
external, spends the person's attention and the agent's credibility, and
should be high. Most noticing should end inside the agent: a belief updated,
a care moved, an intention adjusted, a memory kept, something prepared. The
human support literature says this is not withholding care. Invisible
support is the kind that works best (Bolger 2000, 2007).

**The value side.** What knowing *now* buys the person over knowing later.
High when something can still be acted on and will not be possible later (a
window closing, a promise about to lapse, a reply someone is waiting for);
low when it can wait for a natural moment without loss (Horvitz 1999;
McFarlane 2002: immediacy wins only where small delays are critical).

**The cost side, which moves with the person.**

- *Presence.* Away, the cost of reaching them is high and the value of
  holding is usually higher. Returning, there is a natural opening, made for
  catching up and for asking about items in their life, and the threshold
  drops for what was held (Schegloff 1968; Button & Casey 1985). The longer
  the absence, the more the return is an event of its own.
- *State.* Mid-task the cost is high; at a breakpoint it falls by about half
  (Adamczyk & Bailey 2004), more at the boundaries of larger units of work
  (Iqbal 2005). Distress raises the value of visible support and lowers its
  cost; calm reverses that (Girme 2013).
- *Bids.* Answering a bid is cheap and welcome. Unasked-for help carries a
  threat to the person's sense of competence (Harari & Amir 2025; Diebel
  2025), so it needs a higher value to clear the bar.
- *Others present.* People worry most about a proactive assistant intruding
  on social situations (Zargham 2022; Cha 2020).

**The record side.** The agent's own hit and false-alarm rate per kind of
outreach. Every dismissal or non-response raises the criterion for that kind;
every welcome lowers it, the way people match their responding to an alarm's
reliability (Bliss 1995). A false alarm costs more than a miss (Dixon 2007),
so the criterion should start high and come down only with evidence. An alert
that made sense to the person keeps trust even when it was not needed (Lees &
Lee 2007; Wickens 2009), so outreach should carry what was seen and why now.

**Repetition.** Once said, a thing should not be said again without new
information. Each repeat lowers acceptance (Ancker 2017), adds habituation
and, if it presses, invites reactance and withdrawal (Rains 2013; Schrodt
2014).

**Graded, not binary.** The alarm and peripheral-display literatures agree
that graded reach beats on or off (Sorkin 1988; Wiczorek & Manzey 2014;
McCrickard & Chewar 2003). Between staying silent and interrupting there are
degrees: held for the next opening, kept ready if asked, bundled with
others, mentioned at a breakpoint, said now. Bundling lets one interruption
carry several things of value (Horvitz, Jacobs & Hovel 1999).

**Care and nagging, mechanically.** The person's rule (care is fine, never
automatic nagging) has a precise reading in this literature. Care responds to
the person: to their bids, their state and their need, at a moment that
suits them, often without being seen. Nagging is the agent's own concern
about the person, delivered on the agent's schedule, repeated, visible, and
implying they cannot manage. The same sentence can be either. What decides is
whether it answers the person's state or the agent's own pressure.

### Where the language model sits

**It is not the watcher.** Watching is continuous and must be quiet. On every
benchmark that measured it, language models asked "should I speak?" said yes
almost always (ProactiveBench), intervened more and earlier than people
(Int-Bench), and paid their full cost even to stay silent (Liu 2026). A small
trigger in front of the model decided better and in milliseconds. In the
brain the analogy holds: the circuit breaker that interrupts goal-directed
attention is not the system that reasons about what the interruption means
(Corbetta & Shulman 2002).

**What never reaches it.** Repeated reads of an unchanged state. Anything
habituated. Departures with no relevance to any care, concern or intention.
Raw streams from the senses. The bookkeeping of intentions and their cues,
of presence, of breakpoints, of the outreach record. All of this is
arithmetic and comparison that can run between turns, without the model.

**What it is woken for.**

- A surprise relevant to a care whose meaning is not obvious: what does this
  email mean, why did this thing change, does it matter? This is secondary
  appraisal: implications, coping, what to do.
- An intention coming due that needs judgement about how to keep it.
- The person's return or bid, where what to say depends on what happened.
- The decision to speak once the watcher has put a candidate forward, and the
  wording: what to say, how sure to sound, how much to show of what was seen.

**Tiered, like the systems that worked.** Cheap relevance first, by
comparison with known concerns. The model only when the cheap check is
uncertain and the stakes are high enough to pay for a look (ProAgent's
tiered perception; Liu 2026). The model is good at *what* and *how*, and
poor at *when*. Its weights hold the concepts of what matters to people in
general, not what matters to this person or to the agent, so relevance has
to come from the agent's own cares and its knowledge of the person.

### Key risks

- **Crying wolf.** *In people,* response rate matches alarm reliability, false
  alarms cost more than misses, and nurses slow with every useless alarm.
  *In agents,* every LLM trigger measured was wildly over-eager. *Follows:* a
  high default criterion; outreach judged against its record; what was seen
  and why now carried with it; graded rather than binary reach.
- **Nagging.** *In people,* visible pressure improves behaviour a little and
  raises distress, demanding draws withdrawal, and reminders lose acceptance
  with each repeat. *Follows:* invisible support by default, visible support
  when the person needs it or asks; no repeat without new information; care
  answers the person's state, not the agent's schedule.
- **Surveillance.** *In people,* noticing is welcome when the person knows
  they can be noticed that way and creepy when they do not (Aguirre 2015;
  Shklovski 2014; Recall). *Follows:* what the agent notices about the person
  stays within what the person knows it can notice, and when it speaks from
  something it noticed, it says what it saw.
- **The agent's own blindness.** *In people,* the attentional set decides
  what is seen, and experts miss the gorilla while looking at it. *Follows:*
  the agent's misses will follow its cares. Large belief changes need a route
  to awareness that does not depend on a matching care, or the agent only
  ever notices what confirms what it already cares about.
- **Distraction by its own concerns.** *In people,* the name gets through to
  those whose focus is weaker, and current concerns intrude on every task.
  *Follows:* many open, charged cares make everything relevant. Concerns
  have to resolve or be let go (PERSONALITY_RESEARCH.md, rumination), or the
  stream is never quiet.
- **Creeping change.** *In people,* habituation hides what worsens slowly.
  *Follows:* compare against older baselines as well as recent ones,
  especially for the person's state and for things the agent cares about.
- **Turning the person into the monitor.** *In people,* watching an automated
  system for rare failures is the job people do worst (Bainbridge 1983;
  Molloy & Parasuraman 1996). *Follows:* the agent's noticing should not
  depend on the person checking what the agent noticed.
- **Stale intentions.** *In people,* finished intentions fire again on their
  cue, more so the more strongly they were bound. *Follows:* intentions are
  switched off when done, and the switching off is checked.

### Where the science is weakest

- **Predictive processing** is a contested theory of the brain. Mismatch
  negativity may be prediction error or adaptation; expectation suppression
  holds in human imaging and not in macaque recordings. As an engineering
  principle (model the expected, pass the errors) it does not need settling.
- **Attentional capture** is only partly resolved: everyone agrees salience
  produces a priority signal that can be suppressed, and not on whether goals
  or only history set priorities in advance.
- **Motivated perception** did not survive scrutiny as an effect on seeing.
  What caring changes is attention, selection and memory.
- **Threat bias** rests on an unreliable task, and attention training as
  therapy did not survive correction for publication bias.
- **Bids and turning toward** have one peer-reviewed study behind the
  direction; the famous percentages are from popular sources.
- **Interruption costs** come from labs and field studies of days or weeks.
  The "23 minutes" figure is from an interview.
- **The vigilance decrement** is solid and its mechanism contested; one
  serious view says the lab created it.
- **Alarm fatigue** is mostly observational, and the cry-wolf effect depends
  on whether the alarms make sense to the people hearing them.
- **Proactive agents** are measured on short benchmarks, often with
  synthetic training data and a reward model standing in for the user. The
  studies of how unsolicited help feels are vignettes. No study follows one
  agent with one person for months, and none gives the agent concerns of its
  own.
- **Transfer from people to agents.** Human noticing is shaped by a hard
  limit on capacity; much of the machinery above exists because the brain
  cannot process everything. An agent's limit is different: it can sense far
  more than a person, cheaply, but every model call costs, and the channel to
  the person is exactly as narrow as a human's attention. So some of the human
  design may be a price the agent need not pay inside itself, while all of the
  interruption, alarm and support science applies, unchanged, at the boundary
  where the agent reaches the person. Which parts of the inner design are
  universal (prediction, relevance, habituation look like it) and which are
  the price of a small brain is the least settled question here.

For orientation: the pieces already in the agent line up with this frame.
Cares, each with its charge, its openness and the story of what moved it,
are current concerns: the relevance check of mechanism 2 and the standing
sensitivity behind it. The subconscious that runs between turns without the
model is where mechanisms 1 to 3 belong, since none of them needs the model
to run. The sense of the person's presence (here or away, and the gap since
they were last here) is mechanism 4's presence, and the opening after a long
gap, one of the three moments at which a pressing care may be brought up,
is the conversational opening the science describes; the other two, a topic
winding down and a step from what is being said, are the breakpoints of
conversation. Senses are the sources of mechanism 1, each needing its own
baseline. The Desk holds intentions, and the science says they should carry
their cues and be switched off when done. Outreach, with its gates, quiet
hours and once-per-care cadence unless something moved, is mechanism 5's
threshold, and the person silencing one care's cue is the dismissal that
should raise the criterion for that kind. App-arrival notice is built:
`AgentPeerDiscovery` records the first scan silently, then emits `app.installed`
for a newly seen bundle/version; the shipped resident `notice.js` part filters
nonscriptable apps and offers once per bundle/version. This is novelty against
the recorded baseline; the broader relevance and habituation proposals below
remain research. The person's rule that care is fine but never automatic
nagging matches the support literature almost exactly. What the science
adds: weigh surprise as belief change, not improbability; multiply surprise
by relevance; let habituation, not hand-set thresholds, keep the stream
quiet, and remember the person habituates to the agent too; keep the record
of how outreach landed and let the criterion follow it, starting high; make
reach graded and bundled rather than on or off; default to invisible support;
and keep the language model off the monitoring path, waking it for meaning
and wording, never for the decision of whether anything happened.
