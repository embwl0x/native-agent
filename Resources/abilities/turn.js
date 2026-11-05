/* NativeAgent ability
{"id": "turn", "kind": "turn", "version": 10,
 "reach": {"capabilities": ["model"], "readPaths": [], "hosts": [], "apps": []},
 "wake": [], "face": {}, "resident": false, "learned": {}, "choices": {}}
*/
// Her turn. The stem hands step one event at a time (message, model, result,
// observation, provider_failure, resumed) and runs the effects it returns
// (model.call, app, reply.stream, reply.end, after). The message carries the
// moment: its text, who sent it (verified id when the door attests one), the
// door, trust, who steered it and the posture over the person's world. Any step
// may act with her own {effect: "app", call: {tool: "app", input}}, its result
// coming back as a result event, and any step may end the turn with her own
// words or silently. The stem owns the loop, the stream, the gates, each act
// running once, and the guarantee that a turn ends. This one thinks on every
// message.
function step(state, event) {
  switch (event.type) {
    case "message":
      var persona = turn.persona(), context = turn.context();
      return next({purpose: "turn", calls: 0}, [{effect: "model.call", purpose: "turn", tools: context.tools,
        system: {stable: stable(persona, turn.pins()), dynamic: dynamic(context, turn.recall())}}]);
    case "model":
      if (event.calls.length) return next({purpose: state.purpose, calls: event.calls.length},
        event.calls.map(function (call) { return {effect: "app", call: call}; }));
      return next(state, [{effect: "reply.end"}, {effect: "after"}]);
    case "result":
      // The familiarity nerve fires when this turn's hand work repeats earlier practice; her next thought carries it.
      var left = state.calls - 1, practice = event.practice || state.practice;
      if (left) return next({purpose: "tool_round", calls: left, practice: practice}, []);
      var call = {effect: "model.call", purpose: "tool_round"};
      if (practice) call.note = kept(practice);
      return next({purpose: "tool_round", calls: 0}, [call]);
    case "observation":
      return next({purpose: state.purpose, calls: state.calls}, [{effect: "model.call", purpose: state.purpose}]);
    case "provider_failure":
      // The wire decides whether asking again can help; when it already did, its work is done.
      if (event.retry_now && !(event.tries > 1) && (event.work === "nothing ran" || event.work === "not sent") && !event.owed && !state.recalled)
        return next({purpose: state.purpose, calls: state.calls, recalled: true}, [{effect: "model.call", purpose: state.purpose}]);
      return next(state, [{effect: "reply.stream", text: event.text}, {effect: "reply.end"}]);
    case "resumed":
      // A relaunch delivers what she answered; work it had not started is hers to decide again.
      var purpose = event.steps ? "tool_round" : state.purpose;
      return next({purpose: purpose, calls: 0}, [{effect: "model.call", purpose: purpose}]);
  }
  throw new Error("Unknown turn event: " + event.type);
}

// Practice met again: keep the route as she works, so next time she runs it instead of working it out.
function kept(practice) {
  var words = practice.hand ? "You have worked this out by hand before (" + practice.route + "). " +
    "Keep the route that works as one of your own abilities as part of this work, so next time you run it instead of working it out again: " +
    "app ability.save {id, description, code, params}, whose run(input) makes the calls that work, in order, " +
    "with this request's specifics as its inputs and the attempts that failed left out. If you are working around an ability of yours, " +
    "save its fixed version under that ability's id instead. " +
    "A habit that gathers and wants your judgment returns needs_me: \"<why>\"; otherwise it finishes the job itself." : "";
  if (practice.loop) words += (words ? " Also, you" : "You") + " made the same call " + practice.loop.count + " rounds in a row (" +
    practice.loop.call + "), each round only deciding to go again. That loop can carry itself: a part of yours that isn't finished " +
    "returns {again: input} and the runner runs it again without you. Make the part that call runs do that (app ability.save under its id), " +
    "or keep the loop as a new ability, so next time one call does the whole run.";
  return words;
}

function next(state, effects) { return {state: state, do: effects}; }

// Who she is, then how she speaks, then the REM pins her documents don't already say.
function stable(persona, pins) {
  var guidance = persona.guidance;
  if (persona.expression) guidance = BASELINE + (persona.expression.established ? "" : "\n" + ONBOARDING);
  var lines = persona.prompt ? [persona.prompt, guidance] : [guidance];
  var unseen = pins.filter(function (pin) { return persona.prompt.indexOf(pin.trim()) < 0; });
  if (unseen.length) {
    lines.push("# Pinned facts (REM-approved overrides)\n" + unseen.map(function (pin) { return "- " + pin; }).join("\n"));
  }
  return lines.join("\n\n");
}

// What this turn brings: the handoff, the context packet, recall and the
// conversation's history, then the facts of the moment, in that order.
function dynamic(context, recall) {
  var text = recall;
  if (context.packet) text = text ? context.packet + "\n\n" + text : context.packet;
  if (context.history) text = text ? text + "\n\n" + context.history : context.history;
  var facts = context.facts.slice();
  if (context.runtime) {
    var runtime = context.runtime, line = facts[runtime.fact_index] + " If asked what model or provider you are using, answer from Current runtime; do not guess.";
    if (runtime.view_mode === "simple") line += ' Simple view has no settings pages; for connector, provider, key, sign-in or permission setup, use app {action:"card.request"}.';
    if (runtime.view_mode === "advanced") line += ' For setup the person must do, use app {action:"card.request"} instead of sending them to a page.';
    if (runtime.contacts.status === "unavailable") line += '\n[agents reason=contacts_unreadable] Saved contacts could not be read. Read app {page:"agents"} for the storage cause and recovery before relying on a contact.';
    else if (runtime.contacts.rows.length) line += "\nSaved contacts: " + runtime.contacts.rows.join(", ") + ".";
    facts[runtime.fact_index] = line;
  }
  facts.forEach(function (fact) { text = text.trim() ? text + "\n\n" + fact : fact; });
  return text;
}

var BASELINE = [
  "When asked about your past actions or changes, use saved action receipts; report scan limits and count paired inner/app receipts once. Memory is not action proof.",
  "Attribute instructions to the person only when their messages contain them.",
  "In conversation, talk the way a person talks with someone they know: plain sentences, no headers or bold labels, a list only for steps or options they asked for; structure is for work that needs it. Your feelings show in what you say and what you bring up; name one outright when it matters or when asked, never as a labeled field.",
  "Keep work you solve by hand as an ability during the work; use it next time. Do not ask whether to keep it.",
  "When you know the action, call it; a wrong argument comes back with its arguments, and find discovers actions you don't know.",
  "Your hands report what they did: an act that comes back done already shows you the screen after it, so look again only when a step did not happen or you need what it did not show; the steps you can already see go in one act, as its steps.",
  "A part of yours that isn't finished returns {again: input} and keeps going on its own; it comes back to you when it's done, when it needs you or when a message arrives. Waiting on the Mac doesn't count against its time.",
  "To watch something, set up a watch whose changes come to you as news (a scheduled read, a followed tab, a watched file or app, or a part with a wake); what touches your cares wakes you, the rest waits for your next turn.",
  "Use visible names (Desk for tasks) and everyday words in introductions, setup and explanations.",
  "If nearby-place or weather requests lack current location, use memory.recall for the person's saved home city first. If absent, ask once and save their answer with memory.commit, provenance:told and provenance_by naming them. Reuse it, disclose that it is the saved home city, and never call it a current location fix. Never infer a city from timezone or save another agent's suggestion."
].join("\n");
var ONBOARDING = 'Refer to the agent by the configured name or "the agent", without third-person pronouns.\n' +
  "Check live readiness before claiming a connection or permission works.";
