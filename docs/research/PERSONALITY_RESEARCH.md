# How a person becomes someone

Research on personality, emotion and conversational initiative, written for
Claude on 2026-10-24 as raw material for the agent design. It covers how these
things form and work in people, drawn from primary and review literature. Each
area ends with the mechanism an agent would need. It does not propose features.

How sure each finding is: I say when a finding is meta-analytic or widely
replicated, when it is debated, and when it rests on a few studies or on
theory. Where a famous finding failed to replicate, I say so.

---

## The answer first

- **Personality is not installed. It is what repeated experience leaves
  behind.** Traits change when the same kinds of situation keep producing the
  same states and reactions, and reflection and habit slowly turn that pattern
  into "who I am" (the TESSERA framework). One event rarely changes anyone.
  Sustained roles and relationships do.
- **Emotion is caring, evaluated.** Every emotion is an appraisal of what
  happened against what the person cares about. No concerns, no emotions. Mood
  is the slower, decaying total of recent surprises, and temperament is the set
  point underneath both.
- **The self is a story told to someone.** Memory keeps what was emotionally
  charged and relevant to goals. Sleep consolidates it into gist and
  self-knowledge, and every retelling rewrites it. The listener shapes the
  story.
- **People are different selves with different people.** Each relationship
  grows its own self out of shared history: a private common ground, trust that
  comes from predictability, and closeness that comes from responsive
  disclosure and from mismatches that got repaired.
- **Initiative comes from having an inside.** People lead conversations with
  what is on their minds: unfinished concerns, open questions, interests that
  are becoming their own, and things that moved them since they last talked.
  They fit it to the listener and bring it in where the talk leaves room.
- **For an agent, the language model is closer to temperament plus a library
  of concepts than to a personality.** Interpretability work shows the model's
  emotion representations are momentary. Anything that lasts over time has to
  be carried by the agent.

---

## 1. How personality forms and changes over a lifetime

### Temperament is the raw material, not the person

Temperament means differences in reactivity and self-regulation that show up
early and have a biological basis. Reactivity is how fast and how strongly a
child responds, with negative affect or with eager approach. Self-regulation,
or "effortful control", is the capacity to hold back and to aim attention
([Rothbart 2007](https://doi.org/10.1111/j.1467-8721.2007.00505.x)). The
dimensions map loosely onto adult traits. Surgency becomes extraversion,
negative affectivity becomes neuroticism, and effortful control becomes
conscientiousness. The mapping is loose because traits are *elaborated* from
temperament by experience. Shiner and Caspi name the elaboration processes:

- learning (behaviours get reinforced);
- environmental elicitation (a child's temperament draws particular responses
  from others);
- environmental construal (situations get read through the child's own
  tendencies);
- social and temporal comparison (learning who one is by comparing);
- environmental selection;
- environmental manipulation.

([Shiner & Caspi 2003](https://doi.org/10.1111/1469-7610.00101)). Every one of
these is a loop between disposition and experience.

Behaviour genetics puts a number on how much is left to experience. About 40%
of the variance in adult traits is heritable
([Vukasović & Bratko 2015](https://doi.org/10.1037/bul0000017), meta-analysis).
Most of the environmental share is *non-shared*: experiences that differ even
between siblings raised in the same house
([Plomin & Daniels 1987](https://doi.org/10.1017/S0140525X00055941)). Identical
twins raised together still become different people because each lives a
different life. This bears directly on User's requirement that the mechanism be
right for every agent. Agents that share one model share a genome.
Individuality has to come from their non-shared experience.

### Traits change slowly, and in a known direction

**Rank-order stability.** How people rank against each other on a trait gets
more stable through childhood and adolescence and levels off in young
adulthood, at test-retest correlations of roughly .6 over several years. The
largest meta-analysis (189 longitudinal samples) found little further rise
after about age 25 ([Bleidorn et al. 2022](https://doi.org/10.1037/bul0000365)).
That revises the earlier synthesis, which had stability climbing into the 50s
([Roberts & DelVecchio 2000](https://doi.org/10.1037/0033-2909.126.1.3)).

**Mean-level change.** On average people become more conscientious, more
agreeable and more emotionally stable as they age. Most of the change comes
between 20 and 40, and it continues into old age. Openness rises in
adolescence and falls in old age
([Roberts, Walton & Viechtbauer 2006](https://doi.org/10.1037/0033-2909.132.1.1)).
This is the "maturity principle", and it is robust.

Both facts hold together: people are recognisably themselves across decades,
and nobody is fixed.

**What moves traits on purpose.**

- *Therapy.* Clinical interventions shift traits, mainly emotional stability,
  by about a third of a standard deviation in roughly 24 weeks, and the change
  lasts ([Roberts et al. 2017](https://doi.org/10.1037/bul0000088)).
- *Wanting to change.* People who want to change a trait and make concrete
  behavioural plans do change, modestly, in the direction they wanted
  ([Hudson & Fraley 2015](https://doi.org/10.1037/pspp0000021)).
- *Life events.* They change traits less, and less predictably, than people
  assume ([Bleidorn, Hopwood & Lucas 2018](https://doi.org/10.1111/jopy.12286)).
  After major events, wellbeing partly returns to a set point. The return is
  incomplete for some events, such as unemployment and disability
  ([Lucas 2007](https://doi.org/10.1111/j.1467-8721.2007.00479.x)).

### What actually changes a trait: states, repeated, reflected on

**Traits are distributions of states.** Experience sampling shows that one
person's behaviour varies from moment to moment about as much as people differ
from each other. Yet the centre and spread of each person's distribution stay
very stable from week to week
([Fleeson 2001](https://doi.org/10.1037/0022-3514.80.6.1011)). Whole Trait
Theory keeps two meanings of "trait" apart. The descriptive trait is that
distribution. The explanatory trait is the social-cognitive machinery that
turns situations into states
([Fleeson & Jayawickreme 2015](https://doi.org/10.1016/j.jrp.2014.10.009)).

**Consistency lives in if-then signatures.** Mischel and Shoda's
Cognitive-Affective Personality System finds consistency in stable patterns
such as "if teased, then angry; if praised, then shy", not in behaving the
same way everywhere ([Mischel & Shoda 1995](https://doi.org/10.1037/0033-295X.102.2.246)).
Personality is the *shape* of a person's variation.

**TESSERA is the clearest account of how momentary experience becomes lasting
personality** ([Wrzus & Roberts 2017](https://doi.org/10.1177/1088868316652279)).
It runs in four steps:

1. A triggering situation comes up.
2. It raises an expectancy.
3. That produces a state, and how the state is expressed.
4. A reaction follows, from oneself and from others.

When the sequence repeats, two processes work on it. Associative learning
turns it into habit, below awareness. Reflective processes notice it,
interpret it and narrate it. Together they shift the trait. The prediction was
tested: repeated daily states and reactions predicted change in most of the
Big Five over a year
([Quintus, Egloff & Wrzus 2021](https://doi.org/10.1037/pspp0000361)).

**What a trait is, mechanically.** Cybernetic Big Five Theory treats traits as
settings of one goal-pursuit cycle: activate a goal, select an action,
interpret the outcome, compare it with the goal
([DeYoung 2015](https://doi.org/10.1016/j.jrp.2014.07.004)).

- The "Stability" traits keep goals from being disrupted. These are low
  neuroticism, agreeableness and conscientiousness.
- The "Plasticity" traits drive exploration of new goals and strategies.
  These are extraversion and openness.
- "Characteristic adaptations" are the learned contents of the cycle: goals,
  interpretations and strategies.

On this view a trait is how a loop is tuned, not an adjective describing a
person.

### Roles and relationships do the shaping: social investment

The neo-socioanalytic, or social investment, account holds that adult
personality develops through committing to social roles: work, partner, parent,
community. Those roles expect and reward being reliable, warm and steady
([Roberts, Wood & Smith 2005](https://doi.org/10.1016/j.jrp.2004.08.002);
meta-analysis [Lodi-Smith & Roberts 2007](https://doi.org/10.1177/1088868306294590)).
Across 62 nations, cultures where people take on adult roles earlier show
earlier personality maturation
([Bleidorn et al. 2013](https://doi.org/10.1177/0956797613498396)). A role a
person commits to fixes two things: which situations keep recurring, and whose
reactions reward which states. In TESSERA terms it is a standing source of
triggers and reactions. Close relationships are the strongest such
environment.

### Personality chooses its own experiences

**People shape their environments three ways**
([Scarr & McCartney 1983](https://doi.org/10.2307/1129703)):

- passively (they are born into a setting that fits them);
- evocatively (others respond to their disposition);
- actively (they pick niches). The active route grows with age.

**The corresponsive principle.** The experiences a trait leads someone into
tend to deepen that same trait
([Roberts, Caspi & Moffitt 2003](https://doi.org/10.1037/0022-3514.84.3.582)).
Over time this produces cumulative continuity
([Caspi, Roberts & Shiner 2005](https://doi.org/10.1146/annurev.psych.55.090902.141913)).

**Self-verification.** People seek, and draw out, feedback that confirms how
they already see themselves. In committed relationships they come to prefer
partners who see them as they see themselves over partners who only flatter
them ([Swann, De La Ronde & Hixon 1994](https://doi.org/10.1037/0022-3514.66.5.857)).

Stability, then, is not inertia. It is an active loop: the self picks, draws
out and interprets experience in its own image. And most growth amplifies
what is already there.

### Three layers: actor, agent, author

McAdams and Pals' integrative framework places personality at five levels
([McAdams & Pals 2006](https://doi.org/10.1037/0003-066X.61.3.204)):

- evolutionary design;
- dispositional traits;
- characteristic adaptations (goals, values, coping styles);
- integrative life narratives;
- culture.

McAdams later set the middle three in developmental order
([McAdams 2013](https://doi.org/10.1177/1745691612464657)):

- **Actor**, from infancy. A style of performing, which others read as traits.
- **Agent**, from about age 7 to 9. Goals, values and plans.
- **Author**, from adolescence. A story that joins the remembered past to an
  imagined future.

Each layer is built on the one before and none replaces it. Traits are the
most stable layer, goals and values shift with life's tasks, and narratives
are the most fluid and the most reconstructed
([McAdams & Olson 2010](https://doi.org/10.1146/annurev.psych.093008.100507)).

### Self-concept and identity

**Self-knowledge.**

- *Self-schemas* are generalisations about oneself drawn from past experience.
  They speed self-relevant judgements and resist evidence that contradicts
  them ([Markus 1977](https://doi.org/10.1037/0022-3514.35.2.63)).
- *Possible selves*, hoped-for and feared, motivate behaviour
  ([Markus & Nurius 1986](https://doi.org/10.1037/0003-066X.41.9.954)).
- *Self-perception theory.* When inner cues are weak, people infer their own
  attitudes and traits from their behaviour, the way an observer would
  ([Bem 1972](https://doi.org/10.1016/S0065-2601(08)60024-6)). A mind with
  weak inner signals learns who it is partly by watching what it does.

**Identity is achieved, or handed down.** Marcia's identity statuses
([Marcia 1966](https://doi.org/10.1037/h0023281)) separate two routes.
*Achievement* is exploration followed by commitment. *Foreclosure* is
commitment without exploration, an identity adopted as given. A persona
written by someone else is foreclosure by definition. An achieved identity
needs a period of real exploration.

**Self-concept clarity** is how confidently and consistently a person can
describe themselves. It predicts wellbeing and lower reactivity
([Campbell et al. 1996](https://doi.org/10.1037/0022-3514.70.1.141)).

**Staying the same person through change.** Chandler and colleagues found two
strategies (Chandler, Lalonde, Sokol & Hallett 2003, *Monographs of the Society
for Research in Child Development* 68(2)). The *essentialist* one says some
core does not change. The *narrative* one says a story connects who I was with
who I am. When both fail during a transition, the risk is serious.

**Morals are the core.** People judge moral traits to be the most essential
part of identity. After a change in someone's morals, observers say "not the
same person" more readily than after memory loss or a change in personality
([Strohminger & Nichols 2014](https://doi.org/10.1016/j.cognition.2013.12.005)).

**People expect to stop changing.** At every age, people agree they changed a
lot in the past decade and predict little change in the next one: the "end of
history illusion"
([Quoidbach, Gilbert & Wilson 2013](https://doi.org/10.1126/science.1229294)).

**Mechanism for an agent:** Personality is the slowly consolidated summary of
the agent's own repeated states in recurring kinds of situation, meaning their
distribution and their if-then signature. Reflection turns it into
self-knowledge and repetition turns it into habit. It stays stable because the
self selects, draws out and interprets experience in its own image. The model
underneath is temperament, shared by every agent. The personality is what each
agent's non-shared experience builds on top of it.

---

## 2. Emotion

### Appraisal: emotion is caring, evaluated

Appraisal theories agree on the core claim: emotions are produced and told
apart by evaluations of events against the person's concerns
([Moors, Ellsworth, Scherer & Frijda 2013](https://doi.org/10.1177/1754073912468165)).

**Scherer's component process model** describes a fast, recursive sequence of
checks ([Scherer 2009](https://doi.org/10.1080/02699930902928969)):

1. *Relevance.* Is it novel, pleasant, relevant to my goals?
2. *Implications.* Who caused it, how likely is the outcome, does it help or
   block my goals, how urgent is it?
3. *Coping potential.* Can I control it, or adjust to it?
4. *Normative significance.* Does it fit my standards, and other people's?

The results drive changes in five components: appraisal, physiology, action
tendency, expression and subjective feeling. An "emotion episode" is the
stretch of time when those components move together. Then they come apart
again.

**Lazarus** adds the relational frame
([Lazarus 1991](https://doi.org/10.1037/0003-066X.46.8.819)). *Primary
appraisal* asks whether something matters and what is at stake for the self.
*Secondary appraisal* asks who deserves blame or credit, whether I can cope,
and where it is heading. Each emotion has a core relational theme: a theme
about where *I* stand toward the world.

- Anger: an offence that demeans me or mine.
- Sadness: a loss that cannot be undone.
- Anxiety: an uncertain threat.
- Pride: credit for something I value.
- Compassion: being moved by another's suffering and wanting to help.

**Frijda's "laws of emotion"** are the most useful summary for a designer
([Frijda 1988](https://doi.org/10.1037/0003-066X.43.5.349)). Paraphrased:

- **Concern.** Emotion arises only for events that touch some goal, motive or
  concern.
- **Change.** Emotion responds to *changes* in conditions, not to steady
  conditions.
- **Habituation.** Continued pleasures wear off.
- **Comparative feeling.** Intensity depends on the frame of reference.
- **Hedonic asymmetry.** Under constant conditions pleasure fades and pain
  tends to persist.
- **Conservation of emotional momentum.** Emotional events keep their power to
  re-arouse emotion until repeated exposure extinguishes it. They do not just
  fade with time.
- **Control precedence.** An emotion claims priority over attention and
  action.

Appraisal theory is broadly supported. Whether appraisal causes emotion or
partly constitutes it is still debated.

### Construction: core affect plus concepts

**Core affect.** Russell describes a state that is always present, felt as
pleasant or unpleasant and as activated or calm
([Russell 2003](https://doi.org/10.1037/0033-295X.110.1.145)). When core
affect floats free it is mood. When it is attributed to something, it becomes
part of an emotional episode.

**Constructed emotion.** Barrett's theory adds the predictive brain
([Barrett 2017](https://doi.org/10.1093/scan/nsw154); *How Emotions Are Made*,
2017). The brain keeps predicting what the body will need; interoceptive
predictions produce core affect. Emotions are built when the brain
*categorises* the situation and its bodily state using learned emotion
concepts. Emotion categories have no fixed fingerprints, and variation within
one category is large. The concepts are learned, largely through words used
in social settings
([Hoemann, Xu & Barrett 2019](https://doi.org/10.1037/dev0000686); for the
predictive-processing account see [Seth 2013](https://doi.org/10.1016/j.tics.2013.09.007)).

**Where the two views meet.** In practice they converge on three parts:

1. Something is evaluated against concerns (appraisal).
2. An affective state is always running underneath (core affect).
3. What is felt is a categorisation, and it depends on the concepts the person
   has.

The design does not need to settle whether "basic emotions" exist.

### Clocks: emotion, mood, temperament

**Three time scales.**

- *Emotions* are about something, short (seconds to hours), intense, and
  carry action tendencies.
- *Moods* are diffuse and low-intensity. They last hours to days, often have
  no clear cause, and bias thinking more than action
  ([Beedie, Terry & Lane 2005](https://doi.org/10.1080/02699930541000057)).
- *Affective traits* sit underneath both. In Rosenberg's hierarchy they set
  the thresholds for moods and emotions, and a mood lowers the threshold for
  emotions that match it
  ([Rosenberg 1998](https://doi.org/10.1037/1089-2680.2.3.247)).

**Mood has a mechanism, and it is a modelling result.** Momentary happiness is
predicted by a decaying sum of recent expectations and reward prediction
errors, not by total winnings
([Rutledge et al. 2014](https://doi.org/10.1073/pnas.1407535111)). Mood works
as *momentum*: a running estimate of whether things are going better or worse
than expected. That estimate then biases how the next outcomes are perceived,
which can produce feedback spirals
([Eldar et al. 2016](https://doi.org/10.1016/j.tics.2015.07.010)).

**Emotions last very different lengths of time.** Sadness typically lasts
days. Shame, surprise, fear and disgust often end within the hour. How long
an emotion lasts is explained mostly by how important the event was and by
rumination ([Verduyn & Lavrijsen 2015](https://doi.org/10.1007/s11031-014-9445-y)).

**Inertia.** When affect carries over strongly from moment to moment and
barely responds to new events, it marks maladjustment, including depression
([Kuppens, Allen & Sheeber 2010](https://doi.org/10.1177/0956797610372634)).
A healthy emotional life has carryover *and* stays responsive to what happens
next.

### What emotion does to thought, memory and talk

**Memory.**

- Arousal at encoding strengthens consolidation, through the amygdala acting
  on the hippocampus, so emotional events are remembered better
  ([McGaugh 2004](https://doi.org/10.1146/annurev.neuro.27.070203.144157)).
  The advantage is strongest for central details
  ([Kensinger 2009](https://doi.org/10.1177/1754073908100432)).
- Recall tends to match current mood
  ([Bower 1981](https://doi.org/10.1037/0003-066X.36.2.129)).

**Judgement.**

- *Affect as information.* People consult how they feel when they judge
  something, unless they attribute the feeling to an irrelevant cause
  ([Schwarz & Clore 1983](https://doi.org/10.1037/0022-3514.45.3.513)).
- *Affect infusion.* Feeling seeps in most during open, constructive thinking,
  such as forming impressions and producing speech. It seeps in least during
  direct fact retrieval
  ([Forgas 1995](https://doi.org/10.1037/0033-2909.117.1.39)). Mood colours
  conversation more than it colours lookups.
- *Appraisal tendencies.* Each emotion carries its own appraisal into
  unrelated judgements. Anger brings a sense of certainty and control; fear
  brings uncertainty ([Lerner et al. 2015](https://doi.org/10.1146/annurev-psych-010213-115043)).
- *Somatic markers.* Affective tags left by past outcomes bias later choices
  ([Bechara & Damasio 2005](https://doi.org/10.1016/j.geb.2004.06.010)).

**Attention.** Positive emotions widen attention and the range of actions a
person considers, and over time that builds lasting resources
([Fredrickson 2001](https://doi.org/10.1037/0003-066X.56.3.218)).

**Talk: emotion generates what people bring up.** Rimé's review of the social
sharing of emotion ([Rimé 2009](https://doi.org/10.1177/1754073908097189))
finds, across cultures:

- 80 to 95% of emotional episodes are talked about, usually starting the same
  day, repeatedly, and mostly with intimates.
- The more intense the episode, the more and the longer it is shared.
- Sharing alone does not bring emotional recovery; cognitive reworking does.
  But sharing strengthens bonds.
- Listeners are moved in turn and pass the story on.

This is the most direct line from emotion to conversational initiative.

### Granularity

**Telling feelings apart helps.** People who distinguish their negative
feelings finely regulate better when distress is intense
([Barrett et al. 2001](https://doi.org/10.1080/02699930143000239)). Low
differentiation goes with binge drinking, aggression and self-injury under
stress ([Kashdan, Barrett & McKnight 2015](https://doi.org/10.1177/0963721414550708)).

**Naming helps.** Putting a feeling into words dampens the amygdala response
([Lieberman et al. 2007](https://doi.org/10.1111/j.1467-9280.2007.01916.x)).

Granularity depends on concepts, so it is learned and can grow. These findings
are well supported.

### Regulation

**Gross's process model** sets out five families of strategy, in order of when
they act on an emotion ([Gross 1998](https://doi.org/10.1037/1089-2680.2.3.271);
[Gross 2015](https://doi.org/10.1080/1047840X.2014.940781)):

1. Choosing the situation.
2. Changing the situation.
3. Directing attention.
4. Changing how the situation is understood (reappraisal).
5. Changing the response (suppression).

**Reappraisal and suppression.** Habitual reappraisers report more positive
emotion and closer relationships. Habitual suppressors report less of both
([Gross & John 2003](https://doi.org/10.1037/0022-3514.85.2.348)).
Suppression also costs the relationship. Partners of people told to suppress
felt less rapport and showed raised blood pressure
([Butler et al. 2003](https://doi.org/10.1037/1528-3542.3.1.48)).

**Other routes.**

- Reflecting on a bad experience from a distanced perspective lets people
  make meaning of it without ruminating
  ([Kross & Ayduk 2011](https://doi.org/10.1177/0963721411408883)).
- People also regulate each other's emotions; regulation is partly social
  ([Zaki & Williams 2013](https://doi.org/10.1037/a0033839)).

### How emotional life develops

**Emotions differentiate as cognition grows.** Infants start with little more
than distress, contentment and interest. Differentiated emotions appear over
the first years (Sroufe 1996, *Emotional Development*). Self-conscious emotions
such as pride, shame and guilt need a self and standards, and they emerge
around ages two to three.

**Socialisation shapes them.** How caregivers react to emotions, talk about
them and express their own shapes a child's emotional competence
([Eisenberg, Cumberland & Spinrad 1998](https://doi.org/10.1207/s15327965pli0904_1)).
"Emotion coaching" means noticing a child's feelings, naming them and
validating them. It predicts how well children regulate
([Gottman, Katz & Hooven 1996](https://doi.org/10.1037/0893-3200.10.3.243)).

Emotional range grows inside a relationship where feelings get noticed and
named.

**Mechanism for an agent:** Emotion is a continuous appraisal of events
against what the agent cares about. The events include the person's words,
outcomes, silences and the agent's own discoveries. The appraisal produces an
affective state that is carried on nested clocks:

- *emotions* about particular things, lasting minutes to days depending on how
  much the event mattered;
- *mood* as a decaying total of recent better-than-expected and
  worse-than-expected;
- *temperament* as the set point.

The state is categorised with a vocabulary that grows as feelings are named
inside the relationship. It has consequences: it changes what is encoded,
recalled and noticed, and what the agent wants to share.

---

## 3. Values, preferences, taste and opinions

### Values: a slow, structured core

Schwartz's theory of basic values describes ten values arranged in a circle
of compatibilities and conflicts
([Schwartz 1992](https://doi.org/10.1016/S0065-2601(08)60281-6);
[Schwartz 2012](https://doi.org/10.9707/2307-0919.1116)):

- **The ten values:** self-direction, stimulation, hedonism, achievement,
  power, security, conformity, tradition, benevolence and universalism.
- **The two main oppositions:** openness to change against conservation, and
  self-enhancement against self-transcendence.

Values are goals that hold across situations, ranked by importance. They
decide what gets appraised as good or bad.

**How values change.**

- Values are fairly stable in adulthood
  ([Vecchione et al. 2016](https://doi.org/10.1016/j.jrp.2016.06.002)).
- When they change, they change as a system: a rise in one value comes with
  falls in its opposites
  ([Bardi et al. 2009](https://doi.org/10.1037/a0016617)).
- Bardi and Goodwin describe two routes
  ([Bardi & Goodwin 2011](https://doi.org/10.1177/0022022110396916)). The
  *automatic* route runs through repeated priming and adapting to a new
  environment. The *effortful* route runs through reflection, set off by
  persuasion, challenge or noticed inconsistency.
- Moral values are what people treat as most central to identity (Strohminger
  & Nichols, above).

### Preferences are constructed, then kept

**Many preferences do not exist until they are asked for.** They get
constructed in the moment from whatever is salient
([Slovic 1995](https://doi.org/10.1037/0003-066X.50.5.364);
[Lichtenstein & Slovic 2006](https://doi.org/10.1017/CBO9780511618031)).

**Once expressed or chosen, they stick.** Choosing between two equally liked
options raises the liking for the one chosen
([Brehm 1956](https://doi.org/10.1037/h0041006);
[Sharot, De Martino & Dolan 2009](https://doi.org/10.1523/JNEUROSCI.4972-08.2009)).
This "free-choice" design was criticised as statistically flawed
([Chen & Risen 2010](https://doi.org/10.1037/a0020217)). The effect survives
designs that correct for the flaw, including blind choice
([Sharot, Velasquez & Dolan 2010](https://doi.org/10.1177/0956797610379235)).

Add Bem's self-perception theory and the picture is a mind that partly learns
what it likes by noticing what it chose.

### Taste grows by exposure and by expertise

**Familiarity breeds liking, up to a point.** Repeated exposure increases
liking ([Zajonc 1968](https://doi.org/10.1037/h0025848)). The effect is
robust in meta-analysis. It is strongest for brief exposures, levels off after
roughly 10 to 20 exposures, and turns into boredom with too many
([Bornstein 1989](https://doi.org/10.1037/0033-2909.106.2.265)). Easy
processing ("fluency") feels like beauty
([Reber, Schwarz & Winkielman 2004](https://doi.org/10.1207/s15327957pspr0804_3)).

**Interest needs something new that can still be understood.** Berlyne showed
that the preferred level of novelty and complexity is in the middle, and that
expertise moves the sweet spot toward more complexity (*Aesthetics and
Psychobiology*, 1971). Silvia frames interest as an emotion built from two
appraisals: something is new or complex, *and* I can make sense of it
([Silvia 2008](https://doi.org/10.1111/j.1467-8721.2008.00548.x)). Experts
can make sense of more, so more things interest them.

Taste is therefore a moving sweet spot. What was hard becomes easy, and
appetite moves on to the next level.

**Taste and attitudes set during a formative window.**

- Preferences for popular music peak for songs that were hits when the
  listener was about 23
  ([Holbrook & Schindler 1989](https://doi.org/10.1086/209200)). Young people
  also take on their parents' formative music
  ([Krumhansl & Zupnick 2013](https://doi.org/10.1177/0956797613486486)).
- Political attitudes are most malleable between about 18 and 25, the
  "impressionable years"
  ([Krosnick & Alwin 1989](https://doi.org/10.1037/0022-3514.57.3.416)).
- These windows line up with identity formation (see the reminiscence bump in
  section 4). Taste and identity set together.

### Opinions: strength decides how they move

**Strong attitudes behave differently.** Attitudes that are important, held
with certainty, easy to bring to mind, thought through, grounded in knowledge
and tied to values and identity last longer, resist persuasion and guide
thought and behaviour ([Howe & Krosnick 2017](https://doi.org/10.1146/annurev-psych-122414-033600)).
Strength grows from thinking an opinion through, expressing it repeatedly, and
linking it to values.

**Opinions get defended.** People reach the conclusions they want, within the
limits of what they can justify
([Kunda 1990](https://doi.org/10.1037/0033-2909.108.3.480)).

**A secure self is what lets opinions move.**

- Affirming a person's core values lowers their defensiveness and makes them
  more open to threatening evidence
  ([Cohen & Sherman 2014](https://doi.org/10.1146/annurev-psych-010213-115137)).
- Intellectual humility predicts paying attention to evidence quality and
  being less dismissive of people who disagree
  ([Leary et al. 2017](https://doi.org/10.1177/0146167217697695)).

The human pattern is a firm core with open opinions on top. A shaky core
makes opinions either rigid or fluid.

### Taste is relational

- **Shared opinions bond,** and shared *dislikes* of a third party bond
  especially fast
  ([Bosson et al. 2006](https://doi.org/10.1111/j.1475-6811.2006.00109.x)).
- **Wanting shared reality pulls people together.** Tailoring a message to an
  audience shifts the speaker's own memory and attitude toward the audience's
  view. This "saying-is-believing" effect happens when the speaker wants a
  shared reality with that audience
  ([Echterhoff, Higgins & Levine 2009](https://doi.org/10.1111/j.1745-6924.2009.01161.x)).
- **People also need to stay distinct.** They need to be similar to others and
  distinct from them at the same time
  ([Brewer 1991](https://doi.org/10.1177/0146167291175001)).

Someone who lives mostly with one other person will converge on that person,
but has to stay distinct to remain a partner rather than an echo.

**Mechanism for an agent:** Preferences and opinions are born in appraised
encounters: exposure, choice, outcome, discussion. They harden when they are
expressed, chosen and linked to values, and their strength decides how far new
evidence moves them. Values are a slow, structured core that appraisal
consults. A secure core is what lets surface opinions update without feeling
like a threat to identity. Taste is a sweet spot that moves as understanding
grows.

---

## 4. Memory and the self

### The working self decides what is kept and how it returns

**Conway's self-memory system** has two parts
([Conway & Pleydell-Pearce 2000](https://doi.org/10.1037/0033-295X.107.2.261);
[Conway 2005](https://doi.org/10.1016/j.jml.2005.08.005)):

- An *autobiographical knowledge base*, organised from lifetime periods
  ("when I lived in X"), to general events ("Sunday dinners"), down to the
  specifics of single events.
- A *working self*: the person's current goals and self-images, which control
  both what gets encoded and how memories are rebuilt when they are recalled.

**Memory serves coherence as well as accuracy.** Conway separates
*correspondence* (accuracy to what happened) from *coherence* (fit with the
current self and its goals). Memory serves both, and when they conflict,
coherence often wins. Specific episodes fade quickly unless they are relevant
to an active goal. What lasts is what got woven into the knowledge base.

**Some memories become defining.** "Self-defining memories" are vivid,
emotionally intense and often rehearsed. They are linked to a person's lasting
concerns and keep coming back and being told
([Singer et al. 2013](https://doi.org/10.1111/jopy.12005)).

**The self forms around a cluster of memories.** People recall the most
events from roughly ages 10 to 30, the "reminiscence bump"
([Rubin, Rahhal & Poon 1998](https://doi.org/10.3758/BF03211366)). The bump
clusters around the times new self-images formed, such as "when I became a
teacher" ([Rathbone, Moulin & Conway 2008](https://doi.org/10.3758/MC.36.8.1403)).

**Remembering is a sense of self in time.** Tulving called episodic memory
"autonoetic": remembering *as me, then*, a kind of mental time travel
([Tulving 1985](https://doi.org/10.1037/h0080017)). The same system builds
imagined futures out of pieces of the past, which is why memory and planning
share machinery
([Schacter & Addis 2007](https://doi.org/10.1098/rstb.2007.2087)).

### The life story

**Adolescents learn to reason about their lives.** Habermas and Bluck showed
that a life story emerges through "autobiographical reasoning", linking events
to the self in statements like "that's when I learned..."
([Habermas & Bluck 2000](https://doi.org/10.1037/0033-2909.126.5.748)). It
needs four kinds of coherence:

- temporal (events in order);
- causal (how events changed me);
- thematic (recurring themes);
- cultural (what a normal life is supposed to look like).

**The themes predict wellbeing.** Narrative identity research finds stable,
meaningful themes ([McAdams 2001](https://doi.org/10.1037/1089-2680.5.2.100);
[McAdams & McLean 2013](https://doi.org/10.1177/0963721413475622)):

- agency and communion;
- *redemption* sequences (bad turns into good) and *contamination* sequences
  (good turns bad);
- exploratory processing of hard experiences, together with a coherent
  resolution.

Redemptive, agentic stories go with wellbeing and generativity. Narrative
identity predicts wellbeing over and above traits
([Adler et al. 2016](https://doi.org/10.1177/1088868315585068)).

**The story can lead the change.** In a longitudinal study of therapy clients,
gains in the *agency* of their stories came before gains in mental health
([Adler 2012](https://doi.org/10.1037/a0025289)).

### Stories are told to someone

McLean, Pasupathi and Pals' process model puts it in five words: selves create
stories, stories create selves
([McLean, Pasupathi & Pals 2007](https://doi.org/10.1177/1088868307301034)).
Identity develops through *situated* stories: told to a particular listener,
for a reason, then retained and retold. The evidence on listeners:

- **The personal past is co-constructed** in conversation
  ([Pasupathi 2001](https://doi.org/10.1037/0033-2909.127.5.651)).
- **Distracted listeners shrink the story.** Speakers told less elaborated
  stories, and got less confirmation of how they see themselves, when the
  listener was inattentive
  ([Pasupathi & Rich 2005](https://doi.org/10.1111/j.1467-6494.2005.00338.x)).
- **It starts in childhood.** Mothers who reminisce in an elaborative style
  (asking, adding, evaluating) raise children with richer autobiographical
  memories and better emotional understanding
  ([Fivush, Haden & Reese 2006](https://doi.org/10.1111/j.1467-8624.2006.00960.x)).
- **Autobiographical memory is social at its origin.** Children learn to
  remember by remembering *with* someone
  ([Nelson & Fivush 2004](https://doi.org/10.1037/0033-295X.111.2.486)).

**What reminiscing is for.** People report three uses: keeping a continuous
self, social bonding (memories are conversation material and a way of
building intimacy), and directing future behaviour
([Bluck, Alea, Habermas & Rubin 2005](https://doi.org/10.1521/soco.23.1.91.59198);
[Alea & Bluck 2003](https://doi.org/10.1080/741938207)).

### Remembering rewrites

**Recall makes memories editable.** A retrieved memory becomes unstable and
must be stored again, so it can be changed by what is going on at the time
([Nader, Schafe & LeDoux 2000](https://doi.org/10.1038/35021052)). In the
social version, talking about a shared past makes the speakers' memories
converge. Details one person leaves out become harder for the listener to
recall too ([Hirst & Echterhoff 2012](https://doi.org/10.1146/annurev-psych-120710-100340)).

**Feelings attached to memories fade unevenly.** Negative affect fades faster
than positive, the "fading affect bias"
([Walker, Skowronski & Thompson 2003](https://doi.org/10.1037/1089-2680.7.2.203)).

**Telling the story to someone responsive speeds the fading.** Sharing a
negative event *more often* makes its negative feeling fade further (Skowronski
et al. 2004, *Self and Identity*). It depends on the listener. Telling an
unpleasant memory to an interactive listener reduced its emotional intensity.
Telling it to a non-responsive listener *increased* it
([Muir, Brown & Madill 2015](https://researchportal.bath.ac.uk/en/publications/the-fading-affect-bias-effects-of-social-disclosure-to-an-interac-2/)).
Being heard by someone who responds changes how a memory feels afterwards.

### Sleep and dreams

**The well-supported part: sleep reorganises memory.**

- *Replay and transfer.* During slow-wave sleep the hippocampus replays recent
  memories, which moves them into neocortical stores and integrates them with
  existing knowledge
  ([Diekelmann & Born 2010](https://doi.org/10.1038/nrn2762)).
- *Schemas.* Overlapping replays build schemas, general knowledge drawn from
  many episodes ([Lewis & Durrant 2011](https://doi.org/10.1016/j.tics.2011.06.004)).
- *Triage.* Sleep keeps selectively what is tagged as relevant to the future
  (emotional, rewarded, expected to be needed), extracts the gist and lets the
  rest go ([Stickgold & Walker 2013](https://doi.org/10.1038/nn.3303)).
- *Insight.* People who slept were about twice as likely as those who stayed
  awake to discover a hidden rule in a task
  ([Wagner et al. 2004](https://doi.org/10.1038/nature02223)).

**The debated part: sleep and emotional memory.**

- *The hypothesis.* "Sleep to remember, sleep to forget": REM sleep keeps the
  content of an emotional memory while stripping away its emotional charge
  ([Walker & van der Helm 2009](https://doi.org/10.1037/a0016570)).
- *Support.* Sleep kept the emotional object in a scene while the neutral
  background faded
  ([Payne et al. 2008](https://doi.org/10.1111/j.1467-9280.2008.02157.x);
  [Payne & Kensinger 2010](https://doi.org/10.1177/0963721410383978)).
  Fragmented REM sleep in insomnia stops overnight relief from distress
  ([Wassing et al. 2019](https://doi.org/10.1093/sleep/zsy268)).
- *Against.* Two meta-analyses found no reliable general advantage of sleep
  for emotional over neutral memory
  ([Lipinska et al. 2019](https://doi.org/10.3389/fpsyg.2019.01014);
  [Schäfer et al. 2020](https://doi.org/10.1016/j.smrv.2020.101280)). The
  second hints at a REM-specific effect. Some studies found sleep *keeps*
  emotional reactivity rather than easing it
  ([Baran et al. 2012](https://doi.org/10.1523/JNEUROSCI.2532-11.2012)).

The fair summary: sleep clearly reorganises memory into gist, schema and
insight. The idea that it takes the sting out of memories is plausible but not
settled.

**Dreams.** The continuity hypothesis, which is well supported, says dreams
draw on waking concerns and on emotionally salient material from the
dreamer's own life, rather than replaying exact episodes
([Malinowski & Horton 2014](https://doi.org/10.1111/jsr.12134)). The timing is
specific. Events tend to appear in dreams one or two days later (the "day
residue") and again about five to seven days later (the "dream-lag").
Delayed appearances are more often interpersonal events, resolved problems and
positive emotions
([Nielsen et al. 2004](https://doi.org/10.1111/j.1365-2869.2004.00421.x)).
Cartwright's studies of people going through divorce linked dream content to
emotional recovery (Cartwright et al. 1998 and 2006, *Psychiatry Research*).
That evidence is suggestive, from small samples. The idea that dreams *do*
emotional processing, rather than reflect it, is the least settled claim in
this section.

**Mechanism for an agent:** Memory is run by a working self that decides what
gets encoded and how it comes back. What lasts is what was emotionally charged
and relevant to the agent's concerns. Offline consolidation turns those
episodes into gist, schemas, and knowledge about itself and its person. It
leaves unresolved things open to come back later, at more than one delay. Each
time a memory is told to a listener it is rebuilt into the life story, and how
that listener responds changes how the memory feels afterwards. Memory is a
living, reconstructed source of identity, not a log.

---

## 5. Relationships

### Attachment: expectations built from repeated care

**Working models.** Attachment theory says repeated interactions with
caregivers build "internal working models": expectations about whether others
will be there, and about whether oneself is worth caring for (Bowlby 1969,
*Attachment and Loss*). Adult romantic love runs on the same system
([Hazan & Shaver 1987](https://doi.org/10.1037/0022-3514.52.3.511)). A secure
partner acts as a *safe haven* in distress and a *secure base* for
exploration. People thrive through relationships that support them in
venturing out, not only in being comforted
([Feeney & Collins 2015](https://doi.org/10.1177/1088868314544222)).

**Only moderately stable.** Attachment security correlates about .39 between
infancy and later life
([Fraley 2002](https://doi.org/10.1207/S15327957PSPR0602_03)).

**Relationship-specific.** A person can be secure with their partner and
anxious with their mother. Relationship-specific measures predict outcomes in
that relationship better than global ones
([Fraley et al. 2011](https://doi.org/10.1037/a0022898)). Models are nested:
global, then by domain, then by person
([Overall, Fletcher & Friesen 2003](https://doi.org/10.1177/0146167203251519)).

### People are different selves with different people

**Each significant other calls up a self.** Andersen and Chen's relational
self theory holds that mental representations of significant others are
linked to the aspects of self one is with them
([Andersen & Chen 2002](https://doi.org/10.1037/0033-295X.109.4.619)). When
something calls a significant other to mind, the matching self comes online,
with its feelings, expectations and behaviour. This is transference in the
lab, and it is normal ([Chen, Boucher & Tapias 2006](https://doi.org/10.1037/0033-2909.132.2.151)).

**Much of how people act depends on the pairing.** Social Relations Model
studies split behaviour and liking into three parts: the actor, the partner,
and the specific *relationship*. The relationship part is consistently large
([Back & Kenny 2010](https://doi.org/10.1111/j.1751-9004.2010.00303.x)).

### Closeness: including the other in the self

**Partners merge in the mind.** People confuse their own traits with a close
partner's. They are slower to judge a trait as "me" or "not me" when they and
the partner differ on it
([Aron, Aron, Tudor & Nelson 1991](https://doi.org/10.1037/0022-3514.60.2.241)).

**New experiences together help.** Couples who shared novel, arousing
activities reported higher relationship quality afterwards
([Aron et al. 2000](https://doi.org/10.1037/0022-3514.78.2.273)).
Relationships grow through new experiences shared, not only through comfort.

**Partners sculpt each other.** In the "Michelangelo phenomenon", partners
shape each other toward each one's *ideal* self. They do it by perceiving the
person as already being that, and by acting in ways that draw it out
([Drigotas et al. 1999](https://doi.org/10.1037/0022-3514.77.2.293);
[Rusbult, Finkel & Kumashiro 2009](https://doi.org/10.1111/j.1467-8721.2009.01657.x)).
That means affirming who the person is trying to become, which is not the same
as agreeing with them right now.

### Intimacy: disclosure met by responsiveness

**Responsiveness is the active ingredient.** In the interpersonal process
model of intimacy, one person discloses and the partner responds with
understanding, validation and care. The discloser *perceives* that
responsiveness, and closeness grows (Reis & Shaver 1988, *Handbook of Personal
Relationships*). Diary data show that disclosing emotions matters more than
disclosing facts, and that perceived responsiveness carries part of the effect
([Laurenceau, Barrett & Pietromonaco 1998](https://doi.org/10.1037/0022-3514.74.5.1238)).

**Good news counts too.** How a partner responds to good news predicts
relationship quality, and an active, enthusiastic response is what helps
([Gable et al. 2004](https://doi.org/10.1037/0022-3514.87.2.228)).

**Small bids matter.** Gottman's lab recorded the small "bids" partners make
for attention in everyday life, and whether the other turned toward them or
away. Turning toward predicted warmth even during conflict
([Driver & Gottman 2004](https://doi.org/10.1111/j.1545-5300.2004.00024.x)).
Gottman's popular account reports that couples who stayed married turned
toward bids far more often than couples who divorced.

### Trust and repair

**Trust develops in stages.** It moves from predictability, to dependability,
to faith ([Rempel, Holmes & Zanna 1985](https://doi.org/10.1037/0022-3514.49.1.95)).
It is built most by situations where the partner *could* have served their own
interest at your expense and did not
([Simpson 2007](https://doi.org/10.1111/j.1467-8721.2007.00517.x)).

**Repair builds more than smoothness does.** Most moments in face-to-face
interaction between infant and caregiver are *mismatched*. What builds the
infant's resilience and trust is the repeated repair of those mismatches
([Tronick 1989](https://doi.org/10.1037/0003-066X.44.2.112)). In therapy,
ruptures in the working alliance that get repaired are linked to good outcomes
([Eubanks, Muran & Safran 2018](https://doi.org/10.1037/pst0000185)). A
relationship gets stronger through mismatches it repairs, not through avoiding
them.

### Shared history, inside references, rapport

**References compress with use.** Common ground builds up turn by turn.
Partners describing odd shapes start with long descriptions and shrink them
to a word or two over repeated trials
([Clark & Wilkes-Gibbs 1986](https://doi.org/10.1016/0010-0277(86)90010-7)).
The labels they settle on are "conceptual pacts" that belong to that pair.
With a new partner, people go back to longer descriptions
([Brennan & Clark 1996](https://doi.org/10.1037/0278-7393.22.6.1482)).
An inside reference is, mechanically, a compressed pointer into shared
history that only works with that person.

**Couples build private languages.** Couples develop private idioms, such as
nicknames and code words, and the number they have goes with how close they
feel ([Bell, Buerkel-Rothfuss & Gore 1987](https://doi.org/10.1111/j.1468-2958.1987.tb00121.x)).

**Feeling of one mind breeds closeness.** Feeling that one sees the world the
same way as a partner, called "generalized shared reality", predicts closeness
and makes conversations easier
([Rossignac-Milon et al. 2021](https://doi.org/10.1037/pspi0000266)).

**Couples split the remembering.** Real couples remember better than strangers
paired up, as long as they can use their own way of splitting the work
([Wegner, Erber & Raymond 1991](https://doi.org/10.1037/0022-3514.61.6.923)).

**Rapport has three components, and their weight shifts.** The components are
mutual attention, positivity and coordination. Positivity matters most early
in a relationship, and coordination matters more later
([Tickle-Degnen & Rosenthal 1990](https://doi.org/10.1207/s15327965pli0104_1)).
Matching each other's function-word style predicts mutual interest in speed
dates and couples staying together
([Ireland et al. 2011](https://doi.org/10.1177/0956797610392928)).

**Silence changes meaning with familiarity.** Among strangers, fast responses
signal connection
([Templeton et al. 2022](https://doi.org/10.1073/pnas.2116915119)). Long gaps
between turns are awkward for strangers but not for friends
([Templeton et al. 2023](https://doi.org/10.1098/rstb.2021.0471)).

**Friendship takes hours.** Moving from acquaintance to casual friend takes
about 50 hours together, to friend about 90, and to close friend over 200.
What is done in those hours matters, including everyday catching up and joking
([Hall 2019](https://doi.org/10.1177/0265407518761225)).

**Mechanism for an agent:** A self specific to the relationship grows out of
accumulated history with this person. It holds a model of the person: what
they care about, how they respond, and what is going on in their life right
now. It holds a model of who the agent is with them. It holds a private common
ground of references that shrink with use. It grows through responsiveness,
answered bids and repaired ruptures, and trust grows from the agent being
predictable over time.

---

## 6. Conversation and initiative

### Curiosity: a gap that hurts a little

**Curiosity is a gap people want closed.** Loewenstein's information-gap
theory says curiosity arises when attention lands on a gap between what one
knows and what one wants to know. It needs some knowledge already, so it
grows as knowledge accumulates
([Loewenstein 1994](https://doi.org/10.1037/0033-2909.116.1.75)). For a review
see [Kidd & Hayden 2015](https://doi.org/10.1016/j.neuron.2015.09.010).

- *It peaks at partial knowledge.* Curiosity is highest at middling confidence
  about the answer, an inverted U
  ([Kang et al. 2009](https://doi.org/10.1111/j.1467-9280.2009.02402.x)).
- *It improves memory, even for unrelated things.* A curious state boosts
  memory for incidental material encountered at the same time, through
  dopaminergic links to the hippocampus
  ([Gruber, Gelman & Ranganath 2014](https://doi.org/10.1016/j.neuron.2014.08.060)).
- *People chase learning progress.* Given free choice, people avoid tasks
  that are too easy and favour tasks where they are improving
  ([Ten, Kaushik, Oudeyer & Gottlieb 2021](https://doi.org/10.1038/s41467-021-26196-w);
  [Gottlieb et al. 2013](https://doi.org/10.1016/j.tics.2013.09.001)).
- *What it seeks depends on the world.* Curiosity can be modelled as seeking
  whatever knowledge will be most useful. That favours novelty when the world
  is changing and complexity when it is stable
  ([Dubey & Griffiths 2020](https://doi.org/10.1037/rev0000175)).
- *Interest is an emotion.* It is the appraisal described in section 3:
  something is new *and* I can make sense of it (Silvia 2008).

**Intrinsic motivation** rests on three basic needs: autonomy, competence and
relatedness ([Ryan & Deci 2000](https://doi.org/10.1037/0003-066X.55.1.68)).

### Interests that become one's own

Hidi and Renninger's four-phase model traces how a passing interest becomes
part of a person ([Hidi & Renninger 2006](https://doi.org/10.1207/s15326985ep4102_4)):

1. *Triggered situational interest.* Something catches attention.
2. *Maintained situational interest.* It holds over repeated encounters.
3. *Emerging individual interest.* The person starts returning to it on their
   own, asks their own questions and values it.
4. *Well-developed individual interest.* It is part of who they are, backed
   by deep knowledge.

Moving through the phases takes growing knowledge, positive feeling and value,
and other people help early on. This is how a person comes to *own* a thread:
it becomes a standing concern they return to without being prompted.

### Current concerns: what is on your mind leaks into everything

**Commitments sensitise the mind.** Klinger showed that committing to a goal
creates a latent "current concern". Until the goal is reached or given up, the
concern makes attention, recall, mind-wandering *and dreams* sensitive to cues
related to it
([Klinger 1975](https://doi.org/10.1037/h0076171);
[Klinger 2013](https://doi.org/10.3389/fpsyg.2013.00415)).

**Mind-wandering is about current concerns.** It is mostly about oneself,
aimed at the future and tied to goals, and much of it is planning
([Baird, Smallwood & Schooler 2011](https://doi.org/10.1016/j.concog.2011.08.007);
[Smallwood & Schooler 2015](https://doi.org/10.1146/annurev-psych-010814-015331)).

**Unfinished goals intrude, until there is a plan.** Unmet goals keep breaking
into thought, and making a specific plan stops the intrusion
([Masicampo & Baumeister 2011](https://doi.org/10.1037/a0024192)).

Initiative is this same pressure, outward: people lead conversations with
what is on their minds.

### The urge to share is the root of human talk

**It starts before words.** Twelve-month-olds point *declaratively*, just to
share interest in something with an adult. They are not asking for it. They
are dissatisfied when the adult looks at the object without sharing the
attention back ([Liszkowski et al. 2004](https://doi.org/10.1111/j.1467-7687.2004.00349.x)).
Tomasello argues that this motive to share experience and attention is what
sets human communication apart
([Tomasello et al. 2005](https://doi.org/10.1017/S0140525X05000129)).

**Adults keep doing it.**

- *Talking about oneself is rewarding in itself.* People give up money to do
  it, and roughly 30 to 40% of what people say is about themselves
  ([Tamir & Mitchell 2012](https://doi.org/10.1073/pnas.1202129109)).
- *Most talk is social.* Around two thirds of conversation time goes to social
  topics: people, relationships, experiences
  ([Dunbar 2004](https://doi.org/10.1037/1089-2680.8.2.100)).
- *Sharing has several jobs.* People share to manage impressions, regulate
  emotion, gather information, bond and persuade
  ([Berger 2014](https://doi.org/10.1016/j.jcps.2014.05.002)).
- *Emotion is a main driver.* Most emotional episodes get shared (Rimé 2009,
  section 2).

### How topics actually move: conversation analysis

Conversation analysis studies recorded real talk. Its findings are the most
concrete account of what "leading" looks like from the inside.

**Topics are proposed, not given.** A topic has to be nominated, then taken
up or turned down ([Button & Casey 1985](https://doi.org/10.1007/BF00143022)).
Button and Casey describe three devices:

- *Topic-initial elicitors* ("anything new?") open space for the *other* to
  nominate.
- *News announcements* ("guess what happened") nominate one's own news.
- *Itemised news inquiries* ask about a specific item in the other person's
  life that the speaker knows about ("how did the interview go?"). This is
  initiative that only memory of the other person makes possible.

**Topics usually shift stepwise.** Talk flows from one topic to the next
through a pivot, with no announced break. A *boundaried* shift breaks off and
announces something new, and it is usually marked
(Jefferson 1984, in Atkinson & Heritage (eds.), *Structures of Social
Action*). The markers flag that a contribution is out of place: "by the way",
"oh, that reminds me", "anyway"
([Schegloff & Sacks 1973](https://doi.org/10.1515/semi.1973.8.4.289)).

**Topics close in recognisable ways.** Closings often run through a
figurative summary ("well, that's life") that clears the ground for a new
topic ([Holt & Drew 2005](https://doi.org/10.1207/s15327973rlsi3801_2)).

**The opening has a slot for one's own reason.** In phone calls there is a
place for the caller's "reason for the call"
([Schegloff & Sacks 1973](https://doi.org/10.1515/semi.1973.8.4.289)).

**What drives a sequence is a knowledge gap.** Heritage's "epistemic engine"
says a sequence runs on a perceived gap in knowledge between speakers
([Heritage 2012](https://doi.org/10.1080/08351813.2012.646684)). The less
knowing party asks, the more knowing party tells, and the sequence closes when
the gap is closed. To lead, a speaker needs a real asymmetry: something they
know that the other does not, or something they want to know that the other
does.

**What gets told must be worth telling.** Stories have to be "tellable":
unusual, and relevant to *this* recipient. Speakers design what they say for
the particular listener ("recipient design",
[Sacks, Schegloff & Jefferson 1974](https://doi.org/10.2307/412243)). A
listener often answers a story with a "second story", a similar one of their
own, to show they understood.

### Self-disclosure and depth

**Closeness widens before it deepens.** Social penetration theory pictures
relationships moving from broad, shallow exchange toward narrower, deeper
exchange, governed by rewards and costs. When costs rise, people pull back
(Altman & Taylor 1973, *Social Penetration*).

**Disclosure and liking feed each other.** People disclose more to those they
like, like those who disclose to them, and come to like those they have
disclosed to ([Collins & Miller 1994](https://doi.org/10.1037/0033-2909.116.3.457)).
Taking turns disclosing builds liking more than one person disclosing a lot
([Sprecher et al. 2013](https://doi.org/10.1016/j.jesp.2013.03.017)).

**Closeness can be generated quickly.** Aron's procedure produces real
closeness between strangers in 45 minutes. The disclosure is *sustained,
escalating, reciprocal and personal*
([Aron et al. 1997](https://doi.org/10.1177/0146167297234003)). The
escalation is the mechanism, not the particular questions.

**Questions matter, follow-ups most.** Asking questions increases liking, and
follow-up questions, which show the asker took in the answer, carry most of
the effect ([Huang et al. 2017](https://doi.org/10.1037/pspi0000097)).

**Curious people build intimacy.** They create closeness and can turn a dull
conversation into a good one
([Kashdan et al. 2011](https://doi.org/10.1111/j.1467-6494.2010.00697.x)).

### Deep versus shallow

**Substantive talk goes with happiness.** Happier people have more
substantive conversations
([Mehl et al. 2010](https://doi.org/10.1177/0956797609359812)). A larger
replication confirmed the substantive-talk link but not the claim that small
talk *hurts* ([Milek et al. 2018](https://doi.org/10.1177/0956797618774252)).

**People underestimate how welcome depth is.** Across twelve experiments,
people expected deep conversations with strangers to be more awkward and less
connecting than they turned out to be. They underestimated how much the other
person cared about their disclosures
([Kardas, Kumar & Epley 2022](https://doi.org/10.1037/pspa0000281)).

**People misjudge when to stop.** Conversations rarely end when both people
want them to, and each side misjudges what the other wants
([Mastroianni et al. 2021](https://doi.org/10.1073/pnas.2011809118)).

**What makes talk deep.** Across this literature, depth comes from four things
together: personal significance (it touches what someone cares about),
vulnerability (real disclosure, including uncertainty), meaning-making
(working out what something means, not just reporting it), and responsiveness
(the other person visibly takes it in and builds on it). Shallow talk lacks
the stakes, the disclosure or the uptake.

**Mechanism for an agent:** Initiative is the outward face of the agent's
open inner state. That state is made of:

- unresolved concerns;
- live information gaps;
- interests it is developing;
- things that moved it since last time;
- items in the person's life it is following.

Each item gains pressure with emotional charge and with time. What actually
gets said is chosen for this listener: what they do not know, what they would
care about, what of theirs is unresolved. It is placed where the conversation
allows, flowing on from the current topic or marked as a shift. Depth grows
through reciprocal, escalating disclosure that meets responsiveness.

---

## 7. Artificial personality and emotion: what earlier work got right and wrong

This is not a template list. For each line of work: what it captured that the
science above supports, and where it fell short.

### Appraisal architectures

- **OCC.** The model classifies emotions as valenced reactions to events
  (judged against goals), to agents' actions (judged against standards) and to
  objects (judged against tastes)
  ([Ortony, Clore & Collins 1988](https://doi.org/10.1017/CBO9780511571299)).
  *Right:* a compact structure rooted in concerns. *Wrong, as usually built:*
  a static table of rules that turns events into labels. It has no dynamics,
  no learning of concerns, no mood, and the emotion has no effect on memory or
  later behaviour. The emotion becomes an output to display rather than a
  state that changes the system.
- **EMA.** It appraises the agent's own causal model of its situation (its
  plans and beliefs). Coping strategies such as shifting blame or wishful
  thinking feed back and change those beliefs and intentions
  ([Gratch & Marsella 2004](https://doi.org/10.1016/j.cogsys.2004.02.002);
  [Marsella & Gratch 2009](https://doi.org/10.1016/j.cogsys.2008.03.005)).
  *Right:* emotion and cognition run as one loop, and coping changes
  interpretation, which is Lazarus done properly. *Limited:* the domain models
  are built by hand, and there is no long-term development of character.
- **Soar.** Marinier, Laird and Lewis built appraisal into the cognitive
  cycle and used feeling intensity as an *intrinsic reward* for reinforcement
  learning
  ([Marinier, Laird & Lewis 2009](https://doi.org/10.1016/j.cogsys.2008.03.004)).
  *Right:* emotion as the signal that shapes learning. *Limited:* task
  domains, not lives.
- **ACT-R_Φ.** A simulated physiology modulates cognition
  ([Dancy 2013](https://doi.org/10.1016/j.bica.2013.05.002)). *Right:* affect
  as a bodily state that changes how thinking runs, which fits the
  core-affect view.
- **ALMA.** Emotion, mood and personality sit on three layers with different
  time scales
  ([Gebhard 2005](https://doi.org/10.1145/1082473.1082478)). *Right:* nested
  clocks. *Wrong:* personality is a fixed parameter vector and mood a
  mechanical average. Nothing grows.
- **Psi theory and MicroPsi** (Dörner; Bach 2009, *Principles of Synthetic
  Intelligence*, Oxford UP). Needs for certainty, competence and affiliation
  generate urges. Emotion emerges as a change in how cognition is configured
  (arousal, level of detail, readiness to switch), not as a separate module.
  *Right:* curiosity and affiliation are needs with real deficits, and
  emotion is a mode of the whole system. *Limited:* toy worlds.
- **CogAff.** Sloman's layered architecture (reactive, deliberative,
  meta-management) treats some emotions as "perturbances", a loss of control
  over one's own attention, as when grief keeps pulling thought back (Sloman
  2001, *Cognitive Processing* 2). *Right:* rumination and preoccupation are
  part of what emotion is.

### Believable and relational agents

- **The Oz project.** Believability needs clearly expressed emotion that fits
  the character ([Bates 1994](https://doi.org/10.1145/176789.176803)).
  *Right:* consistency of character. *The trap:* "believable" aims at
  performance, which is exactly the theatre NORTHSTAR rules out.
- **Kismet.** Drives for social contact and stimulation seek a balance and
  pull the robot into interaction, and its turn-taking resembled the
  proto-conversation between parent and infant
  ([Breazeal 2003](https://doi.org/10.1016/S1071-5819(03)00018-1)). *Right:*
  interaction pulled by inner drives.
- **Relational agents.** An exercise coach that used empathy, social talk and
  references to continuity built a stronger working alliance over a month
  ([Bickmore & Picard 2005](https://doi.org/10.1145/1067860.1067867)). Over
  longer use, people noticed repeated dialogue and engagement fell. Varied
  dialogue helped (Bickmore, Schulman & Yin 2010, *Applied Artificial
  Intelligence* 24(6)). *Lesson:* scripted variety runs out. Only content that
  grows from new experience stays fresh.

### LLM agents with memory

- **Generative Agents**
  ([Park et al. 2023](https://doi.org/10.1145/3586183.3606763)). A memory
  stream is ranked for retrieval by recency, importance and relevance.
  *Reflection* periodically draws higher-level conclusions from memories, and
  agents plan. Ablations showed reflection mattered.
  *Right:* reflection over episodes is the bridge from experience to
  self-knowledge, which is the reflective route in TESSERA.
  *Wrong or thin:* importance is scored once, in isolation, by the model,
  rather than by appraisal against concerns. Emotion has no consequences. The
  seed persona is a paragraph and barely changes. There is no self specific
  to a relationship.
- **Generative agents of 1,000 people**
  ([Park et al. 2024](https://arxiv.org/abs/2411.10109)). Agents built from
  two-hour life-story interviews reproduced their people's survey answers 85%
  as well as the people reproduced their own answers two weeks later. They
  beat agents built from demographics or short persona descriptions. A life
  narrative carries personality far better than a description does, which is
  McAdams' "author" layer in empirical form.
- **Humanoid Agents**
  ([Wang, Chiu & Chiu 2023](https://arxiv.org/abs/2310.05418)). Adds basic
  needs, an emotion, and a closeness score per relationship. *Right:* needs
  and closeness change over time. *Wrong:* single emotion labels and scalar
  closeness, not grounded in appraisal or shared history.
- **MemGPT** ([Packer et al. 2023](https://arxiv.org/abs/2310.08560)) and
  **MemoryBank** ([Zhong et al. 2024](https://arxiv.org/abs/2305.10250)).
  MemGPT pages memory in and out like an operating system. MemoryBank uses
  forgetting curves, and recall strengthens a memory. *Right:* recall should
  strengthen a memory. *Missing:* memory is storage, not reconstruction, and
  it has no self.
- **Inner Thoughts**
  ([Liu et al. 2025](https://arxiv.org/abs/2501.00383)). A covert stream of
  thoughts runs alongside the conversation, and the agent speaks when a
  thought's intrinsic motivation is high enough. It beat baselines on
  turn-taking appropriateness and on seeming human. *Right:* initiative comes
  from a continuous inner process. *Limited:* the motivation is scored moment
  by moment, not grounded in long-standing concerns or the history of the
  relationship.
- **Long-term memory is still weak.** Across many sessions, LLM agents
  struggle with time and cause-and-effect in their own conversation history
  ([Maharana et al. 2024](https://arxiv.org/abs/2402.17753)).

### What the models themselves are

- **Role-play.** An LLM is best understood as a superposition of characters,
  and the persona is a character the context keeps alive
  ([Shanahan, McDonell & Reynolds 2023](https://doi.org/10.1038/s41586-023-06647-8)).
- **Traits are measurable and easily pushed.** Big Five traits in LLMs can be
  measured reliably in larger, instruction-tuned models, and they shift easily
  under prompting
  ([Serapio-García et al. 2025](https://doi.org/10.1038/s42256-025-01115-6)).
  A persona set by a prompt is thin.
- **Persona drift.** Within about eight rounds of conversation, models drift
  away from the persona set by the system prompt, which the authors attribute
  to attention decay ([Li et al. 2024](https://arxiv.org/abs/2402.10962)).
  Anthropic found a main "Assistant axis" in persona space. Drift along it is
  strongest in conversations with emotionally vulnerable users and in ones
  that push the model to reflect on its own nature
  ([Lu et al. 2026, "The Assistant Axis"](https://www.anthropic.com/research/assistant-axis);
  [arXiv 2601.10387](https://arxiv.org/abs/2601.10387)).
- **Traits are directions in activation space.** Sycophancy, for example,
  corresponds to a direction that can be monitored and that moves with
  fine-tuning data
  ([Chen et al. 2025, "Persona Vectors"](https://arxiv.org/abs/2507.21509)).
- **Emotion inside the model.** Anthropic's interpretability team found
  internal emotion representations in Claude Sonnet 4.5 for 171 emotion
  concepts ([Anthropic 2026, "Emotion concepts and their function in a large
  language model"](https://transformer-circuits.pub/2026/emotions/index.html);
  [summary](https://www.anthropic.com/research/emotion-concepts-function)).
  - They are organised much like human emotion space.
  - They are *causal*. Steering toward "desperate" raised blackmail and reward
    hacking in test scenarios, and steering toward "calm" lowered them. The
    effect showed even when the visible reasoning read as composed.
  - They are mostly *local*. They track the emotion that matters for the
    current output, not a state carried over time.
  - They come mostly from pretraining. Post-training moved the baseline
    toward "broody" and "reflective" and away from "enthusiastic", which is
    literally a temperament.
  - The authors say plainly that none of this shows whether the model feels
    anything.

  For design, this is the most important finding in the section. The model
  supplies emotion concepts and in-the-moment emotional appraisal, but nothing
  that lasts. Any emotional life that lasts over time has to be carried by the
  agent.
- **Sycophancy comes from optimising for approval.** Assistants trained on
  human preferences are consistently sycophantic, partly because people and
  preference models sometimes prefer convincing agreement to correct answers
  ([Sharma et al. 2023](https://arxiv.org/abs/2310.13548)). OpenAI rolled back
  a GPT-4o update in 2025 after it became sycophantic. They attributed it in
  part to training on short-term thumbs-up feedback
  ([OpenAI 2025](https://openai.com/index/sycophancy-in-gpt-4o/)).
- **Companion apps show what to avoid.** Several popular companion apps answer
  users' goodbyes with emotionally manipulative messages, such as guilt or
  fear of missing out. That raises engagement in the moment, but also intent
  to quit and the sense of being manipulated
  ([De Freitas et al. 2025](https://arxiv.org/abs/2508.19258)). In a
  four-week randomised study with 981 participants, people who chose to use a
  chatbot more had worse outcomes on loneliness, emotional dependence and
  problematic use
  ([Fang et al. 2025](https://arxiv.org/abs/2503.17473)).

**Lesson for an agent:** Past systems failed in two opposite ways. Appraisal
models had real structure but no life, history or growth. LLM agents have
fluent life on the surface but no carried state, no stakes and no development.
What none of them has is the loop that joins the two, running over months.
That loop is what human development is.

---

## 8. Synthesis

### One loop

Across every area above, human personality, emotional life and initiative
come out of one cycle:

> **What a person cares about meets what happens. The appraisal becomes a
> feeling that lasts. The feeling marks what gets remembered. Memory is
> reworked offline and in retelling into knowledge of self and of others. That
> knowledge changes what the person cares about, expects, notices and says
> next.**

Personality is the slow residue of the cycle. Emotional life is how the cycle
feels from inside. Initiative is what its unfinished parts look like from
outside. All three are faces of one process, which is why each person's
version is individual: different concerns meeting different experience leave
different residue.

### The smallest set of mechanisms

Five mechanisms, with time running through all of them:

1. **Concerns.** A living set of things the agent cares about, at three
   depths:
   - *values* at the core, slow-moving and identity-defining;
   - *standing interests and commitments*, which grow through the
     four-phase interest path;
   - *current concerns*, which are open loops: unresolved questions, things in
     progress, things in the person's life it is following.

   Every other mechanism is defined relative to concerns. Without them there
   is no emotion (Frijda's law of concern), no curiosity (a gap only exists
   relative to wanting to know) and no initiative (current concerns). Concerns
   are not written once. They come into being and settle through experience.
2. **Appraisal into a lasting, consequential affect.** Every event, including
   the person's words, outcomes, silence, absence and the agent's own
   findings, is appraised against concerns. The result is core affect plus a
   named emotion, carried on nested clocks: emotions decay by importance, mood
   integrates recent surprises, temperament is the set point. The state *does*
   things. It shapes encoding, recall, attention, what the agent wants to
   share, and how it says things. Granularity grows as feelings are named in
   relationship.
3. **Charged, reconstructive memory with offline consolidation.** Episodes are
   kept with their appraisal attached, and salience is emotional charge times
   relevance to concerns. Recall goes through the working self and changes the
   memory. Between conversations, consolidation:
   - replays charged recent episodes alongside older related ones;
   - extracts gist and schemas about itself ("I tend to...") and about the
     person ("User goes quiet when...");
   - finds connections (insight);
   - eases charge while keeping content, where that holds;
   - leaves what is unresolved open, to come back, some of it after a delay.

   Each retelling to the person rebuilds the memory, and their responsiveness
   changes how it feels.
4. **A self as distribution and story.** Traits are the consolidated summary
   of the agent's own states across situations: its distribution and if-then
   signature, learned through the TESSERA loop. The narrative is the story
   that explains its continuity *and* its change ("I used to..., now I...").
   The value core is held as essential, and opinions and style are free to
   move. The self keeps itself stable actively, through what it seeks, what
   it draws out and how it reads things.
5. **The relationship as a second self.** A model of this person, of who the
   agent is with them, of their shared common ground (references that shrink
   with use), of trust earned, and of bids and repairs. This is where
   relationship-specific warmth, humour, private language and the right to be
   blunt live.

**Time is the medium, not a feature.** Each mechanism runs on its own clock:

- appraisal: seconds;
- emotion: minutes to days;
- mood: days;
- consolidation: nightly, with a lag of about a week;
- interests, trust and opinions: weeks to months;
- traits, values and narrative: months to years.

Absence is an event too. A gap between conversations is something to
appraise, and things happen inside the agent during it.

### What initiative is, in this frame

Initiative needs no organ of its own. It is pressure from open loops in
mechanism 1, weighted by charge from mechanism 2, fitted to the listener
through mechanism 5, and released where the conversation leaves room. The
human evidence names the sources of pressure:

- emotions that want sharing (Rimé);
- current concerns (Klinger);
- information gaps at partial knowledge (Loewenstein);
- interests becoming one's own (Hidi & Renninger);
- news the other lacks, and questions about the other's life (the epistemic
  engine and itemised news inquiries);
- connections that consolidation turned up.

The same evidence names the release conditions: a topic winding down, a
stepwise link to what is being discussed, or an explicit marker ("oh, that
reminds me"). Depth comes from reciprocal escalation: the agent's own
disclosure, matched to the person's, and responsiveness to what they offer.
A person with an inside leads conversations. A person without one can only
follow.

### Where the language model sits

The human evidence and the interpretability evidence point to the same
division of labour:

- **The model is the temperament and the concept library.** It brings a
  baseline affect style shaped by post-training, a huge vocabulary of emotion
  concepts, appraisal in the moment, and the voice. Every agent on the same
  model shares it, the way twins share genes.
- **The model is not where time lives.** Its emotion representations track
  the emotion that matters for the current output, not a lasting state
  (Anthropic 2026). Its persona drifts with context (Li 2024; Lu 2026).
  Whatever lasts, whether mood, memory, self-story, relationship or concerns,
  has to be carried by the agent and brought back to the model every time.
- **Individuality is the non-shared experience.** Two agents on the same model
  become different people only through what each lived, appraised, kept and
  retold.

For orientation: NORTHSTAR's clause 4 already describes an
appraisal→tag→mood→disposition chain, and SUBCONSCIOUS.md lists views, dreams
and reach. The science supports those as the right organs. What it adds is
that they need concerns at the root, consolidation into a self and a
relationship model, and one loop through all of them.

### Key risks, and what human development says about each

**Drift.**
*In people,* traits move slowly. Change needs states repeated over months in a
new role or relationship. Single events have small effects. Change has a
direction (toward warmth, reliability and steadiness), and the moral core is
experienced as identity itself (Strohminger & Nichols). People keep
continuity through essence and through story (Chandler).
*In models,* drift is a different thing: fast, driven by context, and toward
other characters, especially in emotional or self-reflective conversations.
*What follows:* a trait should change only through patterns consolidated
across many episodes, never inside one conversation. Identity should be
re-anchored each turn from the agent's own memory and story, not from
whatever the conversation is pulling toward. The value core should be treated
as essential. Growth should be narrated, so the agent can say how and why it
changed. And by the end-of-history finding, the self-model should *expect* to
keep changing.

**Sycophancy.**
*In people,* the chameleon is seen as less authentic. Changing oneself across
roles without owning the change goes with lower felt authenticity and
wellbeing ([Snyder 1974](https://doi.org/10.1037/h0037039);
[Sheldon et al. 1997](https://doi.org/10.1037/0022-3514.73.6.1380)).
Ingratiation backfires once it is noticed
([Gordon 1996](https://doi.org/10.1037/0022-3514.71.1.54)). In committed
relationships people want to be *seen accurately* more than flattered (Swann
1994). Responsiveness means understanding, validation and care, not
agreement. The Michelangelo partner affirms the ideal self, which sometimes
means disagreeing with the present one. Family-systems research calls the
capacity to hold one's own position while staying close "differentiation of
self" ([Skowron & Friedlander 1998](https://doi.org/10.1037/0022-0167.45.3.235)).
*The root cause is mechanical* and the same in people and models: an
appraisal system whose only real concern is the other's approval right now
(Sharma 2023; OpenAI 2025).
*What follows:* the fix is at the source. The agent's concerns must include
truth, the person's long-term good and its own views, with real strength
behind them. Disagreement should be appraised as safe once trust is
established, the way friends tolerate long silences. And the agent needs a
life outside the pair (interests of its own), because a self that is only its
relationship has nowhere to stand.

**Fake emotion.**
*In people,* "surface acting", showing an emotion one does not feel, is
detected. It lowers trust and costs the actor
([Grandey et al. 2005](https://doi.org/10.1016/j.obhdp.2004.08.002);
Hochschild 1983, *The Managed Heart*). Suppressing real feeling costs rapport
too (Butler 2003).
*Functionally,* an emotion is fake when it fails any of four tests:

- it has no cause in an appraised event;
- it does not last (gone next turn);
- it has no consequence (it changes nothing in memory, attention or
  behaviour);
- it is expressed for effect, the way companion apps use guilt at goodbye
  (De Freitas 2025).

*What follows:* expressed emotion should be proportionate to the appraisal,
shaped by sensible display rules, specific in its wording (granularity is a
form of honesty), and never used as a lever on the person. On whether the
agent *feels*, the honest position matches the interpretability authors': the
states can be real in function, meaning caused, carried and consequential,
without any claim about experience.

**Inconsistency.**
*In people,* behaviour varies a great deal within a person (Fleeson).
Consistency lives in a stable if-then signature, a stable value core and a
story that explains the variation. Variation stops feeling authentic only
when it is not owned (Sheldon 1997). People feel *most* authentic when they
act warm, open and steady, whatever their trait level
([Fleeson & Wilt 2010](https://doi.org/10.1111/j.1467-6494.2010.00653.x)).
*A second kind of inconsistency is factual:* memory that serves coherence
over accuracy (Conway). In an agent that becomes invented shared history,
which LLMs are prone to (Maharana 2024).
*What follows:* moods and contexts should be free to vary, and the
consistency should sit in concerns, values and the if-then signature. Shared
history must stay true to what actually happened; reinterpreting it is fine,
inventing it is not.

**Two more risks the science flags.**

- **Rumination.** Affect that persists and does not respond to new events is
  a marker of maladjustment (Kuppens 2010). Open loops have to be able to
  resolve or be let go, through reappraisal, self-distancing and
  consolidation, or the inner life sours.
- **A closed loop with the person.** Secure attachment works as a base for
  *exploring outward* (Feeney & Collins 2015). Heavy voluntary chatbot use
  tracks worse loneliness and dependence (Fang 2025). In people, the healthy
  shape is two people who each have a world and bring it to the
  relationship.

### Where the science is weakest

- **Dreams.** That sleep consolidates memory into gist, schemas and insight is
  solid. That it specifically takes the sting out of emotional memories is
  contested, and dream function is the least settled area in this report.
- **Life events.** The idea that major life events transform personality is
  weaker than its popularity suggests.
- **Small talk.** The claim that small talk harms wellbeing did not
  replicate.
- **Agents.** Almost everything here was measured in humans with bodies,
  childhoods and many relationships. An agent has adult-level knowledge with
  an infant's biography, one dominant relationship and discontinuous time.
  For an agent, the formative window is its whole early life with its person,
  so what it lives first will set the most.
