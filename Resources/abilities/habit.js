/* NativeAgent ability
{"id":"habit","kind":"tool","version":1,
 "reach":{"capabilities":["model"],"readPaths":[],"hosts":[],"apps":[]},
 "record":{"name":"habit","description":"Notice repeated hand-done sequences and draft a skill once.",
   "actions":["trace.recent","skill.list","skill.read","skill.save","home.arrive"],"inputSchema":{"type":"object"}},
 "wake":["turn.ended"],"resident":true,"face":{"page":"skills"}}
*/
function run(input) {
  if (input.signal !== "turn.ended") return {noticed: false};
  var state = host.state.get() || {};
  // The day's calls, across turns: a habit is a run she repeats, inside one
  // turn or across several, not a whole turn done twice.
  if (state.day !== input.trace) { state.day = input.trace; state.calls = []; }
  state.turns = state.turns || []; state.offered = state.offered || [];
  delete state.recent;
  if (state.turns.indexOf(input.turn_id) >= 0) return {noticed: false};
  var rows = [], query = {view: "shapes", turn_id: input.turn_id, trace: input.trace, limit: 50};
  do {
    var page = app.trace.recent(query);
    if (page.status === "failed") throw new Error("Habit needs the complete turn's call shapes.");
    if (page.scan_truncated) return {noticed: false, incomplete: true};
    rows = rows.concat(page.traces);
    query = page.next_call ? page.next_call.input.args : null;
  } while (query);
  // Trace pages are newest first, including ties; reverse once for call order.
  // Looking is not doing: discovery, page reads and looks are how she finds the
  // action, not the habit; and a call that did not land was not done.
  var calls = rows.reverse().filter(function (row) {
    return row.landed !== false && !/^(app\.)?(find|read|home|page|index)(\.|$)|\.(look|screenshot)$/.test(String(row.action || ""));
  }).map(step);
  state.turns = state.turns.concat([input.turn_id]).slice(-32);
  state.calls = state.calls.concat(calls).slice(-200);
  // Once a day at most, once ever for the same run, never for a run one of her
  // parts already does, and never for one her day's calls would show by chance.
  var habit = null, signature = null, scripts = null, most = null;
  if (state.noticed !== state.day) {
    repeated(state.calls).some(function (run) {
      if (most === null) most = chance(state.calls);
      if (run.times * run.steps.length <= most) return true;
      signature = fingerprint(JSON.stringify(run.steps));
      if (state.offered.indexOf(signature) >= 0) return false;
      scripts = scripts || covering();
      var ids = run.steps.map(action);
      if (scripts.some(function (has) { return ids.every(function (id) { return has.indexOf(id) >= 0; }); })) return false;
      habit = run;
      return true;
    });
  }
  // A skill she runs and then, by hand, usually follows with the same calls: it could take them in.
  var follow = followed(state.calls).filter(function (next) {
    return state.offered.indexOf(fingerprint("follow" + JSON.stringify(next))) < 0;
  })[0];
  while (state.calls.length && bytes(state) > 15000) state.calls.shift();
  if (bytes(state) > 15000) throw new Error("Habit's state is full; preserve offered signatures before making room.");
  if (follow) {
    app.home.arrive({line: follow.skill + " is usually followed by " + follow.steps.map(action).join(" → ") + "; revise its run(input)?"});
    state.offered.push(fingerprint("follow" + JSON.stringify(follow)));
  }
  host.state.set(state);
  if (!habit) return {noticed: !!follow};
  var sequence = habit.steps.map(function (token) {
    var open = token.lastIndexOf("("), ran = /^skill\.(?:run|resume):([^(!]+)/.exec(token), call = {action: action(token)};
    if (ran) call.skill = ran[1];
    call.args = open < 0 ? [] : token.slice(open + 1, token.lastIndexOf(")")).split(",");
    return call;
  });
  var draft = host.model.call({purpose: "habit",
    prompt: "The same hand-done run of app calls recurred " + habit.times + " times today. Draft a reusable skill. " +
      "You have only ordered action ids and argument names, never values or the person's words. " +
      "Return a short unique name, a one-line description of the work, params, and source. " +
      "Source must define synchronous function run(input), perform these exact app calls in order via " +
      "named methods such as app.files.list({path: input.folder}), never app.call, and return the results. " +
      "Use a distinct input param for each unknown argument occurrence; the names cannot tell which values were equal. " +
      "params maps their names to string, int, number, bool, list or object (optional types end in ?). " +
      "Do not invent values, add calls, enable anything, or use a model. Run: " + JSON.stringify(sequence),
    schema: {type: "object", required: ["name", "description", "params", "source"], properties: {
      name: {type: "string"}, description: {type: "string"}, params: {type: "object"}, source: {type: "string"}
    }, additionalProperties: false}});
  var name = draft.name, collision = 0;
  while (true) {
    try {
      app.skill.save({name: name, create_only: true, description: draft.description,
        script: {source: draft.source, params: draft.params,
          actions: sequence.map(function (call) { return call.action; }).filter(function (id, n, ids) { return ids.indexOf(id) === n; })}});
      break;
    } catch (error) {
      if (error.reason !== "name_exists" || error.stopped) throw error;
      name = draft.name.slice(0, 32) + "-" + signature + (collision ? "-" + collision : "");
      collision++;
    }
  }
  var line = "I noticed you did " + draft.description + " " + habit.times + " times today; I drafted a skill '" + name + "' — keep it?";
  app.home.arrive({line: line});
  state.offered.push(signature); state.noticed = state.day;
  host.state.set(state);
  return {noticed: true, line: line};
}

// A call as a step of a run: its action and argument names, never values,
// which vary from one time to the next; a skill run names its skill, and a
// landed write is marked with "!".
function step(row) {
  var args = row.args && typeof row.args === "object" && !Array.isArray(row.args) ? Object.keys(row.args).sort() : [];
  var name = row.skill ? row.action + ":" + row.skill : String(row.action);
  return (args.length ? name + "(" + args.join(",") + ")" : name) + (row.wrote ? "!" : "");
}

function action(token) { return token.replace(/[:(!].*$/, ""); }

// Each skill whose runs were followed, three times, by the same one to three
// calls with a write among them, and the longest such head.
function followed(calls) {
  var heads = {}, found = [];
  calls.forEach(function (token, n) {
    var ran = /^skill\.(?:run|resume):([^(!]+)/.exec(token);
    if (!ran) return;
    var next = [];
    for (var k = n + 1; k < calls.length && next.length < 3 && !/^skill\.(run|resume)[:(!]/.test(calls[k]); k++) next.push(calls[k]);
    (heads[ran[1]] = heads[ran[1]] || []).push(next);
  });
  Object.keys(heads).forEach(function (skill) {
    for (var length = 3; length >= 1; length--) {
      var counts = {};
      heads[skill].forEach(function (next) {
        if (next.length >= length) { var key = JSON.stringify(next.slice(0, length)); counts[key] = (counts[key] || 0) + 1; }
      });
      var usual = Object.keys(counts).map(JSON.parse).filter(function (head) {
        return counts[JSON.stringify(head)] >= 3 && head.some(function (token) { return /!$/.test(token); });
      })[0];
      if (usual) return found.push({skill: skill, steps: usual});
    }
  });
  return found;
}

// The action sets of her parts' scripts that are on or drafted, read the way
// she reads them; a guidance skill (no script) covers nothing.
function covering() {
  return (app.skill.list({}).result || []).filter(function (skill) { return skill.signature; }).map(function (skill) {
    var read = app.skill.read({name: skill.name});
    return ["active", "installed", "draft"].indexOf(String(read.skill_status).toLowerCase()) >= 0 ? (read.script || {}).actions || [] : [];
  });
}

// Her runs, the most of her day first: each done by hand at least three times,
// at least three calls long, with a write among them (looking is not a
// routine), and not one call repeated, which is no workflow.
function repeated(calls) {
  var found = [];
  // A run done three times holds a shorter one done three times, so the first
  // length with none ends the search.
  for (var length = 3, more = true; more && length * 3 <= calls.length; length++) {
    var runs = {};
    more = false;
    for (var i = 0; i + length <= calls.length; i++) {
      var key = JSON.stringify(calls.slice(i, i + length));
      var seen = runs[key] || (runs[key] = {steps: calls.slice(i, i + length), times: 0, next: 0});
      if (i >= seen.next) { seen.times++; seen.next = i + length; }
    }
    for (key in runs) {
      var each = runs[key];
      if (each.times < 3) continue;
      more = true;
      if (new Set(each.steps).size >= 2 && each.steps.some(function (s) { return /!$/.test(s); })) found.push(each);
    }
  }
  return found.sort(function (a, b) { return b.times * b.steps.length - a.times * a.steps.length || b.steps.length - a.steps.length; });
}

// The most calls any run covers in the same calls shuffled, nineteen times:
// a run that beats every shuffle is not chance at about one in twenty, and
// the bar is her own day's mix of calls, not a number picked here.
function chance(calls) {
  var most = 0, seed = parseInt(fingerprint(JSON.stringify(calls)).slice(0, 7), 16) || 1;
  for (var n = 0; n < 19; n++) {
    var shuffled = calls.slice();
    for (var i = shuffled.length - 1; i > 0; i--) {
      seed = seed * 48271 % 2147483647;
      var j = seed % (i + 1), held = shuffled[i];
      shuffled[i] = shuffled[j]; shuffled[j] = held;
    }
    var best = repeated(shuffled)[0];
    if (best) most = Math.max(most, best.times * best.steps.length);
  }
  return most;
}

// Fixed-size fingerprints leave the notebook for memories, not copies of shapes.
function fingerprint(text) {
  var hash = 0x6c62272e07bb014262b821756295c58dn;
  for (var i = 0; i < text.length; i++) hash = BigInt.asUintN(128, (hash ^ BigInt(text.charCodeAt(i))) * 0x1000000000000000000013bn);
  return hash.toString(16).padStart(32, "0");
}

function bytes(value) { return encodeURIComponent(JSON.stringify(value)).replace(/%[0-9A-F]{2}/g, "_").length; }
