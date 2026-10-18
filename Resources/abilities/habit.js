/* NativeAgent ability
{"id":"habit","kind":"tool","version":1,
 "reach":{"capabilities":["model"],"readPaths":[],"hosts":[],"apps":[]},
 "record":{"name":"habit","description":"Notice repeated hand-done sequences and draft a skill once.",
   "actions":["trace.recent","skill.save","home.arrive"],"inputSchema":{"type":"object"}},
 "wake":["turn.ended"],"resident":true,"face":{"page":"skills"}}
*/
function run(input) {
  if (input.signal !== "turn.ended") return {noticed: false};
  var state = host.state.get() || {recent: [], offered: []};
  if (state.recent.some(function (turn) { return turn.id === input.turn_id; })) return {noticed: false};
  var rows = [], query = {view: "shapes", turn_id: input.turn_id, trace: input.trace, limit: 50};
  do {
    var page = app.trace.recent(query);
    if (page.status === "failed") throw new Error("Habit needs the complete turn's call shapes.");
    if (page.scan_truncated) return {noticed: false, incomplete: true};
    rows = rows.concat(page.traces);
    query = page.next_call ? page.next_call.input.args : null;
  } while (query);
  // Trace pages are newest first, including ties; reverse once for call order.
  // Looking is not doing: discovery and page reads are how she finds the action, not the habit.
  var sequence = rows.reverse().filter(function (row) {
    return !/^(app\.)?(find|read|home|page|index)(\.|$)/.test(String(row.action || ""));
  }).map(function (row) { return {action: row.action, args: ordered(row.args)}; });
  // A habit is the same sequence of actions; the arguments vary from day to
  // day, so they shape the draft but never the match.
  var shape = JSON.stringify(sequence);
  var signature = sequence.length >= 2 ? fingerprint(JSON.stringify(sequence.map(function (step) { return step.action; }))) : null;
  var repeated = signature && state.recent.some(function (turn) { return turn.signature === signature; });
  var offer = repeated && state.offered.indexOf(signature) < 0;
  state.recent.push({id: input.turn_id, signature: signature});
  state.recent = state.recent.slice(-32);
  // Remember before thinking: a failed draft or a dropped proposal never spends again.
  if (offer) state.offered.push(signature);
  while (state.recent.length > 1 && bytes(state) > 15000) state.recent.shift();
  if (bytes(state) > 15000) throw new Error("Habit's state is full; preserve offered signatures before making room.");
  host.state.set(state);
  if (!offer) return {noticed: false};
  var draft = host.model.call({purpose: "habit",
    prompt: "The same hand-done app sequence occurred in two turns. Draft a reusable skill. " +
      "You have only ordered action ids and argument shapes, never values or the person's words. " +
      "Return a short unique name, a one-line description of the work, params, and source. " +
      "Source must define synchronous function run(input), perform these exact app calls in order via " +
      "named methods such as app.files.list({path: input.folder}), never app.call, and return the results. " +
      "Use a distinct input param for each unknown argument occurrence; the shapes cannot tell which values were equal. " +
      "params maps their names to string, int, number, bool, list or object (optional types end in ?). " +
      "Do not invent values, add calls, enable anything, or use a model. Sequence: " + shape,
    schema: {type: "object", required: ["name", "description", "params", "source"], properties: {
      name: {type: "string"}, description: {type: "string"}, params: {type: "object"}, source: {type: "string"}
    }, additionalProperties: false}});
  var name = draft.name, collision = 0;
  while (true) {
    try {
      app.skill.save({name: name, create_only: true, description: draft.description,
        script: {source: draft.source, params: draft.params,
          actions: sequence.map(function (step) { return step.action; }).filter(function (id, n, ids) { return ids.indexOf(id) === n; })}});
      break;
    } catch (error) {
      if (error.reason !== "name_exists" || error.stopped) throw error;
      name = draft.name.slice(0, 32) + "-" + signature + (collision ? "-" + collision : "");
      collision++;
    }
  }
  var line = "I noticed you did " + draft.description + " twice; I drafted a skill '" + name + "' — keep it?";
  app.home.arrive({line: line});
  return {noticed: true, line: line};
}

function ordered(value) {
  if (Array.isArray(value)) return value.map(ordered).sort(function (a, b) { return JSON.stringify(a).localeCompare(JSON.stringify(b)); });
  if (value && typeof value === "object") return Object.keys(value).sort().reduce(function (out, key) { out[key] = ordered(value[key]); return out; }, {});
  return value;
}

// Fixed-size fingerprints leave the notebook for memories, not copies of shapes.
function fingerprint(text) {
  var hash = 0x6c62272e07bb014262b821756295c58dn;
  for (var i = 0; i < text.length; i++) hash = BigInt.asUintN(128, (hash ^ BigInt(text.charCodeAt(i))) * 0x1000000000000000000013bn);
  return hash.toString(16).padStart(32, "0");
}

function bytes(value) { return encodeURIComponent(JSON.stringify(value)).replace(/%[0-9A-F]{2}/g, "_").length; }
