(function install(roots, call, settings) {
    const {optionKeys, requestKeys, files, workspace, dataRoot, home, measurementSystem} = settings;
    function invoke(kind, id, args) {
        const out = call("app_call", kind, id, JSON.stringify(args));
        if (!out.ok) throw appError(id, out);
        return out.value;
    }
    function appError(id, out) {
        const e = new Error(out.detail);
        return Object.assign(e, {name: "AppError", reason: out.reason, code: out.failure_code || out.reason,
            action: id, stopped: out.stopped, scriptLine: out.line, callNumber: out.n, receipt: out.receipt,
            try_instead: out.try_instead, effects: out.effects === undefined ? "none" : out.effects, call: out.call || id});
    }
    function door(id, args = {}) {
        if (id.startsWith("files.") && args.root !== undefined) {
            const root = args.root === "app_data" ? dataRoot : args.root === "workspace" ? workspace : null;
            if (!root) throw new Error("File root must be app_data or workspace.");
            if (typeof args.path !== "string" || /^(\/|~)/.test(args.path) || args.path.split("/").includes(".."))
                throw new Error("File path must be relative to its root.");
            args = Object.assign({}, args, {path: root + "/" + args.path});
            delete args.root;
        }
        return invoke("action", id, [args]);
    }
    function primitive(id, args) {
        if (id.indexOf("files.") === 0 && !files.includes(id)) return door(id, args);
        return invoke("primitive", id, args === undefined ? [] : [args]);
    }
    const state = Object.freeze({get: () => invoke("state", "get", []), set: v => invoke("state", "set", [v])});
    const host = settings.part ? {call: primitive, state, measurementSystem,
        paths: Object.freeze({home, workspace}), fetch: args => primitive("fetch", args)} : {state};
    const request = request => {
        if (!request || typeof request !== "object" || Array.isArray(request))
          throw new TypeError("Use app({action:'desk.read',args:{handle:'desk.1'}}) or app.desk.read({handle:'desk.1'}).");
        var batch = null;
        function action(request) {
          if (typeof request.action !== "string" || !request.action.trim())
            throw new TypeError("An app action needs {action:'space.verb',args:{}}; batches use app({actions:[{action:'space.verb',args:{}}]}).");
          var options = {};
          optionKeys.forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(request, key)) options[key] = request[key];
            else if (batch && Object.prototype.hasOwnProperty.call(batch, key)) options[key] = batch[key];
          });
          if (request.preview === true || (batch && batch.preview === true)) options.preview = true;
          var others = Object.keys(request).filter(function (key) {
            return requestKeys.indexOf(key) < 0;
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
        function one(request) {
          if (!request || typeof request !== "object" || Array.isArray(request))
            throw new TypeError("Each app actions entry is one call object: {action, args}, {page, item} or {find}.");
          if (request.action !== undefined) return action(request);
          if ("actions" in request) {
            if (batch) throw new TypeError("An app actions entry is one call; a batch does not hold another batch.");
            var extra = Reflect.ownKeys(request).filter(key => key !== "actions" && optionKeys.indexOf(key) < 0).map(String).sort();
            if (extra.length) throw appError("actions", {reason: "invalid_actions", stopped: false, line: call("source_line", null), try_instead: null,
              detail: "app batch does not take " + extra.join(", ") + " beside actions."});
            if (!Array.isArray(request.actions)) throw new TypeError("app actions must be an array.");
            batch = request;
            return request.actions.map(function (entry) { return one(entry); });
          }
          if (request.find !== undefined) return verbs.find(request.find);
          return request.item === undefined ? verbs.read(request.page) : verbs.read(request.page, request.item);
        }
        return one(request);
    };
    const verbs = Object.assign(Object.create(null), {
        call: (id, ...given) => invoke("action", id, given),
        read: (...given) => invoke("read", "", given),
        find: words => invoke("find", "", [words]),
        log: (...parts) => call("script_log", parts.map(a => typeof a === "string" ? a : JSON.stringify(a)).join(" "))
    });
    if (settings.strict) Object.assign(verbs, {
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
    });
    function member(kind, id, children) {
        if (kind === "primitive") return args => primitive(id, args);
        if (kind === "door") return args => door(id, args);
        if (kind === "primitives") return Object.freeze(new Proxy({}, {get: (_, k) => typeof k === "string" ? children["+" + k] : undefined}));
        if (kind === "host" || kind === "doors") {
            const value = kind === "host" ? host : Object.create(null);
            for (const key of children["*"]) Object.defineProperty(value, key, {enumerable: true, get: () => children["=" + key]});
            return Object.freeze(value);
        }
        const value = kind === "root" ? request : verbs[id] || (kind === "action" ? (...args) => invoke("action", id, args)
            : () => { throw new TypeError("app." + id + " is a namespace. Use app." + id + ".<verb>(args) or app({action:'" + id + ".<verb>',args:{}})."); });
        function seal() {
            if (!Object.isExtensible(value)) return;
            for (const key of children["*"]) Object.defineProperty(value, key, {enumerable: true, configurable: true, get: () => children["=" + key]});
            Object.freeze(value);
        }
        return new Proxy(value, {
            get(target, key) {
                if (typeof key !== "string") return Reflect.get(target, key);
                const known = children["=" + key];
                if (known !== undefined) return known;
                if (key in target || kind === "action") return Reflect.get(target, key);
                return children["+" + key];
            },
            has: (t, k) => k in t || typeof k === "string" && children["?" + k],
            ownKeys() { seal(); return Reflect.ownKeys(value); },
            getOwnPropertyDescriptor(_, key) { seal(); return Reflect.getOwnPropertyDescriptor(value, key); },
            isExtensible() { seal(); return false; },
            preventExtensions() { seal(); return true; },
            defineProperty(_, k, d) { seal(); return Reflect.defineProperty(value, k, d); },
            setPrototypeOf(_, proto) { seal(); return Reflect.setPrototypeOf(value, proto); },
            deleteProperty(_, k) { seal(); return Reflect.deleteProperty(value, k); },
            set() { return false; }
        });
    }
    Object.defineProperty(request, "name", {value: ""});
    Object.defineProperty(globalThis, "app", {enumerable: true, configurable: true, get: () => roots.app,
        set(value) { Object.defineProperty(globalThis, "app", {value, writable: true, configurable: true, enumerable: true}); }});
    if (settings.part) {
        Object.defineProperty(globalThis, "part", {value: Object.freeze({
          call: function (id, input) {
            if (typeof id !== "string" || !/^[a-z][a-z0-9_-]{1,63}$/.test(id))
              return {ok: false, error: {code: "bad_input", message: "part.call requires an exact part id."}};
            if (!input || typeof input !== "object" || Array.isArray(input))
              return {ok: false, error: {code: "bad_input", message: "part.call input is a JSON object."}};
            try { return primitive("part.call", {id: id, input: input}); }
            catch (error) { return {ok: false, error: {code: error.reason || "failed", message: error.message}}; }
          }
        }), writable: true, configurable: true});
        Object.defineProperty(globalThis, "screen", {value: Object.freeze({
          watch: function (args) { return primitive("screen.watch", args); },
          next: function (timeout) {
            var f = primitive("screen.next", timeout === undefined ? {} : {timeout: timeout});
            if (!f || f.captured) return null;
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
        globalThis.kit = (() => {
            const row = fields => Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== null && value !== undefined));
            const segmenter = new Intl.Segmenter("en", {granularity: "grapheme"});
            const graphemes = text => Array.from(segmenter.segment(text), s => s.segment);
            function plain(raw) {
                return raw.trim().replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).map(rawLine => {
                    let line = rawLine.trim(), heading = false;
                    while (/^[#>]/.test(line)) { heading = heading || line[0] === "#"; line = line.slice(1).trim(); }
                    if (heading && line && !/[.!?:]$/.test(line)) line += ".";
                    for (const bullet of ["- ", "* ", "+ "]) if (line.startsWith(bullet)) line = line.slice(bullet.length);
                    return line.replace(/[*\x60\\]/g, "").trim();
                }).filter(Boolean).join(" ").trim();
            }
            function bounded(text, limit) {
                const chars = graphemes(text);
                if (chars.length <= limit) return text;
                const window = chars.slice(0, limit);
                let stop = -1;
                window.forEach((c, i) => { if (c === "." || c === "!" || c === "?") stop = i; });
                if (stop >= Math.floor(limit / 2)) return window.slice(0, stop + 1).join("");
                const space = window.lastIndexOf(" "), head = space >= 0 ? window.slice(0, space).join("").trim() : "";
                return (head || window.join("")) + "…";
            }
            return Object.freeze({row, graphemes, plain, bounded});
        })();
        Object.defineProperty(globalThis, "verbs", {value: undefined, writable: true, configurable: true});
    }
    if (settings.turn) {
        Object.defineProperty(globalThis, "turn", {value: Object.freeze(["persona", "pins", "recall", "context", "body"]
          .reduce(function (t, name) { t[name] = function () { return invoke("turn", name, []); }; return t; }, {}))});
        Object.defineProperty(globalThis, "run", {value: function (input) {
          if (input.weigh) return typeof weigh === "function" ? {worth: weigh(input.weigh.happening, input.weigh.felt)} : {grown: false};
          if (input.hear) return typeof hear === "function" ? {heard: hear(input.hear.happening, input.hear.felt)} : {grown: false};
          return step(input.state, input.event); }});
    }
    let update;
    if (settings.input !== undefined) {
        function freeze(v) {
            if (v && typeof v === "object") { Object.values(v).forEach(freeze); Object.freeze(v); }
            return v;
        }
        let current;
        update = json => { current = freeze(JSON.parse(json)); };
        update(settings.input);
        for (const key of ["input", "args"]) Object.defineProperty(globalThis, key, {get: () => current, enumerable: true});
    }
    return {member, update, names: Object.keys(verbs)};
})
