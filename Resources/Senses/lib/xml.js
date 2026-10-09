// Small namespace-aware-enough reader for OOXML / EPUB, not a browser DOM.
var SenseXML = (() => {
    const fail = NativeKit.fail;
    function entities(text) {
        const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0", ndash: "–", mdash: "—", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", hellip: "…", copy: "©", reg: "®" };
        return text.replace(/&([^;\s]+);/g, (_, name) => {
            if (name[0] === "#") {
                const hex = name[1] === "x", digits = name.slice(hex ? 2 : 1);
                if (!(hex ? /^[a-f\d]+$/i : /^\d+$/).test(digits)) fail("Invalid XML character reference");
                const code = parseInt(digits, hex ? 16 : 10);
                if (!code || code > 0x10ffff || code >= 0xd800 && code <= 0xdfff) fail("Invalid XML scalar");
                return String.fromCodePoint(code);
            }
            if (!(name in named)) fail("Unsupported XML entity: " + name);
            return named[name];
        });
    }
    function parse(text) {
        const root = { name: "", attrs: {}, children: [] }, stack = [root];
        const token = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE\s[^>]*>|<\/?[A-Za-z_](?:"[^"]*"|'[^']*'|[^'">])*>|[^<]+/g;
        let match, end = 0, nodes = 0;
        while ((match = token.exec(text))) {
            if (match.index !== end) fail("Malformed XML"); end = token.lastIndex;
            const s = match[0], parent = stack[stack.length - 1];
            if (s.startsWith("<!--") || s.startsWith("<?")) continue;
            if (s.startsWith("<!DOCTYPE")) { if (s.includes("[")) fail("XML entity declarations are unsupported"); continue; }
            if (s.startsWith("<![CDATA[")) { parent.children.push(s.slice(9, -3)); continue; }
            if (s.startsWith("</")) {
                if (stack.length === 1 || s.slice(2, -1).trim() !== parent.qualified) fail("Unbalanced XML element");
                stack.pop(); continue;
            }
            if (s[0] !== "<") { parent.children.push(entities(s)); continue; }
            if (++nodes > 500000 || stack.length > 128) fail("XML structure exceeds reader limits");
            if (nodes % 2048 === 0) sense.progress();
            const name = /^<([^\s/>]+)/.exec(s)[1], attrs = {};
            const tail = s.slice(1 + name.length, s.endsWith("/>") ? -2 : -1);
            const attr = /\s+([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g; let a, consumed = 0;
            while ((a = attr.exec(tail))) {
                if (a.index !== consumed || Object.prototype.hasOwnProperty.call(attrs, a[1])) fail("Malformed XML attributes");
                attrs[a[1]] = entities(a[2] === undefined ? a[3] : a[2]); consumed = attr.lastIndex;
            }
            if (tail.slice(consumed).trim()) fail("Malformed XML attributes");
            const node = { name: name.split(":").pop(), qualified: name, attrs, children: [] };
            parent.children.push(node);
            if (!s.endsWith("/>")) stack.push(node);
        }
        if (end !== text.length || stack.length !== 1) fail("Truncated XML");
        return root;
    }
    function children(node, name) { return node.children.filter(c => typeof c !== "string" && (!name || c.name === name)); }
    function all(node, name) {
        const out = []; let visited = 0;
        function walk(n) {
            if (typeof n === "string") return;
            if (++visited % 2048 === 0) sense.progress();
            if (n.name === name) out.push(n); n.children.forEach(walk);
        }
        walk(node); return out;
    }
    function attr(node, name) {
        if (node.attrs[name] !== undefined) return node.attrs[name];
        const key = Object.keys(node.attrs).find(k => k.split(":").pop() === name);
        return key === undefined ? undefined : node.attrs[key];
    }
    let textNodes = 0;
    function text(node) {
        if (typeof node === "string") return node;
        if (++textNodes % 2048 === 0) sense.progress();
        if (["script", "style", "del", "delText"].includes(node.name)) return "";
        if (["tab", "br", "cr"].includes(node.name)) return node.name === "tab" ? "\t" : "\n";
        return node.children.map(text).join("");
    }
    function resolve(base, target) {
        if (!target || /^[a-z][a-z\d+.-]*:/i.test(target) || target.startsWith("/")) fail("External or invalid package relationship");
        const parts = base.split("/").slice(0, -1);
        for (const part of decodeURIComponent(target.split("#")[0]).split("/")) {
            if (part === "..") { if (!parts.length) fail("Relationship escapes package"); parts.pop(); }
            else if (part && part !== ".") parts.push(part);
        }
        return parts.join("/");
    }
    function relationships(zip, part) {
        const pieces = part.split("/"), filename = pieces.pop();
        const rel = (pieces.length ? pieces.join("/") + "/" : "") + "_rels/" + filename + ".rels";
        const out = new Map();
        if (!zip.has(rel)) return out;
        for (const r of all(parse(zip.text(rel)), "Relationship")) {
            if (attr(r, "TargetMode") === "External") continue;
            out.set(attr(r, "Id"), { path: resolve(part, attr(r, "Target")), type: attr(r, "Type") });
        }
        return out;
    }
    return { parse, children, all, attr, text, resolve, relationships };
})();
