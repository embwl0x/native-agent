import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramPrelude.swift` | Frozen app/host namespaces, preview/version propagation, ordered batches and strict replay |
extension OwnedProgramRunner {
    public static let hostPrimitiveNamespaces: Set<String> = ["files", "network", "program", "apps", "model"]
    /// The stem's own file readers: a snapshot SQLite query and a MIME message read. Every other files.* call is the gated door action.
    public static let hostFilePrimitives: Set<String> = ["files.query", "files.mime"]
    public static let hostDoorActions: Set<String> = [
        "calendar.upcoming", "calendar.create", "calendar.modify", "calendar.delete",
        "reminders.query", "reminders.create", "reminders.update", "reminders.delete",
        "contacts.search", "contacts.save"
    ]
    /// Capture __call and __log before removing their global bindings; freeze input and namespace bindings while unknown actions retain door validation.
    public static func prelude(ids: String, strict: Bool = false, input: Bool = false, primitives: Bool = false,
                               turn: Bool = false) -> String {
        // The static reading (`OwnedProgram.calls`) and the live one share these keys.
        let requestKeys = OwnedProgram.Calls.requestKeys.map { "\"" + $0 + "\"" }.joined(separator: ", ")
        let marks = !strict ? "" : """
            ,
                expect: (ok, what) => { invoke("expect", "", [!!ok, String(what)]); },
                expect_fail: (code, act) => {
                  invoke("expect_fail", "", [String(code)]);
                  var caught = null, promised = false;
                  try { var back = act(); promised = !!back && typeof back.then === "function"; } catch (e) { caught = e; }
                  invoke("expect_fail_end", "", [promised]);
                  if (caught && (caught.name !== "AppError" || caught.reason !== code || caught.stopped)) throw caught;
                  return caught;
                },
                decide: (question, data) => invoke("decide", "", [String(question), data === undefined ? null : data]),
                step: (label, guidance, options) => {
                  invoke("step", "", [String(label), guidance === undefined ? "" : String(guidance), options === undefined ? null : options]);
                }
            """
        let unknown = """

              function named(space, base) {
                var namespace = () => {
                  throw new TypeError("app." + space + " is a namespace. Use app." + space + ".<verb>(args) or app({action:'" + space + ".<verb>',args:{}}).");
                };
                // An arrow function's only own properties (name, length) are configurable, so any verb name binds as an own property.
                Object.keys(base).forEach(function (key) {
                  // A deeper namespace (app.studio.intake) answers the same way.
                  var value = base[key];
                  if (value && typeof value === "object") value = named(space + "." + key, value);
                  define(namespace, key, value);
                });
                return new Proxy(Object.freeze(namespace), { get: function (t, key) {
                  if (typeof key !== "string" || key in t) return t[key];
                  if (key in api) return api[key];
                  return function () { return invoke("action", space + "." + key, Array.prototype.slice.call(arguments)); };
                } });
              }
              Object.keys(api).forEach(function (key) { if (typeof api[key] === "object") define(api, key, named(key, api[key])); });
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
            if (operation.indexOf("files.") === 0 && \(Self.hostFilePrimitives.sorted()).indexOf(operation) < 0) return door(operation, args);
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
          Object.defineProperty(globalThis, "run", {value: function (input) {
            if (input.weigh) return typeof weigh === "function" ? {worth: weigh(input.weigh.happening, input.weigh.felt)} : {grown: false};
            if (input.hear) return typeof hear === "function" ? {heard: hear(input.hear.happening, input.hear.felt)} : {grown: false};
            return step(input.state, input.event); }});
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
            // Pre-dispatch and runtime failures share this envelope field.
            e.try_instead = out.try_instead;
            // A reply that says nothing of effects is a refusal before anything ran.
            e.effects = out.effects === undefined ? "none" : out.effects; e.call = out.call || id;
            throw e;
          }
          \(host)\(reach)
          // The door and every callable binding are arrow functions: no own prototype, arguments or caller, so no id segment can collide.
          var api = Object.assign((request) => {
            if (!request || typeof request !== "object" || Array.isArray(request))
              throw new TypeError("Use app({action:'desk.read',args:{handle:'desk.1'}}) or app.desk.read({handle:'desk.1'}).");
            var batch = null;
            function action(request) {
              if (typeof request.action !== "string" || !request.action.trim())
                throw new TypeError("An app action needs {action:'space.verb',args:{}}; batches use app({actions:[{action:'space.verb',args:{}}]}).");
              var options = {};
              // Either preview protects the entry; its version overrides the batch's.
              ["preview", "expected_version"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(request, key)) options[key] = request[key];
                else if (batch && Object.prototype.hasOwnProperty.call(batch, key)) options[key] = batch[key];
              });
              if (request.preview === true || (batch && batch.preview === true)) options.preview = true;
              // One reading, as the app tool's: with no args, every other key is the action's; beside args, another key is refused.
              var others = Object.keys(request).filter(function (key) {
                return [\(requestKeys)].indexOf(key) < 0;
              });
              var args = request.args;
              if (args === undefined || args === null) {
                args = {};
                others.forEach(function (key) { args[key] = request[key]; });
              } else if (others.length) {
                throw new TypeError("app({action, args}) takes " + others.join(", ") + " inside args, or beside action when there is no args.");
              }
              return invoke("action", request.action, [args, options]);
            }
            // One reading for a lone call and for each batch entry: an action, a find or a page/item read.
            function one(request) {
              if (!request || typeof request !== "object" || Array.isArray(request))
                throw new TypeError("Each app actions entry is one call object: {action, args}, {page, item} or {find}.");
              if (request.action !== undefined) return action(request);
              if (request.actions !== undefined) {
                if (batch) throw new TypeError("An app actions entry is one call; a batch does not hold another batch.");
                if (!Array.isArray(request.actions)) throw new TypeError("app actions must be an array.");
                batch = request;
                return request.actions.map(function (entry) { return one(entry); });
              }
              if (request.find !== undefined) return api.find(request.find);
              return request.item === undefined ? api.read(request.page) : api.read(request.page, request.item);
            }
            return one(request);
          }, {
            // Literal app.call names are checked at save; computed names keep runtime declaration checks.
            call: (id, ...rest) => invoke("action", id, rest),
            read: (...given) => invoke("read", "", given),
            find: (words) => invoke("find", "", [words]),
            log: (...parts) => {
              say(parts.map(function (a) {
                return typeof a === "string" ? a : JSON.stringify(a);
              }).join(" "));
            }\(marks)
          });
          // Every id binds by its full segments (app.undo, app.desk.read, app.studio.intake.read) and whole (app["desk.read"]).
          // A namespace that is itself an action is that action's arrow function, holding its members; a namespace alone is an object
          // with no prototype. Members are own, configurable, enumerable properties, so they shadow anything inherited and __proto__ is
          // an own property, never a prototype. A segment that still cannot be placed is left out of the member form, never thrown:
          // its id stays reachable as app["id"] and app.call("id").
          var own = Object.keys(api), made = Object.create(null), tree = {id: null, under: Object.create(null)};
          function define(node, key, value) {
            try { Object.defineProperty(node, key, {value: value, enumerable: true, writable: true, configurable: true}); return true; }
            catch (e) { return false; }
          }
          ids.forEach(function (id) {
            var node = tree;
            id.split(".").forEach(function (segment) {
              node = node.under[segment] || (node.under[segment] = {id: null, under: Object.create(null)});
            });
            node.id = id;
          });
          function member(node, value) {
            if (!value && node.id !== null) {
              var id = node.id;
              value = made[id] = (...given) => invoke("action", id, given);
            }
            value = value || Object.create(null);
            Object.keys(node.under).forEach(function (key) { define(value, key, member(node.under[key])); });
            // A deeper action also answers under its dotted remainder (app.studio["intake.read"]), on a callable namespace as on a plain one.
            (function below(from, path) {
              Object.keys(from.under).forEach(function (key) {
                var child = from.under[key], rest = path ? path + "." + key : key;
                if (path && child.id !== null && made[child.id]) define(value, rest, made[child.id]);
                below(child, rest);
              });
            })(node, "");
            return Object.freeze(value);
          }
          Object.keys(tree.under).forEach(function (key) {
            // Bare door verbs keep their own binding (app.find); an action under one hangs on it.
            if (own.indexOf(key) >= 0) member({id: null, under: tree.under[key].under}, api[key]);
            else define(api, key, member(tree.under[key]));
          });
          ids.forEach(function (id) { if (id.indexOf(".") >= 0 && made[id]) define(api, id, made[id]); });
          Object.keys(api).forEach(function (key) { Object.freeze(api[key]); });\(unknown)
          return Object.freeze(api);
        })(\(ids), __call, __log, \(primitives ? "__dataRoot, __workspace" : "undefined, undefined"));\(frozen)
        """
    }
}
