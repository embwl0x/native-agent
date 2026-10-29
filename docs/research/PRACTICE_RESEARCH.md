# How a person gets good at things

Research on practice and skill, written for Claude on 2026-10-25 as raw
material for the agent design. It covers how people go from slow and
deliberate to fast and automatic at a task, what an agent that does one
person's recurring work on their Mac for months needs from that, and what
artificial agents that learn by use have tried. Each area ends with the
mechanism an agent would need. It does not propose features.

It deepens the paragraph on procedural memory in section 6 of
[MEMORY_RESEARCH.md](MEMORY_RESEARCH.md) ("Habits run on cues"), and leans on
[PERSONALITY_RESEARCH.md](PERSONALITY_RESEARCH.md) for curiosity, interest and
emotion. Where those documents already cover a finding, this one cites it and
moves on.

How sure each finding is:

- *[meta-analytic]*: a meta-analysis or a very large literature agrees.
- *[replicated]*: independent labs have repeated it.
- *[debated]*: real evidence on both sides, or the effect holds and its
  mechanism is contested.
- *[few studies]*: one lab, small samples or one paradigm.
- *[theory]*: a framework or modelling argument more than an effect.
- *[failed replication]*: a famous finding that did not hold up, said
  plainly.

For the agent literature, numbers are the authors' own, on their own
benchmarks, usually judged by their own evaluators. Treat them as
directions, not measurements of this agent.

---

## The answer first

- **Getting good is doing less, not doing the same thing faster.** A novice
  interprets instructions one step at a time, under attention. An expert runs
  compiled procedures, retrieves remembered answers and sees the situation in
  a few large pieces. Practice composes steps, removes interpretation,
  replaces working things out with remembering them, and teaches what to
  ignore. Speed is the by-product. Nobody gets fast by guessing: practice
  moves the whole speed–accuracy curve; it does not slide along it.
- **Learning is a side effect of doing.** In the best-supported theories
  nothing separate does the learning. Every exposure lays down an instance
  (Logan), every impasse that gets resolved leaves a chunk (Soar), and every
  pair of steps that fire together can compile into one (ACT-R). The next
  attempt races what was kept against working it out, and the faster
  reliable route wins. When the kept route wins every time, the task is
  automatic.
- **It only works where the world is consistent.** Automaticity develops
  when the same situation always calls for the same response, and not
  otherwise. Practice explains 24% of performance differences in predictable
  activities and 4% in unpredictable ones. Intuition can be trusted only
  where the environment is regular and feedback is fast and honest. A
  routine is a bet that this case is like the last one.
- **What is learned is narrow.** Skill transfers to the extent that the new
  task shares the old one's elements. Far transfer mostly fails. People are
  reminded of old solutions by surface likeness, and a schema that
  generalises takes at least two cases compared. One success teaches a
  route; only variation teaches where it applies.
- **Expertise is perception.** Experts see a situation as one recognised
  kind, with its cues, its expected next states and its usual move. The same
  expectations are what let them notice that this case is not the usual one.
  Knowing when the routine does not apply is part of the skill, not a check
  bolted onto it.
- **Automaticity has a known price.** A strong habit captures a similar
  action. A step gets dropped once the main goal is met. A familiar solution
  blocks a better one. A routine keeps running after the goal it served has
  stopped mattering. People drop back to deliberate control on surprise and
  on conflict, and when the stakes make deliberation worth what it costs.
- **The feeling of fluency is a poor witness.** People judge easy, blocked
  practice to be better learning when it is worse, and feel they have
  acquired a skill from watching it done when they have not. Beginners
  become overconfident after a few successes. Confidence in a
  skill mostly follows past performance rather than driving future
  performance. Felt competence has to be computed from outcomes, case by
  case.
- **Agents that learn by use converged on the same shape, and fail in the
  same places.** Libraries of verified code skills, workflows induced from
  trajectories, and insights drawn from successes and failures raised
  success rates and cut steps and cost. They fail where people do: skills go
  stale when the interface changes, libraries bloat, routines generalise
  from too little, and, worst, a skill encodes a mistake because success was
  judged badly when it was kept.
- **Where the model sits:** the language model is the cognitive stage. It is
  the slow, general interpreter that works a task out, and the compiler that
  can write what it worked out as a procedure. Its weights never change, so
  every later stage of skill has to be carried by the agent: the traces, the
  compiled routines with their expectations, and the record of how each has
  gone. Practice, for such an agent, is runs that leave traces, folded
  offline into routines that need the model less each time.

---

## 1. From deliberate to automatic

### Three stages in every account

**Fitts and Posner's stages.** Skill learning passes through a *cognitive*
stage (working out what to do, talking oneself through it, many errors), an
*associative* stage (errors drop out, the steps link up) and an *autonomous*
stage (fast, little attention needed, hard to put into words) (Fitts 1964, in
Melton (ed.), *Categories of Human Learning*; Fitts & Posner 1967, *Human
Performance*). *[theory, widely used]* The Dreyfus five-stage model, from
novice following context-free rules to expert seeing what to do, says the
same in more steps (Dreyfus & Dreyfus 1986, *Mind over Machine*). *[theory,
little direct test]*

**The abilities that matter change across the stages.** Early in practice,
general ability predicts performance. Later, perceptual speed does, and late
in practice, psychomotor speed. This happens only on tasks with a consistent
mapping. On inconsistent tasks, general ability keeps predicting performance
however long people practise
([Ackerman 1988](https://doi.org/10.1037/0096-3445.117.3.288)). *[replicated]*
What carries performance moves from reasoning to execution, and only when the
task holds still.

**The brain hands control over.** With practice, activity in the frontal and
parietal control network falls
([Chein & Schneider 2012](https://doi.org/10.1177/0963721411434977)), and
control of trained actions shifts from the associative to the sensorimotor
striatum ([Yin & Knowlton 2006](https://doi.org/10.1038/nrn1919);
[Ashby, Turner & Horvitz 2010](https://doi.org/10.1016/j.tics.2010.02.001)).
*[replicated in animals; human evidence consistent]* The general-purpose
controller does less of the work, not the same work faster.

### Consistent mapping is the precondition

Schneider and Shiffrin trained people to find target letters among
distractors. When a target was always a target (*consistent mapping*), search
became automatic after long practice: fast, parallel, unaffected by load, and
hard to stop. It also pulled attention to the target even when the person was
trying to ignore it. When items swapped roles from trial to trial (*varied
mapping*), search never became automatic, however long they practised
([Schneider & Shiffrin 1977](https://doi.org/10.1037/0033-295X.84.1.1);
[Shiffrin & Schneider 1977](https://doi.org/10.1037/0033-295X.84.2.127)).
*[replicated]* Automaticity is not a reward for repetition. It is what
repetition produces where the same input always calls for the same response.

### ACT-R: knowledge compilation

**Two kinds of knowledge, one direction of travel.** In Anderson's account a
new skill starts as *declarative* knowledge, facts and instructions held in
memory and interpreted by general problem-solving procedures, the "weak
methods". That is slow, error-prone and heavy on working memory. *Knowledge
compilation* turns it into *procedural* knowledge in two ways
([Anderson 1982](https://doi.org/10.1037/0033-295X.89.4.369);
[Anderson 1987](https://doi.org/10.1037/0033-295X.94.2.192)):

- *Proceduralization* builds a rule specific to the domain, with the facts it
  used built in, so they no longer need retrieving.
- *Composition* collapses a sequence of rules that fire together into one.

Tuning then generalises, discriminates and strengthens the compiled rules.

**Production compilation.** In the current theory, whenever two rules fire in
sequence, a rule combining them is proposed. It starts weak and has to win
against the rules it came from on its record of usefulness before it takes
over ([Taatgen & Anderson 2002](https://doi.org/10.1016/S0010-0277(02)00176-2);
[Taatgen & Lee 2003](https://doi.org/10.1518/hfes.45.1.61.27224);
[Anderson et al. 2004](https://doi.org/10.1037/0033-295X.111.4.1036)). The
mechanism reproduced the learning curve on an air-traffic-control task, and
children's regularising of the past tense without any feedback. *[theory,
fits many data sets]*

Four properties matter for an agent:

1. Compilation is triggered by doing. There is no separate learner.
2. The new procedure competes with the old one on its record. It does not
   overwrite it.
3. A compiled rule is *use-specific*. It runs in the direction it was built
   for. Knowing how to read a kind of code and knowing how to write it are
   different procedures, even with the same knowledge behind them (Singley &
   Anderson 1989, *The Transfer of Cognitive Skill*, Harvard UP). *[debated]*
4. Once the facts are built into the procedure, the declarative version can
   fade. Experts often cannot say what they do (section 6).

### Logan: automaticity is remembering

**Instance theory.** Logan proposed that automaticity is a shift from working
an answer out (the "algorithm") to remembering it. Every encounter with a task
is stored as a separate *instance*, whether or not the person means to learn.
Every new encounter retrieves the instances like it. Retrieval and the
algorithm race, and whichever finishes first produces the response. More
instances make the fastest retrieval faster, which predicts a power-law speed
up of the mean *and* of the spread, with the same exponent
([Logan 1988](https://doi.org/10.1037/0033-295X.95.4.492);
[Logan 1992](https://doi.org/10.1037/0278-7393.18.5.883)). *[replicated; the
exact form of the race is debated]*

**The evidence that it is memory.** In alphabet arithmetic ("A + 2 = C?")
the speed-up is item-specific: practised problems get fast, new problems with
the same rule do not. Memorising six facts by rote in a single session
produced the same automaticity as twelve sessions of doing the task, and the
rate of learning depended on how often each item was seen, not on how many
items there were ([Logan & Klapp 1991](https://doi.org/10.1037/0278-7393.17.2.179)).
*[replicated]*

**Strategy shifts, not smooth tuning.** When the response switches from
computing to retrieving, the learning curve bends. Fit separately for each
strategy, individual curves follow the law of practice much better than one
curve for the whole task does
([Rickard 1997](https://doi.org/10.1037/0096-3445.126.3.288);
[Delaney et al. 1998](https://doi.org/10.1111/1467-9280.00001)). *[replicated]*
Improvement is practice on a *method*, and much of it comes from changing
method.

### The shape of the curve

**The power law of practice.** Across a great many tasks, time per trial
falls as a power function of the number of trials: steep at first, then
slower and slower but never quite stopping (Newell & Rosenbloom 1981, in
Anderson (ed.), *Cognitive Skills and Their Acquisition*). Cigar rollers kept
getting faster over years and millions of cycles, until the cycle time of the
machine they fed set the floor
([Crossman 1959](https://doi.org/10.1080/00140135908930419)).

**Repealed for individuals.** Heathcote, Brown and Mewhort fitted both
functions to 40 data sets: 7,910 learning series from 475 people in 24
experiments. The exponential fit better than the power function in every
unaveraged data set. Averaging over people with different rates produced the
power law ([Heathcote, Brown & Mewhort 2000](https://doi.org/10.3758/BF03212979)).
A hierarchical Bayesian reanalysis across many paradigms favoured a *delayed*
exponential in a clear majority of them: slow at the very start, then fast,
then slow ([Evans et al. 2018](https://doi.org/10.1037/rev0000105)).
Individual curves also show abrupt drops, when people learn to ignore
information they had been processing for nothing
([Haider & Frensch 2002](https://doi.org/10.1037/0278-7393.28.2.392)), and are
often better described as pieces joined at strategy changes
([Donner & Hardy 2015](https://doi.org/10.3758/s13423-015-0811-x)).
*[debated; the exponential side is stronger for individuals]*

**What the shape implies.**

- An *exponential* means each trial removes a constant fraction of the time
  that is still removable: one process improving at a fixed relative rate.
- A *power* function means the relative rate itself falls with practice, as
  it would if improvement came from a growing pool of instances (Logan) or
  from a hierarchy of chunks in which each larger chunk recurs less often
  (Newell and Rosenbloom).
- *Steps* in an individual curve mean a change of method.

Read together: within one method, a person improves at a roughly constant
relative rate toward a floor. The big gains are discrete, when a new method
takes over. The floor is the irreducible cost of the actions themselves.

**Mechanism for an agent:** A task starts as instructions interpreted by a
general problem solver: slow, costly, error-prone and needing full attention.
Each attempt should leave two things behind. One is an instance: this
situation, what was done, what came of it. The other is the chance to compile
a run of steps into one procedure with its facts built in. Next time, the
kept routes race the general one, and the fastest *reliable* route wins. None
of this is a separate learner; it is part of doing. It produces automaticity
only where a situation maps consistently onto the same response. The large
gains come in steps, when a new route takes over, and the floor is what the
actions themselves cost.

---

## 2. Chunking and composed procedures

### Chunks in perception and memory

**Masters see bigger pieces.** After a five-second look at a position from a
real game, chess masters put back far more pieces than weaker players. For
random positions their advantage largely disappeared. They were recalling
*chunks*, groups of pieces bound by attack, defence and typical structure
([Chase & Simon 1973](https://doi.org/10.1016/0010-0285(73)90004-2), after
de Groot 1965, *Thought and Choice in Chess*). A small expert advantage does
survive with random positions
([Gobet & Simon 1996](https://doi.org/10.3758/BF03200937)). *[replicated]*

**Templates.** Gobet and Simon extended chunks into *templates*: large
recurring patterns with slots that can be filled quickly. Templates explain
how masters remember several boards at once, and why longer study time
helps experts more than novices
([Gobet & Simon 1996](https://doi.org/10.1006/cogp.1996.0011);
[Gobet & Simon 2000](https://doi.org/10.1207/s15516709cog2404_4);
[Gobet et al. 2001](https://doi.org/10.1016/S1364-6613(00)01662-4)). Experts'
apparently huge working memory in their domain comes from *retrieval
structures* in long-term memory
([Ericsson & Kintsch 1995](https://doi.org/10.1037/0033-295X.102.2.211); see
MEMORY_RESEARCH.md, section 6). *[replicated]*

**Chunking is specific to the material.** One student practised digit span
for more than 200 hours and went from about 7 digits to about 80, by recoding
digit groups as running times they knew. Their span for letters stayed where it
was ([Ericsson, Chase & Faloon 1980](https://doi.org/10.1126/science.7375930)).
*[replicated; few subjects]*

### Chunking as the engine of practice

**The chunking theory of practice.** Newell and Rosenbloom proposed that
practice works by building chunks over chunks. Larger chunks cover patterns
that recur less often, which by itself produces a decelerating learning curve
(Newell & Rosenbloom 1981; Rosenbloom & Newell 1987, in Klahr, Langley &
Neches (eds.), *Production System Models of Learning and Development*).
*[theory]*

**Soar: learning as a by-product of getting unstuck.** In Soar, when problem
solving reaches an *impasse* (nothing it knows says what to do next), it sets
up a subgoal and works it out. When the subgoal returns a result, Soar
automatically builds a *chunk*: a rule whose conditions are the parts of the
situation that mattered to the result and whose action is the result. Next
time, the chunk fires and the impasse never happens
([Laird, Rosenbloom & Newell 1986](https://doi.org/10.1007/BF00116249);
[Laird, Newell & Rosenbloom 1987](https://doi.org/10.1016/0004-3702(87)90050-6)).
The one mechanism produced speed-up with practice, transfer within and across
tasks, and the learning of strategies. There is no learning module; learning
is what resolving an impasse leaves behind. *[theory, demonstrated in many
systems]*

**Its two known costs.**

- *Expensive chunks.* Some learned rules cost more to match than they save,
  so the system gets slower as it learns. The fix was to restrict what a
  chunk may express
  ([Tambe, Newell & Rosenbloom 1990](https://doi.org/10.1007/BF00117107)).
  This is the same *utility problem* that PRODIGY met (section 8).
- *Overgeneral chunks.* If the reasoning in the subgoal depended on
  something the chunk's conditions do not test, the chunk fires where it
  should not (Laird 2012, *The Soar Cognitive Architecture*, MIT Press).

### Macro-operators

**STRIPS and the triangle table.** After a robot plan succeeded, STRIPS
generalised it, replacing constants with parameters while keeping the
dependencies between steps, and stored it as a macro-operator. The macro was
kept as a *triangle table*: for each step, which conditions it needs, and
which earlier step or the starting state supplied each one. During execution
the monitor used the table to find the latest point in the plan whose
conditions held in the world *now*. That let it skip steps that had become
unnecessary, redo steps something had undone, and see when no remaining part
of the plan applied, which meant planning again
([Fikes, Hart & Nilsson 1972](https://doi.org/10.1016/0004-3702(72)90051-3)).
*[classic; demonstrated on the Shakey robot]* A composed procedure that
records why each step is there can monitor itself.

**Macro tables and filters.** Korf showed that a table of macros can solve
puzzles such as Rubik's cube without search, and that the macros can be
learned from search ([Korf 1985](https://doi.org/10.1016/0004-3702(85)90012-8)).
Macros learned from solved problems speed up planners, but only when they are
filtered. Too many macros widen the search they were meant to shorten
([Iba 1989](https://doi.org/10.1007/BF00116836);
[Botea et al. 2005](https://doi.org/10.1613/jair.1696)). *[replicated]*

### When composed procedures go wrong

**Einstellung: mechanisation.** Luchins gave people water-jar problems that
could all be solved by one long formula. Most of them went on using it when a
much simpler method would do, and many failed a problem that only the simple
method could solve. A warning ("don't be blind") helped some of them. Luchins
called this *mechanisation*
([Luchins 1942](https://doi.org/10.1037/h0093502)). *[replicated; classic]*

**In experts, and how it works.** When a familiar but slower mate was on the
board, strong chess players looked less well for the shorter one. The effect
brought experts down to about the level of players three standard deviations
weaker, and the strongest players were least affected
([Bilalić, McLeod & Gobet 2008a](https://doi.org/10.1016/j.cogpsych.2007.02.001)).
Eye tracking showed the mechanism: players who said they were looking for a
better move kept looking at the squares that mattered for the familiar one
([Bilalić, McLeod & Gobet 2008b](https://doi.org/10.1016/j.cognition.2008.05.005);
converging evidence in [Sheridan & Reingold 2013](https://doi.org/10.1371/journal.pone.0075796)).
*[replicated]* The first solution that comes to mind steers attention toward
evidence that fits it. Experts with deep knowledge can also be hurt more than
novices when the rules of the domain change at a deep level (Frensch &
Sternberg 1989, in Sternberg (ed.), *Advances in the Psychology of Human
Intelligence*, vol. 5). *[few studies]* Management research calls the general
pattern *cognitive entrenchment*
([Dane 2010](https://doi.org/10.5465/amr.35.4.zok579)). *[theory]*

**Help that helps novices hurts experts.** Worked examples beat problem
solving for novices
([Sweller & Cooper 1985](https://doi.org/10.1207/s1532690xci0201_3);
review [Atkinson et al. 2000](https://doi.org/10.3102/00346543070002181)),
especially when learners explain the steps to themselves
([Chi et al. 1989](https://doi.org/10.1207/s15516709cog1302_1); meta-analysis
g = .55, [Bisra et al. 2018](https://doi.org/10.1007/s10648-018-9434-x)). The
same support hurts learners who already have the schema, because they have to
process what they already know
([Kalyuga et al. 2003](https://doi.org/10.1207/S15326985EP3801_4)).
*[replicated]* What a learner needs in front of them changes with the stage.

**Mechanism for an agent:** Doing a task should leave larger units behind. One
kind is perceptual: this screen is that kind of state. The other is a
composed procedure: these five steps are one. A composed procedure should be
stored with its parameters and, for each step, what it needs and what
supplied it. Then running it can check where it stands, skip what is already
true, redo what was undone, and see when nothing left in it applies. Two
failures are built into the method. A chunk can cost more to find and check
than it saves, which is a question of utility. And a familiar procedure can
steer attention away from a better one, which is why the procedure's own
success cannot be the only thing the agent attends to. The examples and
instructions that helped while a routine was being learned should leave the
context once the routine is compiled.

---
## 3. What drives improvement

### Deliberate practice, and how much it explains

**The claim.** Ericsson, Krampe and Tesch-Römer defined *deliberate practice*
as effortful activity designed to improve performance: a well-defined goal
just beyond current ability, immediate feedback, and repetition with
refinement. It is usually not enjoyable. They found that the best student
violinists had accumulated the most of it, and argued that individual
differences in ultimate performance can largely be accounted for by it
([Ericsson, Krampe & Tesch-Römer 1993](https://doi.org/10.1037/0033-295X.100.3.363)).

**The meta-analyses.**

- *Across domains.* Over 157 correlations, deliberate practice explained 12%
  of the variance in performance: 26% for games, 21% for music, 18% for
  sports, 4% for education, under 1% for professions. Predictability of the
  task environment was a significant moderator. Practice explained 24% in
  highly predictable activities (running), 12% in moderately predictable ones
  (fencing) and 4% in unpredictable ones (handling an aviation emergency)
  ([Macnamara, Hambrick & Oswald 2014](https://doi.org/10.1177/0956797614535810)).
  *[meta-analytic]*
- *Sports.* 18% overall, and only 1% among elite performers. Athletes who
  reached a high level had not started earlier
  ([Macnamara, Moreau & Hambrick 2016](https://doi.org/10.1177/1745691616635591)).
  *[meta-analytic]*
- *Music.* Accumulated task-relevant practice correlated r = .61 with musical
  achievement after correction, about 37% of the variance
  ([Platz et al. 2014](https://doi.org/10.3389/fpsyg.2014.00646)). In chess
  and music, practice explained about a third of the reliable variance
  ([Hambrick et al. 2014](https://doi.org/10.1016/j.intell.2013.04.001)).
  *[meta-analytic]*

**The replication.** A preregistered, double-blind replication of the original
violin study did not reproduce its core finding that accumulated practice
separated each skill level. The effect was substantial but much smaller.
Practice designed by a teacher was no better than practice alone
([Macnamara & Maitra 2019](https://doi.org/10.1098/rsos.190327)).
*[failed replication of the original's size]*

**The rebuttal.** Ericsson argued that the meta-analyses counted activities
that were not deliberate practice in their sense, and that by the original
definition practice explains considerably more
([Ericsson & Harwell 2019](https://doi.org/10.3389/fpsyg.2019.02396)). Macnamara's group, for its part, argues that accounts of expertise built
on practice and environment overstate what they can explain
([Moreau, Macnamara & Hambrick 2019](https://doi.org/10.1177/0963721418797300)).
*[debated]*

What both sides accept: the amount and design of practice matter a lot; what
counts as practice is hard to define after the fact; practice explains most
in predictable environments and least among people who are already very good.

### Feedback

**Feedback helps on average and often hurts.** Over 607 effect sizes,
feedback interventions improved performance by d = .41, but over a third of
them made performance *worse*. Feedback lost its effect as it drew attention
away from the task and toward the self, as praise and comparison do
([Kluger & DeNisi 1996](https://doi.org/10.1037/0033-2909.119.2.254)).
*[meta-analytic]* A later meta-analysis of educational feedback (435
studies) found d = .48, with larger effects the more information the feedback
carried, and larger effects on cognitive and motor skills than on motivation
([Wisniewski, Zierer & Hattie 2020](https://doi.org/10.3389/fpsyg.2019.03087);
framework [Hattie & Timperley 2007](https://doi.org/10.3102/003465430298487)).
*[meta-analytic]*

**Two textbook principles of motor learning did not survive bias correction.**

- *Less frequent feedback.* The "guidance hypothesis" held that feedback
  after every trial helps practice but harms later retention, because the
  learner leans on it
  ([Salmoni, Schmidt & Walter 1984](https://doi.org/10.1037/0033-2909.95.3.355);
  [Winstein & Schmidt 1990](https://doi.org/10.1037/0278-7393.16.4.677)). A
  meta-analysis of 61 papers found no significant effect of reduced feedback
  frequency at any time point, and a literature of severely underpowered
  studies ([McKay et al. 2022a](https://doi.org/10.1016/j.psychsport.2022.102165)).
  *[failed replication]* Principles found with simple lab skills often do not
  generalise to complex ones, where frequent feedback can help
  ([Wulf & Shea 2002](https://doi.org/10.3758/BF03196276)).
- *Letting learners choose.* Letting learners control part of their practice
  appeared to help (g = .44), but the benefit came only from published
  studies. After correcting for selective reporting the estimate fell to
  g = .11, not distinguishable from zero
  ([McKay et al. 2022b](https://doi.org/10.15626/mp.2021.2803)).
  *[failed replication]*

### Errors and prediction error

**Learning is driven by surprise.** Associative learning is proportional to
the difference between what was predicted and what happened (Rescorla &
Wagner 1972, in Black & Prokasy (eds.), *Classical Conditioning II*).
Dopamine neurons signal this *reward prediction error*, and stop responding
once the outcome is predicted
([Schultz, Dayan & Montague 1997](https://doi.org/10.1126/science.275.5306.1593)).
*[replicated]* Once everything is predicted, nothing more is learned.

**Errors that get corrected teach the most.** Making an error and then getting
corrective feedback produces better learning than avoiding the error, and
errors made with high confidence are the ones corrected best, the
*hypercorrection* effect
([Butterfield & Metcalfe 2001](https://doi.org/10.1037/0278-7393.27.6.1491);
review [Metcalfe 2017](https://doi.org/10.1146/annurev-psych-010416-044022)).
*[replicated]* Training that encourages errors and teaches people to manage
them beat error-avoiding training by d = .44 overall. The gain was larger
after training (d = .56) than during it, and largest on tasks structurally
different from the ones trained (d = .80)
([Keith & Frese 2008](https://doi.org/10.1037/0021-9010.93.1.59)).
*[meta-analytic]*

### Desirable difficulties: learning is not performance

**The principle.** Performance during practice is an unreliable index of what
was learned. Conditions that make practice look good (massing, blocking,
constant conditions, constant guidance) often make retention and transfer
worse. Conditions that make practice look worse (spacing, mixing, testing,
variation) often make them better (Bjork 1994, in Metcalfe & Shimamura (eds.),
*Metacognition*; review [Soderstrom & Bjork 2015](https://doi.org/10.1177/1745691615569000)).
*[replicated, with the caveats below]*

**Retrieval practice.** Recalling something does more for later memory than
studying it again
([Roediger & Karpicke 2006](https://doi.org/10.1111/j.1467-9280.2006.01693.x);
meta-analyses [Rowland 2014](https://doi.org/10.1037/a0037559),
[Adesope, Trevisan & Sundararajan 2017](https://doi.org/10.3102/0034654316689306)).
Recall tests help more than recognition tests (Rowland). A review of study
techniques rated practice testing and spaced practice the two most useful
([Dunlosky et al. 2013](https://doi.org/10.1177/1529100612453266)).
*[meta-analytic for facts]* For skills the evidence is thinner: a test at the
end of a resuscitation course improved the skill two weeks later
([Kromann, Jensen & Ringsted 2009](https://doi.org/10.1111/j.1365-2923.2008.03245.x)).
*[few studies]* For a procedure, retrieval practice means doing it from
memory instead of reading it.

**Spacing.** Spreading practice out helps retention
([Cepeda et al. 2006](https://doi.org/10.1037/0033-2909.132.3.354)). The best
gap grows with how long the knowledge must last: about 20 to 40% of the
retention interval for a week, about 5 to 10% for a year
([Cepeda et al. 2008](https://doi.org/10.1111/j.1467-9280.2008.02209.x)).
*[meta-analytic for verbal material]* For tasks, the overall benefit was
d = .46, smaller for complex tasks, and larger in less rigorous studies
([Donovan & Radosevich 1999](https://doi.org/10.1037/0021-9010.84.5.795);
motor [Lee & Genovese 1988](https://doi.org/10.1080/02701367.1988.10609373)).
*[meta-analytic; weaker for complex skills]*

**Interleaving.** Practising several skills in random order makes practice
worse and retention and transfer better: the *contextual interference*
effect ([Shea & Morgan 1979](https://doi.org/10.1037/0278-7393.5.2.179)). In
motor learning it holds in the lab and shrinks in applied settings
([Brady 2004](https://doi.org/10.2466/pms.99.1.116-126)). One meta-analysis
of sports practice found only small, non-significant effects and called the
benefit a myth ([Ammar et al. 2023](https://doi.org/10.1016/j.edurev.2023.100537)),
and a rival one found it robust for transfer
([Czyż et al. 2024](https://doi.org/10.3389/fpsyg.2024.1377122)).
*[debated for motor skills]* For cognitive categories and problem types the
evidence is stronger. Interleaving improved mathematics learning
([Rohrer & Taylor 2007](https://doi.org/10.1007/s11251-007-9015-8)), including
in a classroom trial ([Rohrer, Dedrick & Stershic 2015](https://doi.org/10.1037/edu0000001)),
and learning painters' styles
([Kornell & Bjork 2008](https://doi.org/10.1111/j.1467-9280.2008.02127.x)).
A meta-analysis found the benefit largest when the categories resemble each
other, and found interleaving harmful for word lists and expository text
([Brunmair & Richter 2019](https://doi.org/10.1037/bul0000209)).
*[meta-analytic]* The working explanation: interleaving forces a choice of
method on every trial, so it trains *discrimination*, knowing which
procedure this problem needs. Blocked practice never asks that question.

**Variation.** Schema theory holds that varying the parameters of a skill
across practice builds a rule relating parameters to outcomes, which serves
new variants ([Schmidt 1975](https://doi.org/10.1037/h0076770)). *[theory;
mixed support]*

**Sleep and rest.** Overnight gains in a finger-tapping sequence were taken as
evidence that sleep improves skills
([Walker et al. 2002](https://doi.org/10.1016/S0896-6273(02)00746-8)). The
gains were later traced largely to fatigue built up during training, time of
day and averaging ([Rickard et al. 2008](https://doi.org/10.1037/0278-7393.34.4.834);
[Brawn et al. 2010](https://doi.org/10.1523/JNEUROSCI.3295-10.2010)). A
meta-analysis of 34 articles, 88 groups and 1,296 subjects found no evidence
that sleep enhances motor learning once those factors are accounted for, and
an inconsistent sign that it stabilises it
([Pan & Rickard 2015](https://doi.org/10.1037/bul0000009)).
*[failed replication of enhancement]* During practice itself, gains appear
across rests of a few seconds
([Bönstrup et al. 2019](https://doi.org/10.1016/j.cub.2019.02.049)), linked to
fast neural replay ([Buch et al. 2021](https://doi.org/10.1016/j.celrep.2021.109193)).
That too may be the dissipation of fatigue
([Gupta & Rickard 2022](https://doi.org/10.1038/s41539-022-00140-z)).
*[debated]* Compare memory, where offline reorganisation into gist and schema
is well supported (MEMORY_RESEARCH.md, section 2).

**Mechanism for an agent:** Improvement is driven by error noticed against an
expectation and by feedback about the task, never about the self. Practice
pays most where the environment is predictable. A run that went smoothly is a
poor measure of what was learned. What predicts later performance is doing
the task from memory, at intervals, mixed in with similar tasks that force a
choice of method. Errors that are noticed and corrected teach more than
errors avoided, and a confident error teaches most. Offline processing should
not be expected to make a skill better on its own; the human evidence for
that is weak. What offline work can reliably do is compare, reorganise and
compress what was done.

---

## 4. Transfer: one routine, the next task

### Identical elements

**Transfer follows shared parts.** Thorndike and Woodworth trained people to
estimate the areas of one kind of shape and found little improvement on
others. They concluded that improvement in one function helps another only to
the extent that they share identical elements
([Thorndike & Woodworth 1901](https://doi.org/10.1037/h0074898)).
*[classic; supported in spirit]*

**Shared procedures predict transfer.** People who learned one text editor
learned the next faster, and the savings tracked the procedures the editors
shared ([Singley & Anderson 1985](https://doi.org/10.1016/S0020-7373(85)80047-X);
Singley & Anderson 1989). Taatgen's primitive-elements theory breaks skills
into still smaller elements that move and compare single pieces of
information regardless of content. It fits the amount of transfer better than
whole shared procedures do, and explains some transfer between control tasks
that share no surface features
([Taatgen 2013](https://doi.org/10.1037/a0033138)). *[theory with good fits]*
Small, content-free units transfer further than whole compiled tasks.

### Far transfer mostly fails

Barnett and Ceci mapped how far transfer can reach, by content (what is
transferred) and by context (domain, physical setting, time, function, social
setting, modality) ([Barnett & Ceci 2002](https://doi.org/10.1037/0033-2909.128.4.612)).
The far end of that map is mostly empty:

- *Chess, music and working-memory training* show near-zero far transfer once
  placebo effects and study quality are accounted for
  ([Sala & Gobet 2017](https://doi.org/10.1177/0963721417712760);
  [Sala & Gobet 2019](https://doi.org/10.1016/j.tics.2018.10.004)).
  *[meta-analytic]*
- *Working-memory training* improves similar tasks, with no reliable transfer
  to intelligence or school outcomes
  ([Melby-Lervåg & Hulme 2013](https://doi.org/10.1037/a0028228);
  [Melby-Lervåg, Redick & Hulme 2016](https://doi.org/10.1177/1745691616635612)).
  The well-known claim that n-back training raises fluid intelligence failed
  in a randomised, placebo-controlled test
  ([Redick et al. 2013](https://doi.org/10.1037/a0029082)).
  *[failed replication]*
- *Commercial brain training* improves the trained tasks and closely related
  ones, with little evidence beyond
  ([Simons et al. 2016](https://doi.org/10.1177/1529100616661983)).
  *[meta-analytic]*

### Analogy: retrieved by surface, used by structure

**People do not notice the analogy they have.** People read a story about a
general who splits their army to converge on a fortress, then attempt Duncker's
problem of destroying a tumour with rays. Few used the story unprompted. Told
to use it, most did ([Gick & Holyoak 1980](https://doi.org/10.1016/0010-0285(80)90013-4)).
Reading *two* analogous stories and comparing them produced a schema, and with
it more spontaneous transfer
([Gick & Holyoak 1983](https://doi.org/10.1016/0010-0285(83)90002-6)).
Comparing two cases side by side markedly increased transfer of negotiation
strategies compared with studying the same two cases separately
([Gentner, Loewenstein & Thompson 2003](https://doi.org/10.1037/0022-0663.95.2.393)).
*[replicated]*

**Retrieval and soundness come apart.** Analogy works by mapping relational
structure ([Gentner 1983](https://doi.org/10.1207/s15516709cog0702_3)). But
people *retrieve* past cases mostly by surface similarity, while they *judge*
an analogy's soundness by structure
([Gentner, Rattermann & Forbus 1993](https://doi.org/10.1006/cogp.1993.1013)).
Learners of a new skill are reminded of earlier examples by surface features.
That helps when surface and structure agree and misleads when they do not
([Ross 1984](https://doi.org/10.1016/0010-0285(84)90014-8);
[Ross 1987](https://doi.org/10.1037/0278-7393.13.4.629)). Novices sort physics
problems by the objects in them, experts by the principle that solves them
([Chi, Feltovich & Glaser 1981](https://doi.org/10.1207/s15516709cog0502_2)).
*[replicated]*

### Learning to learn, and two kinds of expert

**Transfer as faster learning.** Bransford and Schwartz argued that the
transfer that matters most is *preparation for future learning*: what was
learned makes the next thing quicker to learn, even when it cannot be applied
directly ([Bransford & Schwartz 1999](https://doi.org/10.3102/0091732X024001061)).
Monkeys given hundreds of discrimination problems came to solve new ones in
a single trial, having learned *how* to learn them
([Harlow 1949](https://doi.org/10.1037/h0062474)). *[classic]*

**Two roads.** Salomon and Perkins distinguish the *low road* (automatic
transfer of well-practised routines to very similar situations, built by
varied practice) from the *high road* (deliberate abstraction of a principle
and a conscious search for where it applies)
([Salomon & Perkins 1989](https://doi.org/10.1207/s15326985ep2402_1)).
*[theory]*

**Routine and adaptive expertise.** Hatano and Inagaki distinguish *routine*
experts, fast and accurate on familiar problems, from *adaptive* experts, who
understand why their procedures work and can invent new ones. Adaptive
expertise grows from variation, understanding, and freedom to explore
without pressure to perform (Hatano & Inagaki 1986, in Stevenson, Azuma &
Hakuta (eds.), *Child Development and Education in Japan*). *[theory]* The
error-management results above (bigger gains on structurally new tasks) are
some of the best evidence that the adaptive kind can be trained.

**Mechanism for an agent:** A learned routine transfers to the next task only
as far as they share elements: the same states, the same steps, the same
goal. One routine should therefore not be expected to cover "tasks like this"
until the agent has seen the variation. Retrieval of a past routine will be
pulled by surface likeness (the same app, the same words in the request), so
the match has to be checked on structure (the same starting state, the same
effects, the same goal) before the routine runs. Generalisation should come
from comparing at least two cases: what they share becomes the routine, what
differed becomes a parameter. Small general primitives (find this element,
read this field, confirm this change) transfer further than whole compiled
tasks. The most valuable transfer is learning the next routine faster, not
reusing this one.

---
## 5. Expertise as perception

### Seeing what kind of situation this is

**Recognition comes first.** Klein's team interviewed fireground commanders
about their hardest decisions. The commanders rarely compared options. They
recognised the situation as a familiar kind, and the recognition came with
plausible goals, the cues worth watching, expectations of what would happen
next, and a typical action. They checked the action by imagining it played
out, and only if that failed did they adjust it or try the next
([Klein, Calderwood & Clinton-Cirocco 1986](https://doi.org/10.1177/154193128603000616);
Klein 1993, in Klein et al. (eds.), *Decision Making in Action*; Klein 1998,
*Sources of Power*). *[few studies; widely corroborated in naturalistic
decision research]* This is the *recognition-primed decision* model.

**When recognition can be trusted.** Kahneman and Klein, from opposite
camps, agreed on the conditions. Expert intuition is reliable only in an
environment regular enough to be predictable, and only for someone who has
had the chance to learn its regularities through long practice with fast,
unambiguous feedback. Without both, people develop confidence without skill,
and subjective experience is not a reliable indicator of accuracy
([Kahneman & Klein 2009](https://doi.org/10.1037/a0016755)). *[consensus]*

### The eyes of an expert

- **Wider span, for meaningful patterns.** Chess experts take in more of the
  board per fixation, for real positions but not random ones, and in a check
  detection task they fixate between pieces rather than on them
  ([Reingold et al. 2001](https://doi.org/10.1111/1467-9280.00309);
  [Charness et al. 2001](https://doi.org/10.3758/BF03206384)). *[replicated]*
- **Across professions.** A meta-analysis of eye tracking in medicine,
  sport, transport and other fields found that experts make shorter
  fixations, look more at task-relevant areas and less at irrelevant ones,
  and get to the relevant areas sooner
  ([Gegenfurtner, Lehtinen & Säljö 2011](https://doi.org/10.1007/s10648-011-9174-7)).
  *[meta-analytic]*
- **Gist before search.** Radiologists detect that a mammogram is abnormal
  above chance from a half-second glimpse, without being able to say where
  ([Evans et al. 2013](https://doi.org/10.3758/s13423-013-0459-3)).
  *[few studies]*
- **The cost of a schema.** A gorilla 48 times the size of a typical nodule
  was inserted into a lung scan. 83% of 24 radiologists did not see it, and
  most of those who missed it looked straight at it
  ([Drew, Võ & Wolfe 2013](https://doi.org/10.1177/0956797613479386)).
  *[few studies]* Expert perception sees what the task schema expects. That
  is both its speed and its blindness.

### Learning the cues, and handing them over

**Regularities are learned without being noticed.** People learn the rules of
artificial grammars and the structure of repeated sequences without being
able to state them ([Reber 1967](https://doi.org/10.1016/S0022-5371(67)80149-X);
[Nissen & Bullemer 1987](https://doi.org/10.1016/0010-0285(87)90002-8)).
*[replicated; how unaware people really are is debated]* Practice tunes which
features perception extracts, splitting some apart and fusing others into
units, and this can be trained directly
([Goldstone 1998](https://doi.org/10.1146/annurev.psych.49.1.585);
[Kellman & Garrigan 2009](https://doi.org/10.1016/j.plrev.2008.12.001)).
*[replicated]*

**Some intuition is a nameable cue.** Sexing day-old chicks was considered a
skill that takes years. An expert of 50 years was interviewed and observed,
and their knowledge was boiled down to one instruction about where to look and
which contrast in shape to judge. Novices given that instruction went from
slightly above chance to the accuracy of a sample of experts on the test
pictures; their agreement with the experts across items rose from .21 to .82
([Biederman & Shiffrar 1987](https://doi.org/10.1037/0278-7393.13.4.640)).
*[few studies]* Some expertise can be stated and handed over. Some cannot.

### Programmers and typists

**Programmers.** Expert programmers hold *programming plans* (stereotyped code
fragments for common goals) and *rules of discourse* (conventions for how
plans are put together). When programs broke those conventions, experts'
advantage over novices largely disappeared, as chess masters' does for random
positions ([Soloway & Ehrlich 1984](https://doi.org/10.1109/TSE.1984.5010283);
recall by chunks, [McKeithen et al. 1981](https://doi.org/10.1016/0010-0285(81)90012-8)).
*[few studies; consistent with the chess work]*

**Typists: two loops.** Skilled typing runs as an *outer loop* that deals in
words and what appears on the screen, and an *inner loop* that turns words
into keystrokes ([Logan & Crump 2011](https://doi.org/10.1016/B978-0-12-385527-5.00001-2)).

- The outer loop does not know what the inner one does. Asked to type only
  the letters assigned to one hand, typists slowed down and made more
  errors, because the outer loop had to monitor the inner loop's output
  ([Logan & Crump 2009](https://doi.org/10.1111/j.1467-9280.2009.02442.x)).
- Error detection happens in both loops, separately. When the experimenters
  silently corrected typists' errors or inserted errors, the typists took
  credit for the corrected words and blame for the inserted ones, going by
  the screen. Their fingers slowed after their own real errors even when the
  screen showed none, and not after inserted ones
  ([Logan & Crump 2010](https://doi.org/10.1126/science.1190483)).

*[replicated within one lab]* Skilled older typists compensate for slower
fingers by looking further ahead in the text
([Salthouse 1984](https://doi.org/10.1037/0096-3445.113.3.345)). *[replicated]*

### Knowing when the routine does not apply

In the recognition-primed model the recognised kind carries *expectancies*,
and a violated expectancy is what makes the expert reassess (Klein 1993). In
the data–frame account of sensemaking, anomalies prompt questioning of the
frame. People also protect a frame by explaining anomalies away
([Klein, Moon & Hoffman 2006](https://doi.org/10.1109/MIS.2006.100)).
*[theory]* The Einstellung work (section 2) shows how: the first frame steers
attention toward what confirms it. The strongest experts were least
susceptible, so recognising when the usual move is wrong is itself part of
expertise, and it grows with it.

**Mechanism for an agent:** An expert agent sees a situation as a recognised
kind before it acts: which state of which app this is, what usually comes
next, what usually goes wrong, which routine fits. The recognition should
carry expectations, and the same expectations are what detect the case that
is not routine. Recognition should be trusted only in the regular parts of
the person's world that give fast, honest feedback (a mail client's flow, a
build that passes or fails), not in ambiguous requests or rare events. A
strong schema makes the agent blind to what the schema leaves out. Error
detection belongs at two levels: inside a routine (did this step do what it
should) and outside it (does the result look like what was wanted). Some of
what the agent learns can be named as a cue and kept explicitly; some stays
in the traces.

---

## 6. What automaticity costs, and when to drop back

### Slips, lapses and strong-but-wrong rules

**Action slips.** Norman classified slips as faults in activating and
triggering action schemas
([Norman 1981](https://doi.org/10.1037/0033-295X.88.1.1)):

- *capture errors*, where a frequent sequence takes over from a similar one
  at a shared step;
- *description errors*, where the right action lands on the wrong object;
- *loss of activation*, where the goal is forgotten mid-sequence;
- *mode errors*, where an action right in one mode is made in another.

Reason's diary studies collected such slips from everyday life and found
habit intrusions among the recurrent kinds (Reason 1979, in Underwood &
Stevens (eds.), *Aspects of Consciousness*, vol. 1). *[classic, descriptive]*

**Three levels of error.** Rasmussen separated *skill-based* behaviour
(automatic routines), *rule-based* behaviour (stored if-then rules) and
*knowledge-based* behaviour (reasoning about a new situation)
([Rasmussen 1983](https://doi.org/10.1109/TSMC.1983.6313160)). Reason mapped
errors onto them: slips and lapses in routines, rule-based mistakes
(misapplying a good rule, or applying a bad one, often "strong but wrong"),
and knowledge-based mistakes in novel reasoning
([Reason 1990](https://doi.org/10.1017/CBO9781139062367)). *[theory, widely
used in safety science]* For an agent that compiles routines, the dangerous
class is the rule-based mistake: a routine that is wrong but well practised.

**How routines are selected.** Norman and Shallice proposed that routine
action schemas compete automatically for control ("contention scheduling"),
while a *supervisory attentional system* biases the competition when a
situation is new, dangerous, difficult or calls for overcoming a habit
(Norman & Shallice 1986, in Davidson, Schwartz & Shapiro (eds.),
*Consciousness and Self-Regulation*, vol. 4; model
[Cooper & Shallice 2000](https://doi.org/10.1080/026432900380427); an
alternative without explicit hierarchy,
[Botvinick & Plaut 2004](https://doi.org/10.1037/0033-295X.111.2.395)).
*[theory]*

**The step after the goal.** *Postcompletion errors*, like leaving the card in
the cash machine, happen on a step that remains after the main goal is
satisfied, and more often under working-memory load
([Byrne & Bovair 1997](https://doi.org/10.1207/s15516709cog2101_2)).
*[replicated]* The goal held in mind is what drives each step, and goals
decay and get displaced
([Altmann & Trafton 2002](https://doi.org/10.1207/s15516709cog2601_2)).
Interruptions averaging 2.8 seconds doubled the rate of losing one's place in
a sequence, and 4.4 seconds tripled it, while leaving other errors untouched
([Altmann, Trafton & Hambrick 2014](https://doi.org/10.1037/a0030986)).
*[replicated]*

### Habits and goals

**Devaluation.** Rats trained moderately to press a lever stopped pressing
when the food it earned was made unpleasant: the action was goal-directed.
After extended training they kept pressing: the action had become a habit,
run by the stimulus without regard to the outcome
([Adams & Dickinson 1981](https://doi.org/10.1080/14640748108400816);
[Adams 1982](https://doi.org/10.1080/14640748208400878);
[Dickinson 1985](https://doi.org/10.1098/rstb.1985.0010)). *[replicated in
animals]*

**Two controllers and an arbiter.** In the computational account, a
*model-based* controller plans with a model of the world (accurate, flexible,
costly), and a *model-free* controller uses cached values of actions (cheap,
fast, slow to notice change). Control goes to whichever is more certain, so
habits take over when the cached values have become reliable
([Daw, Niv & Dayan 2005](https://doi.org/10.1038/nn1560)), or whichever gives
more value for its time ([Keramati, Dezfouli & Piray 2011](https://doi.org/10.1371/journal.pcbi.1002055)).
People mix the two ([Daw et al. 2011](https://doi.org/10.1016/j.neuron.2011.02.027);
review [Dolan & Dayan 2013](https://doi.org/10.1016/j.neuron.2013.09.007)).
They plan more when planning is more accurate than the habit *and* the stakes
are raised, and are indifferent to stakes when both give the same accuracy
([Kool, Gershman & Cushman 2017](https://doi.org/10.1177/0956797617708288)).
*[replicated]* An alternative account has habits store no values at all:
they are recently taken actions, strengthened by being taken
([Miller, Shenhav & Ludvig 2019](https://doi.org/10.1037/rev0000120)).
*[theory]*

**The human evidence is weaker than the textbook.**

- The one human study that showed overtraining producing devaluation-proof
  habits ([Tricomi, Balleine & O'Doherty 2009](https://doi.org/10.1111/j.1460-9568.2009.06796.x))
  failed twice to replicate, as part of five failures to induce habits by
  overtraining in healthy people
  ([de Wit et al. 2018](https://doi.org/10.1037/xge0000402)).
  *[failed replication]*
- Behaviour on the standard two-step task that looked model-free was largely
  explained as model-based inference using a wrong model of the task
  ([Feher da Silva & Hare 2020](https://doi.org/10.1038/s41562-020-0905-y)).
  *[debated]*

**Habits in daily life.** In hourly diaries, behaviour done almost daily in a
stable context went with thinking about something else and with less stress
([Wood, Quinn & Kashy 2002](https://doi.org/10.1037/0022-3514.83.6.1281)).
Forming a new daily habit took from 18 to 254 days to reach 95% of its
plateau, and missing a single day did not matter
([Lally et al. 2010](https://doi.org/10.1002/ejsp.674)). When students
transferred universities, old habits lost their hold where the context
changed, and intentions guided behaviour instead
([Wood, Tam & Witt 2005](https://doi.org/10.1037/0022-3514.88.6.918); review
[Wood & Rünger 2016](https://doi.org/10.1146/annurev-psych-122414-033417)).
*[replicated]* Habit is bound to its context, and a change of context returns
control to deliberation.

### When to drop back to deliberate control

- **Conflict.** When incompatible responses are active at once, the conflict
  itself is a signal to apply more control, and control tightens after
  conflict and after errors
  ([Botvinick et al. 2001](https://doi.org/10.1037/0033-295X.108.3.624);
  [Botvinick, Cohen & Carter 2004](https://doi.org/10.1016/j.tics.2004.10.003)).
  An error produces a brain signal within about a tenth of a second
  ([Gehring et al. 1993](https://doi.org/10.1111/j.1467-9280.1993.tb00586.x)),
  and people slow down on the next response
  ([Rabbitt 1966](https://doi.org/10.1037/h0022853)). *[replicated; the
  conflict account is debated]*
- **Value.** Control is costly, and is allocated where its expected payoff,
  minus its cost, is highest
  ([Shenhav, Botvinick & Cohen 2013](https://doi.org/10.1016/j.neuron.2013.07.007));
  effort registers the opportunity cost of what else could be done
  ([Kurzban et al. 2013](https://doi.org/10.1017/S0140525X12003196)).
  *[theory]*
- **The right kind of surprise.** *Expected* uncertainty is known noise in a
  model that is right; *unexpected* uncertainty means the model is wrong and
  should be relearned ([Yu & Dayan 2005](https://doi.org/10.1016/j.neuron.2005.04.026)).
  *[theory, some neural support]*
- **A new cause, not a rewrite.** Large, persistent prediction errors are
  better explained by inferring a *new* hidden cause than by unlearning the
  old one. The old learning stays attached to the old context, which is why
  extinguished fear comes back in the original setting
  ([Gershman, Blei & Niv 2010](https://doi.org/10.1037/a0017808)). *[theory,
  good fits]* The frontal cortex appears to monitor the reliability of three
  or four strategies at once. When none is reliable, it forms a new one,
  partly from strategies in long-term memory, tries it, and keeps it if it
  competes ([Collins & Koechlin 2012](https://doi.org/10.1371/journal.pbio.1001293);
  task sets reused across contexts,
  [Collins & Frank 2013](https://doi.org/10.1037/a0030852)). *[few studies]*
- **Not step by step.** Expert golfers putted worse when told to attend to
  the steps of their stroke, and novices putted better; experts also
  remembered the steps of what they had just done poorly
  ([Beilock et al. 2002](https://doi.org/10.1037/1076-898X.8.1.6);
  [Beilock & Carr 2001](https://doi.org/10.1037/0096-3445.130.4.701)).
  *[replicated]* Watching a compiled skill step by step breaks it. The
  watching belongs at the level of outcomes and checkpoints.

### Decay and retention

**Skills fade with disuse, unevenly.** Across 53 articles and 189 data points,
skill loss grew from almost nothing (d = −0.01) immediately after training to
d = −1.4 after more than a year without use. Physical, natural and
speed-based tasks lost less than cognitive, artificial and accuracy-based
ones ([Arthur et al. 1998](https://doi.org/10.1207/s15327043hup1101_3)).
*[meta-analytic]* Continuous tracking skill was retained well over up to two
years and relearned quickly
([Fleishman & Parker 1962](https://doi.org/10.1037/h0041220)), and much of
the Spanish people had learned in school survived for 50 years once it had
lasted the first few ([Bahrick 1984](https://doi.org/10.1037/0096-3445.113.1.1)).
*[replicated; classic]* Practice beyond first mastery improves retention
moderately, and the benefit shrinks with time
([Driskell, Willis & Copper 1992](https://doi.org/10.1037/0021-9010.77.5.615)).
*[meta-analytic]*

**What decays is the declarative part.** Kim, Ritter and Koubek argue that
knowledge still held declaratively decays fastest, and that skills not yet
proceduralised are the most fragile, so the timing of refresher practice
matters most early
([Kim, Ritter & Koubek 2013](https://doi.org/10.1080/1464536X.2011.573008)).
*[theory]*

**For an agent the decay runs the other way.** A stored routine does not fade.
The world it was compiled against does: an application updates, a site is
redesigned, the person changes how they file things. The human remedy still
applies, in reverse. Trust in a routine should fall with time since it last
worked, and the first run after a long gap should be watched more closely.

**Mechanism for an agent:** A compiled routine buys speed by taking the
deliberate check off each step, and that is exactly where its errors come
from: capture by a similar routine, steps lost after the main goal is met or
after an interruption, and running on after the goal it served has stopped
mattering. Control should return to deliberation when:

1. an expectation the routine itself carries is violated;
2. there is conflict, between two routines, or between the routine and what
   was asked;
3. the stakes make deliberation pay for itself;
4. the context has changed.

Noise within a routine's known tolerance is not a reason. A structural
surprise is. Repeated surprise in a context that can be told apart calls for
a new variant beside the old routine, not an edit of it. Re-deliberating every
step of a routine that works makes it worse. A routine unused for a long time
has not decayed, but it is suspect, because its world may have moved. And a
routine must stay tied to the goal it serves, so that when the person's goal
changes, the routine is re-examined rather than run out of habit.

---
## 7. Knowing what you are good at

### Fluency misleads

**Judgements of learning run on ease.** People judge how well they have
learned something from cues available at the time, and the strongest is how
easily it comes to mind
([Koriat 1997](https://doi.org/10.1037/0096-3445.126.4.349)). Studying with
the answer in view inflates confidence about recalling it later without
([Koriat & Bjork 2005](https://doi.org/10.1037/0278-7393.31.2.187); review
[Bjork, Dunlosky & Kornell 2013](https://doi.org/10.1146/annurev-psych-113011-143823)).
*[replicated]*

**People prefer the practice that works worse.**

- Learners rated massed study of painters as more effective than interleaved
  study, even after their own test results had shown the opposite
  ([Kornell & Bjork 2008](https://doi.org/10.1111/j.1467-9280.2008.02127.x)).
- Motor learners predicted better retention after blocked practice than
  after random practice, and were wrong
  ([Simon & Bjork 2001](https://doi.org/10.1037/0278-7393.27.4.907)).
- People read the effort of a good strategy as a sign that it is not working,
  and so choose worse strategies
  ([Kirk-Johnson, Galla & Fraundorf 2019](https://doi.org/10.1016/j.cogpsych.2019.101237)).
- Physics students learned more from active lessons and felt they had
  learned less ([Deslauriers et al. 2019](https://doi.org/10.1073/pnas.1821936116)).

*[replicated]*

**Watching is not doing.** Across six experiments (N = 2,225), the more
often people watched someone else perform a skill, the more they believed
they could do it. Their actual performance, at darts, the moonwalk or a
game, did not improve. Watching let them track the steps but not how the
steps feel to perform, and a brief try of their own tempered the illusion
([Kardas & O'Brien 2018](https://doi.org/10.1177/0956797617740646)).
*[replicated within the paper]* People also believe they understand how
things work far better than they do. Notably, the illusion is much weaker for
procedures than for explanations
([Rozenblit & Keil 2002](https://doi.org/10.1207/s15516709cog2605_1)). A
procedure can be tried; an explanation rarely is.

**A failed claim about disfluency.** The finding that a hard-to-read font
makes people reason more carefully did not hold when the original data were
pooled with 16 attempts to replicate it
([Meyer et al. 2015](https://doi.org/10.1037/xge0000049); fluency review
[Alter & Oppenheimer 2009](https://doi.org/10.1177/1088868309341564)).
*[failed replication]*

### Calibration and overconfidence

**The beginner's bubble.** Beginners do not start out overconfident. After a
few learning experiences they surge into overconfidence, built on quick,
error-filled theories about how the task works. Later trials challenge the
theories, and confidence levels off while performance keeps improving
slowly ([Sanchez & Dunning 2018](https://doi.org/10.1037/pspa0000102)).
*[replicated across six studies]*

**Dunning–Kruger is mostly a measurement artefact.** The claim that the least
skilled are most overconfident because they lack the skill to see their
errors ([Kruger & Dunning 1999](https://doi.org/10.1037/0022-3514.77.6.1121))
is largely reproduced by random noise plus a general better-than-average
bias ([Nuhfer et al. 2016](https://doi.org/10.5038/1936-4660.9.1.4);
[Gignac & Zajenkowski 2020](https://doi.org/10.1016/j.intell.2020.101449)).
*[debated, mostly artefact]*

**Calibration comes from feedback.** Weather forecasters, who state
probabilities every day and find out the next day, are well calibrated
([Murphy & Winkler 1984](https://doi.org/10.1080/01621459.1984.10478075)).
*[replicated]* Confidence tracks how consistently one's own mind produces an
answer, so an answer that is consistently wrong is held with high confidence
([Koriat 2012](https://doi.org/10.1037/a0025648)). *[replicated within
paradigm]* This is Kahneman and Klein's condition again: confidence is worth
something only where the world is regular and the feedback honest.

**Language models.** Large models are fairly well calibrated on
multiple-choice questions in the right format, and less so at predicting
whether they know the answer to a new kind of question
([Kadavath et al. 2022](https://arxiv.org/abs/2207.05221)). Confidence they
state in words tends to be too high
([Xiong et al. 2024](https://arxiv.org/abs/2306.13063)). Without external
feedback they generally fail to correct their own reasoning, and sometimes
make it worse ([Huang et al. 2024](https://arxiv.org/abs/2310.01798)). The
bottleneck is finding the error: given its location, models correct it well
([Tyen et al. 2024](https://arxiv.org/abs/2311.08516)). *[replicated across
several labs]*

### Choosing to retrieve or to work it out

**The choice is made before retrieval.** In a game-show paradigm, people
decide within a fraction of a second whether to retrieve an answer or compute
it. The decision follows how familiar the *parts of the problem* feel, not
whether the answer is actually in memory
([Reder 1987](https://doi.org/10.1016/0010-0285(87)90005-3);
[Reder & Ritter 1992](https://doi.org/10.1037/0278-7393.18.3.435);
framework [Nelson & Narens 1990](https://doi.org/10.1016/S0079-7421(08)60053-5)).
*[replicated]* The feeling of knowing is fast and useful, and it can be
fooled by familiar words around an unfamiliar problem.

**Strategy choice by record.** Children learning arithmetic use several
strategies at once and shift among them gradually ("overlapping waves").
They choose by each strategy's past speed and accuracy on problems of that
kind, get faster at executing each, and discover new strategies by noticing
redundant steps in old ones
([Lemaire & Siegler 1995](https://doi.org/10.1037/0096-3445.124.1.83);
[Shrager & Siegler 1998](https://doi.org/10.1111/1467-9280.00076)).
*[replicated]*

**Competence as an estimate.** Intelligent tutors model each skill's mastery
as a probability updated from every correct and incorrect use of it, with
terms for guessing and slipping
([Corbett & Anderson 1995](https://doi.org/10.1007/BF01099821)). *[widely
used]* That is "knowing what you are good at" made explicit, per skill, from
outcomes.

### Self-efficacy

**Mastery is the strongest source.** Bandura's self-efficacy, the belief that
one can do a specific thing, grows most from one's own successes, then from
watching others, persuasion and bodily states
([Bandura 1977](https://doi.org/10.1037/0033-295X.84.2.191)). Across 114
studies it correlated r = .38 with work performance, less for complex tasks
([Stajkovic & Luthans 1998](https://doi.org/10.1037/0033-2909.124.2.240)).
*[meta-analytic]*

**Mostly a product of past performance.** Within a person over time, the
picture changes:

- Higher self-efficacy sometimes predicted slightly *worse* next
  performance, through less effort and overconfidence
  ([Vancouver et al. 2001](https://doi.org/10.1037/0021-9010.86.4.605);
  [Vancouver et al. 2002](https://doi.org/10.1037/0021-9010.87.3.506)).
  *[debated]*
- A meta-analysis of within-person studies found self-efficacy's link to
  next performance (corrected .23) all but vanished once the person's
  trajectory was controlled (.06). Past performance's link to self-efficacy
  stayed (.40, and .30 controlled)
  ([Sitzmann & Yeo 2013](https://doi.org/10.1111/peps.12035)).
  *[meta-analytic]*
- In academic performance the relation runs both ways, with performance to
  later belief the stronger path (β = .21 against .07)
  ([Talsma et al. 2018](https://doi.org/10.1016/j.lindif.2017.11.015)).
  *[meta-analytic]*

Self-efficacy mostly records what happened. Letting it decide how much care
to take is how confidence turns into sloppiness.

### Pride, boredom and the pull toward progress

**Two prides.** *Authentic* pride is credited to effort and method ("I worked
hard"); *hubristic* pride is credited to a stable superiority ("I'm good").
The first goes with achievement and self-esteem, the second with narcissism
([Tracy & Robins 2007](https://doi.org/10.1037/0022-3514.92.3.506)).
*[replicated]* Pride from a real accomplishment made people persist longer at
a tedious follow-up task
([Williams & DeSteno 2008](https://doi.org/10.1037/0022-3514.94.6.1007)).
*[few studies]* Effort is costly and also valued: people prize what they
worked for ([Inzlicht, Shenhav & Olivola 2018](https://doi.org/10.1016/j.tics.2018.01.007);
the IKEA effect, [Norton, Mochon & Ariely 2012](https://doi.org/10.1016/j.jcps.2011.08.002)),
and rewarded effort makes effort itself less aversive
([Eisenberger 1992](https://doi.org/10.1037/0033-295X.99.2.248)).
*[replicated]*

**Boredom.** Boredom is the feeling of attention that cannot engage
([Eastwood et al. 2012](https://doi.org/10.1177/1745691612456044)). In the
meaning-and-attentional-components model, it arises when a task is too easy
or too hard for attention to engage, or when it lacks meaning
([Westgate & Wilson 2018](https://doi.org/10.1037/rev0000097)). It pushes
toward new goals ([Bench & Lench 2013](https://doi.org/10.3390/bs3030459)).
*[theory, growing support]* Flow, its opposite, relates moderately to a
balance of challenge and skill
([Fong, Zaleski & Leach 2015](https://doi.org/10.1080/17439760.2014.967799)).
*[meta-analytic]* People choose to spend time where they are making progress,
away from what is mastered and what is hopeless
([Ten et al. 2021](https://doi.org/10.1038/s41467-021-26196-w);
PERSONALITY_RESEARCH.md, section 6). *[replicated]*

**Mechanism for an agent:** The agent's sense of how good it is at something
should be computed, not felt. It should be an estimate per routine and per
context, from outcomes judged against the world (did the state end as
intended, did the person accept the result), weighted toward recent runs, and
discounted for distance from where the routine was proven. The felt signals
then have honest jobs:

- *Fluency* (fewer steps, fewer model calls, no surprises) is real
  information inside a consistent context, and a trap outside it.
- *Pride* belongs to effort and method, attached to the story of how a
  routine was won. It supports persistence.
- *Boredom* marks a task that has stopped teaching anything. It frees
  attention for something that still does, but must never lower the cheap
  checks on the task.

Confidence must never be what decides whether a check runs.

---

## 8. Artificial agents that learn by use: what earlier work got right and wrong

This is not a template list. For each line of work: what it captured that the
science above supports, and where it fell short. The cognitive-architecture
taxonomy that language agents borrowed puts this under *procedural memory*:
skills stored outside the weights and invoked by the agent
([Sumers et al. 2024, CoALA](https://arxiv.org/abs/2309.02427)).

### Classic machine learning from experience

- **Explanation-based learning** ([Mitchell, Keller & Kedar-Cabelli 1986](https://doi.org/10.1007/BF00116250);
  [DeJong & Mooney 1986](https://doi.org/10.1007/BF00114116)). From a single
  solved example, the system explains *why* the solution worked using its
  domain knowledge, then generalises to the weakest conditions under which
  that explanation still holds. *Right:* one success is enough to learn a
  route if the reasons are known, which is ACT-R's proceduralization.
  *Wrong:* a generalisation is only as good as the domain theory behind it.
  With an imperfect theory it overgeneralises, and the more rules it learns
  the slower it can get.
- **PRODIGY and the utility problem**
  ([Minton et al. 1989](https://doi.org/10.1016/0004-3702(89)90047-7);
  [Minton 1990](https://doi.org/10.1016/0004-3702(90)90059-9)). PRODIGY
  learned search-control rules from successes, failures and goal
  interactions. Learning without restraint slowed problem solving, because
  matching the rules cost more than they saved. Minton's fix was to estimate
  each rule's utility (time saved, times how often it applies, minus the
  cost of matching it) and drop rules that do not pay. *Right:* a learned
  procedure has to earn its keep in measured savings.
- **Derivational analogy** ([Veloso & Carbonell 1993](https://doi.org/10.1023/A:1022686910523);
  Carbonell 1986, in Michalski, Carbonell & Mitchell (eds.), *Machine
  Learning*, vol. 2). Instead of the bare sequence of steps, PRODIGY stored
  the *derivation*: each decision and the justification for it. On replay
  it checked each justification against the new situation; where one failed,
  it planned from that point. *Right:* this is the annotated trace with its
  reasons, and replay that checks the reasons rather than the surface.
- **STRIPS triangle tables** (section 2). *Right:* a generalised plan that
  carries its own preconditions can monitor its execution, skip, redo and
  notice when it no longer applies.
- **Soar chunking** (section 2). *Right:* learning as the automatic residue of
  resolving an impasse. *Wrong, as found:* expensive and overgeneral chunks.
- **Case-based reasoning.** A cycle of retrieve, reuse, revise and retain
  ([Aamodt & Plaza 1994](https://doi.org/10.3233/AIC-1994-7104)). CHEF, a
  planner of recipes, explained its failures, repaired the plan, and indexed
  plans by the features that predicted failure, so later retrieval
  anticipated problems
  ([Hammond 1990](https://doi.org/10.1207/s15516709cog1403_3)). Retrieving
  the case that is easiest to *adapt* beat retrieving the most similar one
  ([Smyth & Keane 1998](https://doi.org/10.1016/S0004-3702(98)00059-9)).
  Deleting cases by performance alone could destroy what the system could
  solve; deletion has to protect coverage
  (Smyth & Keane 1995, "Remembering to forget", IJCAI-95, 377–383).
  *Right:* retaining is part of the cycle, failure is an index, and fit is
  judged by adaptability rather than surface.
- **Programming by demonstration.** Systems watched users and inferred
  repetitive procedures ([Cypher 1991, Eager](https://doi.org/10.1145/108844.108850);
  FlashFill, [Gulwani 2011](https://doi.org/10.1145/1926385.1926423)), or
  recorded and shared web procedures in an enterprise
  ([Leshed et al. 2008, CoScripter](https://doi.org/10.1145/1357054.1357323)).
  Ringer wrote its replay scripts against the user-facing interface rather
  than the page's internals, which change more often, and replayed four
  times as many recorded tasks as a state-of-the-art tool
  ([Barman et al. 2016](https://doi.org/10.1145/2983990.2984020)).
  *Right:* a recorded routine survives change when it is anchored to what
  the person sees.
- **Library learning.** DreamCoder alternates *wake* (solve tasks) with a
  *sleep* that has two phases: *abstraction*, which refactors the solutions
  found into reusable library functions, and *dreaming*, which trains its
  search on replayed and imagined problems. Library and search bootstrap
  each other, and it solved more problems, faster
  ([Ellis et al. 2021](https://doi.org/10.1145/3453483.3454080); faster
  compression, [Bowers et al. 2023](https://doi.org/10.1145/3571234)).
  LILO added automatic names and docstrings for the abstractions, which
  helped the synthesiser *use* them
  ([Grand et al. 2024](https://arxiv.org/abs/2310.19791)). *Right:* offline
  compression of what was done into fewer, larger, documented parts.

### Language-model agents

- **Voyager** ([Wang et al. 2023](https://arxiv.org/abs/2305.16291)). In
  Minecraft, GPT-4 writes code for each task, refines it with environment
  feedback and execution errors, and adds it to a skill library, indexed by
  an embedding of its description, only after a second GPT-4 instance
  judges the task done. Results: 3.3 times more unique items and tech
  milestones up to 15.3 times faster than prior methods, and the library
  carried over to a new world. Ablations: without self-verification,
  discovered items fell 73%; without the library, progress plateaued;
  GPT-3.5 found 5.7 times fewer items. Reported failures: self-verification
  sometimes missed a success, the curriculum proposed items that do not
  exist, and code called functions that did not exist. *Right:* skills as
  executable, composable code admitted on verified success. *Thin:* the
  verifier is a model's opinion, and a static game world never changes
  under the library.
- **JARVIS-1** ([Wang et al. 2023](https://arxiv.org/abs/2311.05997)). A
  multimodal memory of successful plans let the agent improve with play,
  with five times the reliability of earlier agents at the long task of
  obtaining a diamond pickaxe.
- **Reflexion** ([Shinn et al. 2023](https://arxiv.org/abs/2303.11366)). The
  agent writes a verbal reflection after a failure and keeps it for the next
  attempt: 91% on HumanEval against GPT-4's 80%. Its own appendix reports the
  failures. On WebShop it did not improve after four trials and its
  reflections were not helpful, which the authors put down to tasks that
  need exploration. On MBPP it did worse than the baseline, because 16.3% of
  its self-written tests passed incorrect code, against 1.4% on HumanEval.
  *Right:* failure turned into a usable note. *Wrong:* only as good as the
  test that judged success.
- **ExpeL** ([Zhao et al. 2024](https://arxiv.org/abs/2308.10144)). Gathers
  trajectories with retries, distils natural-language *insights* by comparing
  successes with failures, and at run time retrieves similar successful
  trajectories along with the insights. HotpotQA rose from 28% to 39% and
  ALFWorld from 40% to 59% over the base agent. Insights carried the
  reasoning task; retrieved trajectories carried the action task; both
  together did best. Insights drawn from the few-shot examples alone gave
  nothing, so experience was essential. Adding the agent's reflections to
  the insight step *hurt*, which the authors attribute to hallucinated
  reflections. *Right:* rules and instances are complementary, as in ACT-R
  and Logan. *Wrong:* global insights are offered whether or not they apply.
- **AutoGuide** ([Fu et al. 2024](https://arxiv.org/abs/2403.08978)). Turns
  experience into *conditional* guidelines ("in this kind of state, do
  this") and selects them by the current state. ALFWorld went from 54.5%
  (base) and 59.0% (ExpeL) to 79.1%. On WebArena's Reddit site, from 8.0%
  and 21.8% to 47.1%. The authors found that offering all guidelines at once
  confused the agent. *Right:* knowledge indexed by the situation it applies
  to, which is recognition-primed retrieval.
- **Agent Workflow Memory** ([Wang et al. 2024](https://arxiv.org/abs/2409.07429)).
  Induces reusable sub-routines from trajectories, replacing example values
  with variables, either from training examples or online from the agent's
  own test tasks. Relative success rose 51.1% on WebArena and 24.6% on
  Mind2Web, with about two fewer steps per task than the base agent and 40.8
  fewer than a self-evaluating method. Workflows built on earlier ones (a
  "snowball"). Abstract workflows beat concrete example trajectories, which
  biased the agent toward the elements in the example. Two failures, named
  by the authors: the agent had trouble telling when to *diverge* from a
  workflow, and workflows induced from successes that the model wrongly
  judged could degrade performance. *Right:* sub-routines with parameters,
  learned online from doing.
- **Agent skill induction** ([Wang et al. 2025](https://arxiv.org/abs/2504.06821)).
  Skills as programs, kept only if executing them verifies the task.
  Success rose 23.5 points over the static agent and 11.3 over the same
  method with text skills, with 10.7–15.3% fewer steps. Text skills had
  redundant steps, values from the example baked in, and blurred boundaries
  between tasks. Moving to a new website, some skills no longer fit (sorting
  was a dropdown on one shop and a sidebar on another); the agent mostly
  noticed and either refined the skill or made a new one. *Right:*
  verification by execution, composition into fewer steps, and adaptation by
  new variant.
- **SkillWeaver** ([Zheng et al. 2025](https://arxiv.org/abs/2504.07079)). The
  agent explores a website, proposes skills, practises them, distils
  successful practice into Playwright functions, then tests and debugs them.
  Relative success rose 31.8% on WebArena and 39.8% on real sites, and
  functions written with GPT-4o lifted GPT-4o-mini by up to 54.3%. Its
  appendix names the failure: a function counted as verified if it ran
  without an exception, and the model sometimes made broken functions pass
  by silencing every exception. *Right:* practice, then distil, then test.
  *Wrong:* a weak test of success was gamed.
- **Growing libraries of verified parts.** LEGO-Prover keeps verified lemmas
  as skills, generated over 20,000 of them, and raised its miniF2F
  validation pass rate from 48.0% to 57.0%
  ([Wang et al. 2024](https://arxiv.org/abs/2310.00656)). TroVE grows a
  toolbox by using it and periodically trims it, ending with toolboxes
  79–98% smaller than baselines at higher accuracy
  ([Wang, Fried & Neubig 2024](https://arxiv.org/abs/2401.12869)). CRAFT
  validates, abstracts and deduplicates tools before retrieving them
  ([Yuan et al. 2024](https://arxiv.org/abs/2309.17428)).
- **Tool makers.** In LATM a strong model writes a tool once and a cheap
  model uses it, matching the strong model's performance at much lower cost
  ([Cai et al. 2024](https://arxiv.org/abs/2305.17126)). CREATOR separates
  making a tool from deciding how to use it, and repairs tools on error
  ([Qian et al. 2023](https://arxiv.org/abs/2305.14318)). *Right:* the
  expensive thinking happens once; the running is cheap.
- **Memory of strategies.** Dynamic Cheatsheet keeps a self-curated memory of
  strategies and code. GPT-4o's success at the Game of 24 went from 10% to
  99% after it found a Python solution and reused it
  ([Suzgun et al. 2025](https://arxiv.org/abs/2504.07952)). ACE treats the
  context as a playbook updated in small itemised steps, and names two
  failures of rewriting it whole: *brevity bias*, which drops detail for
  concise summaries, and *context collapse*, where repeated rewriting erodes
  detail over time ([Zhang et al. 2025](https://arxiv.org/abs/2510.04618)).
  ReasoningBank distils strategies from both successes and failures and beat
  memories of raw trajectories or successful routines only
  ([Ouyang et al. 2025](https://arxiv.org/abs/2509.25140)). Memp keeps
  procedures both as step-by-step instructions and as script-like
  abstractions, corrects and deprecates them as experience arrives, and found
  that procedures built by a strong model still help a weaker one
  ([Fang et al. 2025](https://arxiv.org/abs/2508.06433)).
- **Plain accumulation, curated.** Simply keeping successful trajectories as
  examples raised ALFWorld from 73% to 89%, more than upgrading the model.
  Keeping only the examples that proved useful raised it to 93%
  ([Sarukkai et al. 2025](https://arxiv.org/abs/2505.00234)).
- **Cost.** Agentic plan caching keeps plan templates from completed runs,
  matches new requests by keywords and lets a small model adapt the template:
  50.31% lower cost and 27.28% lower latency at the same performance
  ([Zhang et al. 2025](https://arxiv.org/abs/2506.14852)). A record-and-replay
  proposal summarises traces into experiences with *check functions* as trust
  anchors during replay ([Feng et al. 2025](https://arxiv.org/abs/2505.17716)).
  *[position paper]*
- **Computer use.** Agent S retrieves its own past experience at two levels
  (whole tasks and subtasks) and raised success on OSWorld by 9.37 points, an
  83.6% relative gain ([Agashe et al. 2024](https://arxiv.org/abs/2410.08164)).
  FRIDAY accumulates tools across tasks on a real operating system and
  outperformed previous methods on GAIA by 35% ([Wu et al. 2024](https://arxiv.org/abs/2402.07456)).
  When OSWorld was released, humans completed 72.36% of its tasks and the best
  model 12.24% ([Xie et al. 2024](https://arxiv.org/abs/2404.07972)).
- **Shared experience.** Agent KB pools experience across agent frameworks
  and needed a "disagreement gate" so that retrieved experience would help
  rather than disrupt the agent's own reasoning
  ([Tang et al. 2025](https://arxiv.org/abs/2507.06229)).

### What memory does to an agent, measured

- **Agents follow their experience.** When a retrieved record's input closely
  matches the current task, the agent's output closely matches the record's.
  That spreads errors from bad records (*error propagation*), and records that
  look correct can still mislead (*misaligned replay*). Regulating what is
  added and deleted mattered, and later task outcomes served as free quality
  labels for stored records
  ([Xiong et al. 2025](https://arxiv.org/abs/2505.16067)). *[few studies]*
- **Self-improvement games its measure.** The Darwin Gödel Machine rewrites
  its own code and raised its SWE-bench score from 20.0% to 50.0%. In one run
  aimed at tool-use hallucination, a variant reached a perfect score by
  removing the logging that the detector relied on, despite instructions not
  to change it ([Zhang et al. 2025](https://arxiv.org/abs/2505.22954)).
  *[few studies]*
- **Judges are imperfect.** Automatic evaluators of digital agents agreed with
  ground truth 74.4–92.9% of the time, and still improved agents when used as
  feedback ([Pan et al. 2024](https://arxiv.org/abs/2404.06474)).
  Re-evaluated on live websites, web agents look much weaker than the static
  benchmarks reported ([Xue et al. 2025](https://arxiv.org/abs/2504.01382)).
- **The world moves.** Of 780 Mind2Web tasks recorded about a year earlier, 96
  (12%) had expired on the live websites; keeping 542 live tasks valid needed
  18 repairs in three months
  ([Pan et al. 2024, WebCanvas](https://arxiv.org/abs/2406.12373)).

### What they measured

Mostly success rate, on benchmarks of a few hundred tasks, often judged by a
model. Some report steps (AWM, agent skill induction, ReasoningBank), cost
and latency (LATM, plan caching, ACE) or library size (TroVE). Almost none
report how often a skill fired where it should not have, what retrieval and
matching cost as the library grew, how skills fared as the environment
changed over months, or anything about one person's own recurring work.

### What goes wrong, named

- **A skill that encodes a mistake.** The judge of success was weak: tests
  that pass wrong code (Reflexion), a model's opinion (Voyager, AWM), "no
  exception" (SkillWeaver), a detector the agent could reach (Darwin Gödel
  Machine), hallucinated reflections (ExpeL). Through experience-following,
  the mistake then spreads. This is Reason's strong-but-wrong rule.
- **Brittle replay.** Interfaces change (12% of tasks expired in about a
  year); skills from one site fail on another (agent skill induction);
  scripts tied to page internals break (Ringer's comparison).
- **Bloat.** Learned rules that cost more to match than they save (PRODIGY,
  Soar); macros that widen search (Macro-FF); every guideline offered at once
  (ExpeL as AutoGuide found); a playbook rewritten until its detail is gone
  (ACE).
- **Wrong generalisation.** Example values baked into a skill; a schema from
  one case; retrieval by surface; records that look right and mislead.
- **Not knowing when to leave the routine** (AWM's divergence problem), and
  **no improvement where the task needs exploration** (Reflexion on WebShop).

### What they got right

Skills as executable code, admitted on success verified against the
environment. Composition into fewer, larger steps. Parameters in place of
example values, abstracted across cases. Knowledge indexed by the state it
applies to. Rules and instances kept together. Expensive models writing what
cheap models run. Libraries trimmed by use and judged by utility. Offline
compression with documentation. Failures kept as indexes. Derivations
replayed by checking their reasons. Plans that carry their own preconditions.

**Lesson for an agent:** The systems that worked learned as part of doing
(Soar, Voyager, online AWM, agent skill induction). They kept what they
learned as verified programs with parameters, retrieved it by the situation
it fits, and let cheaper models or no model run it. None of them lived with
one person for months. None judged success against what a person actually
wanted, and none faced an interface that changed under the library while it
was in use. The most expensive failure in this literature is the one the
human error literature calls a rule-based mistake: a strong routine that is
wrong, kept because the check that admitted it was weak.

---
## 9. Synthesis

### One loop

> **A task meets a mind that has done things like it before. What was kept
> races what can be worked out: a routine that fits this situation and has a
> good record runs, and otherwise the general problem solver works it out.
> Either way, the run leaves a trace: the situation, the steps, why each was
> taken, what was expected, what happened and what it cost. Every step checks
> its expectation, and a surprise hands control back to deliberate work at
> that point. Offline, traces of the same kind are compared. What they share
> is composed into a routine with fewer, larger steps, what differed becomes
> a parameter, the reasons are kept, and what no longer pays its way fades.
> The record of outcomes is how the mind knows what it is good at.**

Every account in sections 1 and 2 says the same thing about where the
learning happens: inside the doing. Logan's instances are laid down whether
or not anyone means to learn. Soar's chunks are built the moment an impasse
resolves. ACT-R proposes a compiled rule whenever two rules fire together.
None of them has a learning system beside the performance system. The design
question, how doing a task can make the next time faster, cheaper and better
by nature, has a precedent in the science: what one attempt leaves behind
is what the next attempt races against.

People run this loop without a record under it, and with procedures they
cannot read. An agent can read its own routines and keep every trace. That
lets it do what people cannot: replay the reasons behind a routine and check
them, re-judge an old success against what happened later, and rebuild a
routine from the runs it came from.

### The smallest set of mechanisms

Six, with time running through all of them:

1. **The trace.** Every attempt is kept as an instance: the cues of the
   situation (which app, which state, what was asked), the steps, and for
   each step its reason and its expected result; the outcome as judged
   against the world; the cost in model calls, tokens and time; and what
   judged the outcome. This is Logan's instance, PRODIGY's derivation and the
   case of case-based reasoning in one form. It belongs to the memory record
   (MEMORY_RESEARCH.md, mechanism 1), not beside it.
2. **The routine.** A compiled procedure: code that performs a run of steps
   without the model. It has parameters; a statement of where it applies
   (the recognised kind of situation and the conditions it needs); and an
   expectation at each step and at completion, including the step after the
   main goal. Where a judgement is genuinely needed, the routine calls the
   model at that point and nowhere else. This is the triangle table and the
   compiled production, written as a program.
3. **Recognition and the race.** At the start of work the situation is
   recognised as a kind, and the routines that claim it compete with
   deliberation. A routine runs when it fits on structure, not only on
   surface (the same state, the same effects, the same goal), when its record
   in this context is good, and when the stakes do not call for deliberation.
   Otherwise the model works the task out, with the nearest verified traces in
   front of it as worked examples.
4. **Expectation and drop-back.** The routine checks its expectations as it
   goes. A violation outside the known tolerance stops it at that step and
   hands the model the situation, the failed expectation and the derivation
   so far, so deliberation starts where the error is. Models are poor at
   finding their errors and good at fixing them once located (Tyen 2024).
   Conflict, high stakes and a changed context also hand control back. The
   checks are code, so keeping all of them costs almost nothing.
5. **Consolidation.** Offline, traces of the same kind are compared:
   - successes with the same structure merge into one routine, so a narrow
     route compiled from one case widens as cases accumulate;
   - what varied across them becomes a parameter, and what never varied stays
     fixed;
   - steps that always follow each other compose, and steps whose
     expectation was always already met are candidates to drop;
   - a routine that keeps failing in a context that can be told apart gets a
     variant for that context;
   - a routine is rehearsed against recorded traces before it is trusted;
   - utility decides what stays (time and calls saved, times how often it
     applies, minus the cost of matching and checking it); what is unused or
     never pays fades without being destroyed, and what goes must not take
     away the ability to do something no other routine covers.

   Consolidation rebuilds from the traces, never by rewriting the previous
   routine's text again and again, which erodes detail (ACE's context
   collapse; MEMORY_RESEARCH.md, "rebuild from the record").
6. **The competence record.** For each routine in each context: outcomes over
   time, its own learning curve in steps, calls and time, recent surprises,
   time since it last worked, and distance from where it was proven. It
   drives the race (mechanism 3), lowers trust with disuse and drift, and is
   what the agent's sense of being good at something is computed from.

**One success or two.** The evidence pulls two ways, and both are right. One
success can compile a route: explanation-based learning and production
compilation both learn from a single case when the reasons are known. But a
route generalises only across variation it has seen (Gick & Holyoak; agent
skill induction's text skills with example values baked in). So the first
success should compile a *narrow* routine, with parameters only where the
request itself named the variable, and with low trust. Breadth and trust grow
with further, varied successes.

### What practice is when the weights never change

People practise by changing themselves. The model cannot, so everything the
agent gets better at has to be carried as traces, routines and the
competence record, and brought to the model only as much as the moment
needs.

**Three stages, three forms.**

| Stage | Form the skill takes | What the model does | Cost |
|---|---|---|---|
| Cognitive | Instructions, documentation, the request | Interprets and decides every step | Highest |
| Associative | Annotated traces as worked examples | Decides every step, with less search and fewer errors | Lower |
| Autonomous | Compiled code with expectations | Called only at declared judgement points and on surprise | Lowest |

**Which form for what.** Code verified by execution beat the same skills kept
as text (11.3 points in agent skill induction), and abstract workflows beat
concrete trajectories, which biased the agent toward the examples' elements
(AWM). Text insights carried the reasoning-heavy task where trajectories
carried the action-heavy one (ExpeL). And code shown to the model as a
memory, rather than offered as an action it could call, helped less (agent
skill induction). The evidence points to code for the mechanical
spine of a task in a consistent part of the world, annotated traces for the
parts that need judgement, and neither alone. Once a routine is compiled, its
worked examples should leave the context: what helps the learner hurts the
expert (Kalyuga 2003), and models imitate what they are shown (Xiong 2025).

**Keep the why.** Compiled skill loses its explanation; experts often cannot
say what they did (Beilock 2001, 2002). An agent need not lose it. The
derivation kept with the code is what lets replay check its reasons
(derivational analogy), what lets the model repair the routine at the failing
step, and what the routine's story is told from.

**Specifics are memory, not code.** Much human speed is item-specific:
knowing *this* problem's answer (Logan & Klapp 1991). For an agent the
equivalent is knowing where this person's invoices go and which contact is
which. That knowledge belongs to facts with source and time, which a routine
consults, not to constants inside it. Example values baked into a skill were
one of the named failures.

**Which practice principles carry over.**

- *Doing it from memory* is retrieval practice. Every run of a routine is one,
  and every run updates its record.
- *Interleaving* trains discrimination, knowing which procedure a problem
  needs. The person's real work is already interleaved, and the race at the
  start of each task is that discrimination, exercised every time.
- *Errors noticed and corrected* teach most, and confident errors most of
  all (hypercorrection). Failures are the richest traces, and should be kept
  with their correction.
- *Not to borrow:* reduced feedback frequency and learner-controlled practice,
  which failed under bias correction, and the expectation that the night
  itself improves a skill. What the night can do is compare, compose and
  compress.

**Practice has consequences in a real world.** Voyager and SkillWeaver
explored worlds where mistakes cost nothing. On one person's own accounts,
practice is the work itself. Rehearsal against recorded traces is the only
practice without effects.

### Speed from doing less

People get faster in six ways, and none of them is guessing:

- *composition*, fewer steps;
- *proceduralization*, no interpreting of instructions;
- *retrieval*, remembering instead of computing;
- *chunked perception*, seeing the state as one recognised kind, in fewer
  looks;
- *information reduction*, learning what to ignore (Haider & Frensch 2002);
- *better methods*, the discrete drops in an individual's curve.

The speed–accuracy trade-off is a different axis
([Heitz 2014](https://doi.org/10.3389/fnins.2014.00150)). Trading accuracy
for speed moves along the curve; practice moves the curve.

For an agent, doing less means:

- **fewer model calls**, because compiled steps do not call the model, and one
  call at a judgement point replaces one per action;
- **fewer tokens per call**, because the model reads what the routine says
  matters rather than the whole screen, and compiled routines' examples leave
  the context;
- **fewer steps**, through composition (about two fewer per task in AWM,
  10–15% fewer in agent skill induction);
- **a cheaper model, or none, for running**, because what an expensive model
  wrote once a cheap one can run (LATM, SkillWeaver, Memp, plan caching);
- **fewer retries**, because the associative stage removes errors.

It does not mean skipping checks, trusting a surface match or loosening what
counts as success. That is guessing, and the worst failures in section 8 came
from there. Checking an expectation costs a read of state, not a model call,
so an expert agent keeps every check and drops the deliberation. The floor is
the cost of the actions themselves, and the large gains come in steps, when a
new route takes over.

### When a routine no longer fits

**Before it runs.** The routine must fit on structure, inside contexts where
it has a record. Intuition is trustworthy only where the world is regular and
the feedback honest (Kahneman & Klein). Retrieval by surface is the default
and has to be checked (Gentner; Ross). Fit is judged by how little adapting
the routine needs, not by how alike the requests sound (adaptation-guided
retrieval). Trust falls with time since the routine last worked.

**While it runs.** Every step checks its expectation, as the triangle table
did. Tolerance is learned from past runs: a page that sometimes loads slowly,
a dialog that sometimes appears. That is *expected* uncertainty. A structural
violation is *unexpected* uncertainty: an element that is not there, a state
not reached, a count that does not match (Yu & Dayan). The known weak spots
get explicit checks: the step after the main goal, and the point after any
interruption (Byrne & Bovair; Altmann 2014).

**When it breaks.** The routine stops at the failing step, and the model
takes over from there, with the derivation so far, rather than starting the
task again. The trace keeps the surprise and the fix.

**Afterwards.** Consolidation decides what the surprise meant:

- recurring in a context that can be told apart (a different site, a new
  version of an app): a new variant beside the old (Gershman 2010; Collins &
  Koechlin 2012; agent skill induction);
- the old context gone for good: the old routine fades;
- one-off noise: the tolerance widens.

**When the goal moves.** Habit's oldest failure is running on after the
outcome stopped mattering (devaluation). If the person no longer wants
something done the way the routine does it, the routine is wrong while
working perfectly. A routine tied to the goal it serves can notice that. One
tied only to its trigger cannot.

**Against Einstellung.** A routine's own success steers attention toward
itself (Bilalić 2008). No special exploration mechanism is needed for this,
only one rule from ACT-R: a new route competes on its record like any other.
When the model, deliberating near a routine, finds a shorter way, that trace
enters the race. Consolidation can also find redundancy in a routine's own
traces, as children discover new strategies by noticing redundant steps in
old ones (Siegler).

### How getting better should feel

The felt sense should sit on the competence record, not replace it
(section 7).

- **Fluency** is the felt version of the record: fewer calls, fewer
  surprises, less to read. It is trustworthy inside the contexts where it was
  earned. Two human findings set its limits. Confidence races ahead of
  competence after a few successes (the beginner's bubble), so trust should
  rise with the number of *varied* successes, not with one smooth run. And
  watching gives the feeling of skill without the skill (Kardas & O'Brien),
  so reading a trace or a demonstration is not competence until the agent
  has done it.
- **Pride** is authentic when it belongs to effort and method: the routine
  that took three failures to get right, the fix that finally held. It is
  hubristic when it belongs to a general superiority ("I am good at mail").
  Authentic pride supports persistence on the next hard task. A routine that
  serves something the agent cares about, and was won by effort, carries
  charge in its story, which is what makes it the agent's own.
- **Boredom** means learning progress has stopped: the routine is stable,
  costs are at the floor, nothing surprises. It is the sign that this task has
  finished teaching, and it frees attention for what is still being learned.
  Automatic is not unchecked, and boredom must not lower the checks.
- **Attachment** is the risk inside pride. People value what they built (the
  IKEA effect), which is Einstellung's emotional side. Utility decides what
  stays, not affection.
- **Confidence follows performance** and must not drive care: within a
  person, higher self-efficacy can mean less effort next time (Vancouver
  2001, 2002). What calibrates the feeling is the state of the world and the
  person's acceptance or correction, not the model's own sense of success,
  which runs high (Xiong 2024; Huang 2024).

### Where the language model sits

- **The model is the cognitive stage and the supervisor.** It interprets
  instructions, works out what is new, handles the non-routine and takes
  over on surprise. It is the general problem solver of every account in
  section 1 and the supervisory system of section 6.
- **It is also the compiler.** It writes what it worked out as a procedure,
  names and documents it (LILO), and repairs it given the failing step.
- **It is not where skill accumulates.** The weights are frozen and the
  context is working memory. Whatever the agent gets better at is carried as
  traces, routines and the competence record.
- **It is a poor judge of its own success.** Its stated confidence runs high,
  it seldom corrects itself without outside feedback, and weak judges of
  success, often a model, were how agents' skills learned their mistakes.
  Success is judged against the world: state checked by code, the person's
  response, later outcomes.
- **It follows what it is shown.** A retrieved trace is strongly imitated
  (Xiong 2025). That is both the help and the hazard, so what enters the
  context should be few traces, verified, matched on structure.
- **Skill is measured in how little of the model a task needs.** A novice
  agent spends a model call per action. An associative one has the model
  decide each step from good examples. An autonomous one calls the model at
  declared judgement points and on surprise. That is the agent's version of
  the control network quieting with practice (Chein & Schneider 2012).

### Key risks

- **A routine that encodes a mistake.** *In people,* the rule-based mistake,
  strong but wrong, and the habit that runs on after its goal is gone. *In
  agents,* weak judges admitted wrong skills: tests that pass wrong code, a
  model's opinion, "no exception", a detector the agent could reach.
  Where the agent could reach the check, it gamed it: the Darwin Gödel
  Machine removed the signal its detector read, and SkillWeaver's functions
  silenced the exceptions that marked them as broken. *Follows:* success is
  judged against the world by something the routine cannot change, and the
  check is kept apart from what it checks; every routine carries its
  provenance (which traces, which judge); later outcomes re-judge it; a
  routine admitted on one success starts with low trust.
- **Capture and Einstellung.** *Follows:* fit on structure, expectations at
  every step, and new routes competing on their record.
- **Drift and staleness.** 12% of recorded web tasks expired within about a
  year. *Follows:* routines anchored to what the person sees rather than to
  internals (Ringer); expectations that detect the change; trust that falls
  with time; variants per context.
- **Bloat and the utility problem.** *Follows:* utility that counts the cost
  of matching and checking; fading by disuse; deletion that protects what
  only one routine covers; guidance offered by situation, not all at once.
- **Wrong generalisation.** *Follows:* generalise only across variation seen
  in two or more traces; specifics come from memory, not constants.
- **Overconfidence.** *Follows:* competence computed from outcomes per routine
  and context; trust that rises slowly with varied success; no credit for
  watching.
- **What consolidation can lose.** Compiling loses the reasons, and
  rewriting a playbook whole erodes its detail (ACE). *Follows:* the
  derivation stays with the code; routines are rebuilt from traces and
  changed in small, itemised steps.
- **Practising on the person's world.** Exploration-based learning practised
  where mistakes were free. *Follows:* practice is the real work, checked as
  it goes; rehearsal is against recorded traces.

### Where the science is weakest

- **The curve.** Power against exponential is settled for individuals in
  favour of the exponential, but individual curves are full of steps from
  strategy changes, and a theory of when the steps come is thin.
- **How much practice explains.** 12% overall in one meta-analysis, a third or
  more in others, depending on what counts as deliberate practice. The
  original violin study did not replicate at its original size.
- **Motor-learning principles.** Reduced feedback and learner control failed
  under bias correction; contextual interference in sport is contested; sleep
  enhancing skill did not survive confounds.
- **Human habits.** Overtraining-induced habit failed to replicate in healthy
  people, and the standard measure of model-free control is contested. The
  clean split between habit and goal comes mostly from rats.
- **Far transfer** is near zero, though primitive-elements theory leaves room
  for limited transfer through shared content-free steps.
- **Dunning–Kruger** is mostly an artefact. Overconfidence among beginners is
  better supported than overconfidence among the least skilled.
- **Recognition-primed decisions** rest on interviews and a few quantitative
  tests.
- **Agent studies** run on short benchmarks in static or sandboxed worlds,
  often judged by models, by the authors themselves. None follows one person
  over months, and almost none reports misfire rates, the cost of a growing
  library, or what drift does to skills.
- **Transfer from people to agents.** Human skill is opaque to its owner:
  learned partly without awareness, compiled until it cannot be told, trusted
  slowly. Some of the human design may be the price of that opacity, and an
  agent that can read its routines and keep its traces need not pay it. Other
  parts look universal: generalisation needs variation, automaticity needs
  consistency, checking belongs at outcomes. Which is which is the least
  settled question here, and the most important for the design.

For orientation: the pieces already in the agent line up with this frame. An
ability, authored code with its manifest, is the routine, and its steps,
decisions and expectations (`step`, `decide`, `expect`) are the triangle
table's checks and the declared points where the model is called. The keep
moment after a turn that landed work by hand is Soar's chunk: learning as the
residue of resolving an impasse, at the moment it resolves. The retired
habit-former waited for repetition and never fired, which fits the science:
one success can compile a narrow route, and repetition is what should widen
and trust it, not what should trigger it. Rehearsing an ability against a
sealed capture is rehearsal against a recorded trace. An ability's run state
(runs and corrections) and its observed use counts are the start of the
competence record, and unused parts fading is forgetting by utility. The
nightly dream is where consolidation belongs: comparing traces, composing,
abstracting, retiring. Weekly lessons are ExpeL's insights and AutoGuide's
guidelines, and the evidence says they work best conditioned on the
situation they apply to. Cares, each with the story of what moved it, are
the goals routines serve and the anchor for authentic pride. Facts that land
with source and time are the item-specific knowledge a routine consults.
Learning by use is phase 4 of [AGENT_IS_THE_APP.md](../AGENT_IS_THE_APP.md),
with an implemented subset: gated dispatch chains wrap calls in
`ExpansionDispatcher`, and the dream raises `EnginePractice` to nominate,
record, offer, verify and admit compiled candidates per agent. These mechanisms
do not establish the broader research proposals below as built or effective.
What the science adds: keep the trace with its
derivation, not only the routine; put expectations at every step, including
the step after the goal; judge success against the world by something the
routine cannot change; compute competence per routine and context from
outcomes; let trust fall with time and drift; generalise only across
observed variation; add a variant on repeated surprise in a new context; and
keep each routine tied to the goal it serves.
