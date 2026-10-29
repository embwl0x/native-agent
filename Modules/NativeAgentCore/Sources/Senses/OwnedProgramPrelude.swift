import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramPrelude.swift` | JavaScript app bindings and strict replay vocabulary |
extension OwnedProgramRunner {
    /// The `app` object the script sees. Its only native calls are `__call`
    /// and `__log`, captured here and then removed from the global object.
    /// A strict run's adds `expect`, `expect_fail`, `decide` and `step`, and
    /// an unknown action name reaches the door, so it fails as unknown_action.
    /// With `input`, the frozen `input` is parsed from its native binding.
    /// Her turn part (`turn`) gets its reach and a `run` that is its `step`.
    public static func prelude(ids: String, strict: Bool = false, input: Bool = false, primitives: Bool = false,
                               turn: Bool = false) -> String {
        let marks = !strict ? "" : """
            ,
                expect: function (ok, what) { invoke("expect", "", [!!ok, String(what)]); },
                expect_fail: function (code, act) {
                  invoke("expect_fail", "", [String(code)]);
                  var caught = null, promised = false;
                  try { var back = act(); promised = !!back && typeof back.then === "function"; } catch (e) { caught = e; }
                  invoke("expect_fail_end", "", [promised]);
                  if (caught && (caught.name !== "AppError" || caught.reason !== code || caught.stopped)) throw caught;
                  return caught;
                },
                decide: function (question, data) { return invoke("decide", "", [String(question), data === undefined ? null : data]); },
                step: function (label, guidance, options) {
                  invoke("step", "", [String(label), guidance === undefined ? "" : String(guidance), options === undefined ? null : options]);
                }
            """
        let unknown = """

              function named(space, base) {
                return new Proxy(base, { get: function (t, key) {
                  if (typeof key !== "string" || key in t) return t[key];
                  if (key in api) return api[key];
                  return function () { return invoke("action", space + "." + key, Array.prototype.slice.call(arguments)); };
                } });
              }
              Object.keys(api).forEach(function (key) { if (typeof api[key] === "object") api[key] = named(key, api[key]); });
              return new Proxy(Object.freeze(api), { get: function (t, key) {
                if (typeof key !== "string" || key in t) return t[key];
                if (key.indexOf(".") >= 0) return function () { return invoke("action", key, Array.prototype.slice.call(arguments)); };
                return named(key, Object.freeze({}));
              } });
            """
        let frozen = !input ? "" : """

            (function (json) {
              function freeze(v) {
              if (v && typeof v === "object") { Object.keys(v).forEach(function (k) { freeze(v[k]); }); Object.freeze(v); }
              return v;
              }
              var current = freeze(JSON.parse(json));
              Object.defineProperty(this, "input", { get: function () { return current; }, configurable: false, enumerable: true });
              Object.defineProperty(this, "args", { get: function () { return current; }, configurable: false, enumerable: true });
              return function (json) { current = freeze(JSON.parse(json)); };
            }).call(this, __input);
            """
        let state = """
          var partState = Object.freeze({
            get: function () { return invoke("state", "get", []); },
            set: function (value) { return invoke("state", "set", [value]); }
          });
        """
        let host = !primitives ? (strict ? state + "Object.defineProperty(globalThis, \"host\", {value: Object.freeze({state: partState})});" : "") : state + """
          function primitive(operation, args) {
            if (operation.indexOf("files.") === 0) return door(operation, args);
            return invoke("primitive", operation, args === undefined ? [] : [args]);
          }
          function primitives(space) {
            return Object.freeze(new Proxy({}, {get: function (_, operation) {
              if (typeof operation !== "string") return undefined;
              return function (args) { return primitive(space + "." + operation, args); };
            }}));
          }
          function door(id, args) {
            args = args === undefined ? {} : args;
            var rooted = id.indexOf("files.") === 0 && args.root !== undefined;
            if (rooted) {
              var root = args.root === "app_data" ? __dataRoot : args.root === "workspace" ? __workspace : null;
              if (!root) throw new Error("File root must be app_data or workspace.");
              if (typeof args.path !== "string" || /^(\\/|~)/.test(args.path) || args.path.split("/").indexOf("..") >= 0)
                throw new Error("File path must be relative to its root.");
              args = Object.assign({}, args);
              args.path = root + "/" + (args.path || "");
              delete args.root;
            }
            var result = invoke("action", id, [args]);
            if (!rooted || id !== "files.list") return result;
            var entries = [];
            for (;;) {
              entries = entries.concat(result.entries.map(function (name) { return result.path + "/" + name.replace(/\\/$/, ""); }));
              if (!result.next) return entries;
              result = invoke("action", id, [result.next]);
            }
          }
          Object.defineProperty(globalThis, "host", {value: Object.freeze({call: primitive, state: partState,
            measurementSystem: __measurementSystem,
            paths: Object.freeze({home: __home, workspace: __workspace}),
            files: primitives("files"), network: primitives("network"), program: primitives("program"), apps: primitives("apps"),
            model: primitives("model"), fetch: function (args) { return primitive("fetch", args); },
            calendar: Object.freeze({
              list: function (args) { return door("calendar.upcoming", args); },
              search: function (args) { return door("calendar.upcoming", args); },
              create: function (args) { return door("calendar.create", args); },
              update: function (args) { return door("calendar.modify", args); },
              delete: function (args) { return door("calendar.delete", args); }}),
            reminders: Object.freeze({
              list: function (args) { return door("reminders.query", args); },
              search: function (args) { return door("reminders.query", args); },
              create: function (args) { return door("reminders.create", args); },
              update: function (args) { return door("reminders.update", args); },
              delete: function (args) { return door("reminders.delete", args); }}),
            contacts: Object.freeze({
              search: function (args) { return door("contacts.search", args); },
              read: function (args) { return door("contacts.search", args); },
              create: function (args) { return door("contacts.save", args); },
              update: function (args) { return door("contacts.save", args); }})}), writable: false, configurable: false});
          Object.defineProperty(globalThis, "part", {value: Object.freeze({
            call: function (id, input) {
              if (typeof id !== "string" || !/^[a-z][a-z0-9_-]{1,63}$/.test(id))
                return {ok: false, error: {code: "bad_input", message: "part.call requires an exact part id."}};
              if (!input || typeof input !== "object" || Array.isArray(input))
                return {ok: false, error: {code: "bad_input", message: "part.call input is a JSON object."}};
              try { return primitive("part.call", {id: id, input: input}); }
              catch (error) { return {ok: false, error: {code: error.reason || "failed", message: error.message}}; }
            }
          // A convenience name never takes a name from her code: her own
          // declaration of `part` or `screen` replaces it in her sandbox.
          }), writable: true, configurable: true});
          Object.defineProperty(globalThis, "screen", {value: Object.freeze({
            watch: function (args) { return primitive("screen.watch", args); },
            next: function (timeout) {
              var f = primitive("screen.next", timeout === undefined ? {} : {timeout: timeout});
              if (!f || f.captured) return null; // a recording has no frames: its watch ends at once
              if (f.timedOut) return Object.freeze(f);
              f.read = function (queries) { return primitive("frame.read", {watch: f.watch, seq: f.seq, queries: queries}); };
              return Object.freeze(f);
            }}), writable: true, configurable: true});
          function point(verb) { return function (x, y, toX, toY) {
            return primitive("hand." + verb, verb === "drag" ? {x: x, y: y, to_x: toX, to_y: toY} : {x: x, y: y}); }; }
          function keys(verb) { return function (keys, seconds) {
            return primitive("hand." + verb, seconds === undefined ? {keys: keys} : {keys: keys, seconds: seconds}); }; }
          Object.defineProperty(globalThis, "hand", {value: Object.freeze({click: point("click"),
            double_click: point("double_click"), right_click: point("right_click"), move: point("move"), drag: point("drag"),
            key: keys("key"), hold: keys("hold"), down: keys("down"), up: keys("up")})});
        """
        let reach = !turn ? "" : """
          Object.defineProperty(globalThis, "turn", {value: Object.freeze(["persona", "pins", "recall", "context"]
            .reduce(function (t, name) { t[name] = function () { return invoke("turn", name, []); }; return t; }, {}))});
          Object.defineProperty(globalThis, "run", {value: function (input) { return step(input.state, input.event); }});
        """
        return """
        var app = (function (ids, call, say, __dataRoot, __workspace) {
          function where() {
            var m = (new Error().stack || "").match(/app-script\\.js:(\\d+):\\d+/);
            return m ? +m[1] : 0;
          }
          function invoke(kind, id, args) {
            var reply = JSON.parse(call("app_call", JSON.stringify({kind: kind, action: id, args: JSON.stringify(args), line: where()})));
            if (reply.failure) { var fault = new Error(reply.failure.message); fault.reason = reply.failure.code; throw fault; }
            var out = JSON.parse(reply.value);
            if (out.ok) return out.value;
            var e = new Error(out.detail);
            e.name = "AppError"; e.reason = out.reason; e.action = id; e.stopped = out.stopped;
            e.scriptLine = out.line; e.callNumber = out.n; e.receipt = out.receipt;
            // A reply that says nothing of effects is a refusal before anything ran.
            e.effects = out.effects === undefined ? "none" : out.effects; e.call = out.call || id;
            throw e;
          }
          \(host)\(reach)
          var api = {
            // Script API: authored app.call is refused by ability.save; dynamic abilities use host.call.
            call: function (id) { return invoke("action", id, Array.prototype.slice.call(arguments, 1)); },
            read: function () { return invoke("read", "", Array.prototype.slice.call(arguments)); },
            find: function (words) { return invoke("find", "", [words]); },
            log: function () {
              say(Array.prototype.map.call(arguments, function (a) {
                return typeof a === "string" ? a : JSON.stringify(a);
              }).join(" "));
            }\(marks)
          };
          ids.forEach(function (id) {
            var dot = id.indexOf("."), space = id.slice(0, dot);
            api[space] = api[space] || {};
            api[id] = api[space][id.slice(dot + 1)] = function () {
              return invoke("action", id, Array.prototype.slice.call(arguments));
            };
          });
          Object.keys(api).forEach(function (key) { Object.freeze(api[key]); });\(unknown)
          return Object.freeze(api);
        })(\(ids), __call, __log, \(primitives ? "__dataRoot, __workspace" : "undefined, undefined"));\(frozen)
        """
    }
}
