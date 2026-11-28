function programIndex(source) {
    const comments = [];
    const tree = acorn.parse(source, {ecmaVersion: "latest", locations: true, onComment: comments});
    const root = {bindings: new Map(), outer: null};
    const scopes = new WeakMap(), parents = new WeakMap(), nodes = [];
    const initializing = new WeakSet();
    const entries = new Set(), functions = Object.create(null), calls = [];
    const functionTypes = new Set(["FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"]);
    const blockTypes = new Set(["BlockStatement", "ForStatement", "ForOfStatement", "ForInStatement", "SwitchStatement", "CatchClause", "ClassExpression", "ClassDeclaration", "StaticBlock"]);
    function bind(pattern, scope, init) {
        if (!pattern) return;
        switch (pattern.type) {
        case "Identifier":
            if (scope.bindings.has(pattern.name)) scope.bindings.get(pattern.name).changed = true;
            else scope.bindings.set(pattern.name, {init, references: []});
            if (scope === root) entries.add(pattern.name);
            break;
        case "AssignmentPattern": bind(pattern.left, scope); break;
        case "RestElement": bind(pattern.argument, scope); break;
        case "ObjectPattern": for (const p of pattern.properties) bind(p.value || p.argument, scope); break;
        case "ArrayPattern": for (const e of pattern.elements) bind(e, scope); break;
        }
    }
    const hasStrictDirective = body => body.some(statement => statement.directive === "use strict");
    const pending = [{node: tree, parent: null, scope: root, variableScope: root, atLoad: true,
        strict: hasStrictDirective(tree.body)}];
    while (pending.length) {
        let {node, parent, scope, variableScope, atLoad, strict} = pending.pop();
        if (atLoad) initializing.add(node);
        if (!strict && atLoad && node.type === "FunctionDeclaration" && node.id) entries.add(node.id.name);
        if (functionTypes.has(node.type)) atLoad = false;
        if (node.type === "FunctionDeclaration" || node.type === "ClassDeclaration") bind(node.id, scope);
        if (node.type === "FunctionDeclaration" && scope === root) root.bindings.get(node.id.name).globalProperty = true;
        if (!strict && node.type === "FunctionDeclaration" && parent?.type === "BlockStatement" && scope !== variableScope) {
            const name = node.id?.name;
            if (name && !variableScope.bindings.has(name)) variableScope.bindings.set(name, {references: []});
        }
        if (functionTypes.has(node.type) || blockTypes.has(node.type))
            scope = {outer: scope, bindings: new Map()};
        if (functionTypes.has(node.type)) {
            strict ||= node.body.type === "BlockStatement" && hasStrictDirective(node.body.body);
            variableScope = scope;
            bind(node.id, scope);
            for (const param of node.params) bind(param, scope);
        }
        if (node.type === "ClassExpression" || node.type === "ClassDeclaration") strict = true;
        if (node.type === "StaticBlock") variableScope = scope;
        if (node.type === "ClassExpression") bind(node.id, scope);
        if (node.type === "CatchClause") bind(node.param, scope);
        if (node.type === "VariableDeclaration") {
            const scoped = node.kind !== "var" || parent.type === "Program" ||
                parent.type === "BlockStatement" && functionTypes.has(parents.get(parent)?.type);
            for (const d of node.declarations) {
                bind(d.id, node.kind === "var" ? variableScope : scope, scoped ? d.init : null);
                if (node.kind === "var" && variableScope === root && d.id.type === "Identifier")
                    root.bindings.get(d.id.name).globalProperty = true;
            }
        }
        parents.set(node, parent);
        scopes.set(node, scope);
        nodes.push(node);
        const children = [];
        for (const child of Object.values(node)) {
            if (Array.isArray(child)) { for (const e of child) if (e?.type) children.push(e); }
            else if (child?.type) children.push(child);
        }
        for (let i = children.length - 1; i >= 0; --i)
            pending.push({node: children[i], parent: node, scope, variableScope, atLoad, strict});
    }
    function binding(id) {
        for (let scope = scopes.get(id); scope; scope = scope.outer)
            if (scope.bindings.has(id.name)) return scope.bindings.get(id.name);
    }
    function string(value) { return typeof value === "string" && value.isWellFormed() ? value : null; }
    function literal(node) {
        if (node?.type === "Literal" && typeof node.value === "string") return string(node.value);
        if (node?.type === "TemplateLiteral" && !node.expressions.length) return string(node.quasis[0].value.cooked);
        return null;
    }
    function prop(node) { return node.computed ? literal(node.property) : node.property.name; }
    function chain(node) {
        const members = [];
        while (node.type === "MemberExpression") { members.push(prop(node)); node = node.object; }
        if (node.type === "Identifier" && !binding(node) && ["app","host","part","screen","hand"].includes(node.name))
            return {root: node.name, members: members.reverse()};
    }
    function locations() {
        const lines = Object.create(null), direct = new WeakSet();
        const verbs = new Set(["read", "find", "log", "expect", "expect_fail", "step", "decide"]);
        function mark(key, line) { lines[key] = key in lines && lines[key] !== line ? 0 : line; }
        for (const node of nodes) {
            if (node.type !== "CallExpression") continue;
            let callee = node.callee;
            const keys = [];
            while (callee.type === "MemberExpression") {
                const key = prop(callee);
                if (key === null || (key !== "call" && key in Function.prototype) || key === "prototype") return {};
                keys.unshift(key);
                callee = callee.object;
            }
            if (callee.type !== "Identifier") return {};
            if (binding(callee)) return {};
            const root = callee.name, line = node.loc.start.line === node.loc.end.line ? node.loc.start.line : 0;
            if (!["app", "host", "turn", "hand", "part", "screen"].includes(root) || !keys.length) return {};
            direct.add(callee);
            const name = keys.join(".");
            if ((root === "app" || root === "host") && name === "call") {
                const id = literal(node.arguments[0]);
                if (id === null) return {};
                mark(id, line);
            } else if (root === "app") {
                mark(name, line);
                if (verbs.has(keys[keys.length - 1])) mark(keys[keys.length - 1], line);
                if (keys.includes("call") || keys.slice(0, -1).some(key => verbs.has(key))) return {};
                if (keys[keys.length - 1] === "expect_fail") mark("expect_fail_end", line);
            } else if (root === "host") {
                mark(name.startsWith("state.") ? keys[1] : name, line);
            } else {
                mark(root === "turn" ? name : root + "." + name, line);
            }
        }
        for (const node of nodes) {
            if (["ThisExpression", "Super", "WithStatement", "ImportExpression", "TaggedTemplateExpression", "NewExpression",
                "ObjectPattern", "ArrayPattern", "ClassDeclaration", "ClassExpression"].includes(node.type)) return {};
            if (node.type === "MemberExpression" && (prop(node) === null || ["constructor", "__proto__", "prototype", "caller", "callee"].includes(prop(node)))) return {};
            if (node.type !== "Identifier" || binding(node) || direct.has(node)) continue;
            const p = parents.get(node);
            if (p.type === "MemberExpression" && !p.computed && p.property === node ||
                p.type === "Property" && !p.computed && !p.shorthand && p.key === node) continue;
            if (!["input", "args", "undefined", "NaN", "Infinity"].includes(node.name)) return {};
        }
        return lines;
    }
    function facts() {
        function inert(node) {
            if (!node) return true;
            switch (node.type) {
            case "Literal": case "Identifier": case "FunctionDeclaration": case "FunctionExpression":
            case "ArrowFunctionExpression": case "EmptyStatement": return true;
            case "VariableDeclaration":
                return node.declarations.every(d => d.id.type === "Identifier" && inert(d.init));
            case "ExpressionStatement": return inert(node.expression);
            case "ArrayExpression": return node.elements.every(inert);
            case "ObjectExpression":
                return node.properties.every(p => p.type === "Property" && !p.computed && inert(p.value));
            case "MemberExpression": {
                const owner = node.object.type === "Identifier" ? binding(node.object)?.init : node.object;
                const key = prop(node);
                return owner?.type === "ObjectExpression" && key !== null && owner.properties.every(p =>
                    p.type === "Property" && !p.computed && p.kind === "init") &&
                    owner.properties.some(p => (p.key.name ?? p.key.value) === key);
            }
            default: return false;
            }
        }
        if (tree.body.some(node => !inert(node))) entries.add("*");
        const evalScopes = new Set();
        const commentEnding = new Map(comments.filter(c => c.type === "Line").map(c => [c.loc.end.line, c]));
        for (const node of nodes) {
            const p = parents.get(node);
            if (node.type === "CallExpression" && node.callee.type === "Identifier" && node.callee.name === "eval" && !binding(node.callee))
                for (let scope = scopes.get(node); scope; scope = scope.outer) evalScopes.add(scope);
            if (node.type === "Identifier" && !(p.type === "MemberExpression" && !p.computed && p.property === node)
                && !(p.type === "Property" && !p.computed && p.key === node)
                && !(p.type === "VariableDeclarator" && p.id === node)) binding(node)?.references.push(node);
            if (initializing.has(node) && node.type === "AssignmentExpression") {
                const target = node.left;
                if (target.type === "Identifier" && !binding(target)) entries.add(target.name);
                if (target.type === "MemberExpression" && (target.object.type === "ThisExpression" || target.object.name === "globalThis")) {
                    const key = prop(target);
                    if (key !== null) entries.add(key);
                    else entries.add("*");
                } else if (target.type !== "Identifier") {
                    entries.add("*");
                }
            }
            if (p === tree && node.type === "FunctionDeclaration") {
                let start = node.start, line = node.loc.start.line;
                while (commentEnding.has(line - 1)) {
                    const c = commentEnding.get(line - 1);
                    if (source.slice(c.end, start).trim()) break;
                    start = c.start;
                    line = c.loc.start.line;
                }
                functions[node.id.name] = [start, node.end];
            }
        }
        const shapes = [{unknown:{}}], indices = new WeakMap();
        const secretLines = Object.create(null);
        const unknown = 0;
        function shape(node) {
            if (!node) return unknown;
            if (indices.has(node)) return indices.get(node);
            indices.set(node, unknown);
            const result = inspect(node);
            const index = typeof result === "number" ? result : shapes.push(result) - 1;
            indices.set(node, index);
            return index;
        }
        function inspect(node) {
            if (!node) return unknown;
            const value = literal(node);
            if (value !== null) return {value:{_0:value}};
            if (node.type === "Literal" && !node.regex && !node.bigint && (node.value === null || typeof node.value === "boolean" || Number.isFinite(node.value)))
                return {value:{_0:node.value}};
            if (node.type === "UnaryExpression" && ["+","-"].includes(node.operator) && Number.isFinite(node.argument.value))
                return {value:{_0:node.operator === "-" ? -node.argument.value : node.argument.value}};
            if (node.type === "ArrayExpression" && node.elements.every(e => e && e.type !== "SpreadElement"))
                return {array:{_0:node.elements.map(shape)}};
            if (node.type === "ObjectExpression") {
                const fields = Object.create(null);
                for (const p of node.properties) {
                    if (p.type !== "Property" || p.computed || p.method || p.kind !== "init") return unknown;
                    const key = p.key.name ?? p.key.value;
                    if (key === "__proto__" || typeof key === "string" && string(key) === null) return unknown;
                    fields[key] = shape(p.value);
                }
                return {object:{_0:fields}};
            }
            if (node.type === "Identifier") {
                const b = binding(node);
                if (!b?.init || b.changed || b.init.end > node.start) return unknown;
                if (evalScopes.has(scopes.get(b.init))) return unknown;
                if (b.stable !== undefined) return b.stable ? shape(b.init) : unknown;
                b.stable = false;
                const reference = ["ObjectExpression","ArrayExpression","Identifier"].includes(b.init.type);
                for (const ref of b.references) {
                    const p = parents.get(ref);
                    if (reference && !(p.type === "CallExpression" && p.arguments.includes(ref) && chain(p.callee)?.root === "app")) return unknown;
                    if (p.type === "UpdateExpression" || p.type === "AssignmentExpression" && p.left === ref
                        || ["ObjectPattern","ArrayPattern","RestElement","ForOfStatement","ForInStatement","AssignmentPattern"].includes(p.type)
                        || p.type === "Property" && parents.get(p)?.type === "ObjectPattern") return unknown;
                }
                b.stable = true;
                return shape(b.init);
            }
            return unknown;
        }
        for (const node of nodes) {
            const text = node.type === "TemplateElement" ? string(node.value.cooked) : node.type === "Literal" ? literal(node) : null;
            if (text?.includes("{{secret:")) {
                for (const match of text.matchAll(/\{\{secret:([^{}]{1,64})\}\}/g)) {
                    secretLines[match[1]] ??= node.loc.start.line;
                }
            }
            if (initializing.has(node) && (node.type === "VariableDeclarator" && node.init ||
                node.type === "AssignmentExpression" || node.type === "UpdateExpression")) {
                const target = node.id ?? node.left ?? node.argument;
                let name;
                if (target?.type === "Identifier" && binding(target) === root.bindings.get(target.name)) name = target.name;
                if (target?.type === "MemberExpression" && (target.object.type === "ThisExpression" ||
                    target.object.name === "globalThis" && !binding(target.object))) {
                    const key = prop(target);
                    if (!root.bindings.has(key) || root.bindings.get(key).globalProperty) name = key;
                }
                if (name != null) {
                    const value = node.init ?? (node.operator === "=" ? node.right : null);
                    const statement = parents.get(node);
                    if (value && parents.get(statement) === tree && (functionTypes.has(value.type) ||
                        value.type === "Identifier" && functions[value.name])) functions[name] = [statement.start, statement.end];
                    else delete functions[name];
                }
            }
            if (node.type !== "CallExpression" && node.type !== "NewExpression") continue;
            const target = chain(node.callee);
            if (!target) continue;
            let inWithBody = false;
            for (let child = node, p = parents.get(child); p; child = p, p = parents.get(child)) {
                if (p.type === "WithStatement" && p.body === child) { inWithBody = true; break; }
            }
            if (inWithBody && !(target.root === "app" && ["step","decide","expect","expect_fail"].includes(target.members[0]))) continue;
            calls.push({...target, line:node.loc.start.line, first:literal(node.arguments[0]),
                given:node.arguments.some(n => n.type === "SpreadElement") ? null : node.arguments.map(n => shape(n))});
        }
        return JSON.stringify({entries:[...entries].sort(), functions, shapes, calls, callLines:locations(), secretLines});
    }
    return {locations, facts};
}

(function () {
    const analyze = source => programIndex(source).facts();
    analyze.locations = source => {
        try { return programIndex(source).locations(); }
        catch (error) { if (error instanceof SyntaxError) return {}; throw error; }
    };
    return analyze;
})()
