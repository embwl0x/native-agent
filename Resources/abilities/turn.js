/* NativeAgent ability
{"id": "turn", "kind": "turn", "version": 3,
 "reach": {"capabilities": ["model"], "readPaths": [], "hosts": [], "apps": []},
 "wake": [], "face": {}, "resident": false, "learned": {}, "choices": {}}
*/
// Her turn. The stem hands step one event at a time (message, model, result,
// observation, resumed) and runs the effects it returns (model.call, app,
// reply.stream, reply.end, after). The stem owns the loop, the stream, the
// gates and the guarantee that a turn ends; this decides what she thinks with
// and what happens next.
function step(state, event) {
  switch (event.type) {
    case "message":
      var persona = turn.persona(), context = turn.context();
      return next({purpose: "turn", calls: 0}, [{effect: "model.call", purpose: "turn", tools: context.tools,
        system: {stable: stable(persona, turn.pins()), dynamic: dynamic(context, turn.recall())}}]);
    case "model":
      if (!event.calls.length) return next(state, [{effect: "reply.end"}, {effect: "after"}]);
      return next({purpose: state.purpose, calls: event.calls.length},
        event.calls.map(function (call) { return {effect: "app", call: call}; }));
    case "result":
      var left = state.calls - 1;
      return next({purpose: "tool_round", calls: left}, left ? [] : [{effect: "model.call", purpose: "tool_round"}]);
    case "observation":
      return next({purpose: state.purpose, calls: state.calls}, [{effect: "model.call", purpose: state.purpose}]);
    case "provider_failure":
      // Nothing ran and nothing is owed: ask once more under the stem's notice; the same cut again is hers to say.
      if ((event.work === "nothing ran" || event.work === "not sent") && !event.owed && !state.recalled)
        return next({purpose: state.purpose, calls: state.calls, recalled: true}, [{effect: "model.call", purpose: state.purpose}]);
      return next(state, [{effect: "reply.stream", text: event.text}, {effect: "reply.end"}]);
    case "resumed":
      var purpose = event.steps ? "tool_round" : state.purpose;
      return next({purpose: purpose, calls: 0}, [{effect: "model.call", purpose: purpose}]);
  }
  throw new Error("Unknown turn event: " + event.type);
}

function next(state, effects) { return {state: state, do: effects}; }

// Who she is, then how she speaks, then the REM pins her documents don't already say.
function stable(persona, pins) {
  var lines = persona.prompt ? [persona.prompt, persona.guidance] : [persona.guidance];
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
  if (context.digest) text = text ? context.digest + "\n\n" + text : context.digest;
  if (context.history) text = text ? text + "\n\n" + context.history : context.history;
  context.facts.forEach(function (fact) { text = text.trim() ? text + "\n\n" + fact : fact; });
  return text;
}
