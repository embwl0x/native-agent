import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramPrelude.swift` | Frozen app/host namespaces, preview/version propagation, ordered batches and strict replay |
extension OwnedProgramRunner {
    public static let hostPrimitiveNamespaces: Set<String> = ["files", "network", "program", "apps", "model"]
    public static let hostDoorActions: Set<String> = [
        "calendar.upcoming", "calendar.create", "calendar.modify", "calendar.delete",
        "reminders.query", "reminders.create", "reminders.update", "reminders.delete",
        "contacts.search", "contacts.save"
    ]
    /// Capture __call and __log before removing their global bindings; freeze input and namespace bindings while unknown actions retain door validation.
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
                var namespace = () => {
                  throw new TypeError("app." + space + " is a namespace. Use app." + space + ".<verb>(args) or app({action:'" + space + ".<verb>',args:{}}).");
                };
                // A verb may itself be named name/length; those function
                // properties are configurable until this namespace freezes.
                Object.keys(base).forEach(function (key) {
                  Object.defineProperty(namespace, key, {value: base[key], enumerable: true});
                });
                return new Proxy(Object.freeze(namespace), { get: function (t, key) {
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
        let namespaces = Self.hostPrimitiveNamespaces.sorted().map { "\($0): primitives(\"\($0)\")" }
        let doorActions = Set(Self.hostDoorActions.compactMap { $0.split(separator: ".").first.map(String.init) }).sorted().map { space in
            let methods = Self.hostDoorActions.sorted().filter { $0.hasPrefix(space + ".") }.map { key in
                "\(key.split(separator: ".").last!): function (args) { return door(\"\(key)\", args); }"
            }
            return "\(space): Object.freeze({\(methods.joined(separator: ","))})"
        }
        let host = !primitives ? (strict ? state + """
            Object.defineProperty(globalThis, \"host\", {value: Object.freeze({state: partState})});
            """ : "") : state + """
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
            return invoke("action", id, [args]);
          }
          Object.defineProperty(globalThis, "host", {value: Object.freeze({call: primitive, state: partState,
            measurementSystem: __measurementSystem,
            paths: Object.freeze({home: __home, workspace: __workspace}),
            \(namespaces.joined(separator: ",")), fetch: function (args) { return primitive("fetch", args); },
            \(doorActions.joined(separator: ","))}), writable: false, configurable: false});
          Object.defineProperty(globalThis, "part", {value: Object.freeze({
            call: function (id, input) {
              if (typeof id !== "string" || !/^[a-z][a-z0-9_-]{1,63}$/.test(id))
                return {ok: false, error: {code: "bad_input", message: "part.call requires an exact part id."}};
              if (!input || typeof input !== "object" || Array.isArray(input))
                return {ok: false, error: {code: "bad_input", message: "part.call input is a JSON object."}};
              try { return primitive("part.call", {id: id, input: input}); }
              catch (error) { return {ok: false, error: {code: error.reason || "failed", message: error.message}}; }
            }
          // A convenience name never takes a name from the agent's code: its own
          // declaration of `part` or `screen` replaces it in the agent's sandbox.
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
          var api = Object.assign(function (request) {
            if (!request || typeof request !== "object" || Array.isArray(request))
              throw new TypeError("Use app({action:'desk.read',args:{handle:'desk.1'}}) or app.desk.read({handle:'desk.1'}).");
            var batch = request;
            function action(request) {
              if (!request || typeof request !== "object" || typeof request.action !== "string" || !request.action.trim())
                throw new TypeError("An app action needs {action:'space.verb',args:{}}; batches use app({actions:[{action:'space.verb',args:{}}]}).");
              var options = {};
              // Either preview protects the entry; its version overrides the batch's.
              ["preview", "expected_version"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(request, key)) options[key] = request[key];
                else if (request !== batch && Object.prototype.hasOwnProperty.call(batch, key)) options[key] = batch[key];
              });
              if (request.preview === true || batch.preview === true) options.preview = true;
              return invoke("action", request.action, [request.args === undefined ? {} : request.args, options]);
            }
            if (request.action !== undefined) return action(request);
            if (request.actions !== undefined) {
              if (!Array.isArray(request.actions)) throw new TypeError("app actions must be an array.");
              return request.actions.map(action);
            }
            if (request.find !== undefined) return api.find(request.find);
            return request.item === undefined ? api.read(request.page) : api.read(request.page, request.item);
          }, {
            // Literal app.call names are checked at save; computed names keep runtime declaration checks.
            call: function (id) { return invoke("action", id, Array.prototype.slice.call(arguments, 1)); },
            read: function () { return invoke("read", "", Array.prototype.slice.call(arguments)); },
            find: function (words) { return invoke("find", "", [words]); },
            log: function () {
              say(Array.prototype.map.call(arguments, function (a) {
                return typeof a === "string" ? a : JSON.stringify(a);
              }).join(" "));
            }\(marks)
          });
          ids.forEach(function (id) {
            var dot = id.indexOf("."), space = id.slice(0, dot);
            // Bare door verbs already have their own binding (app.find).
            if (dot < 0) return;
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
