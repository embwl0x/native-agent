// Canvas example: exposed AX plus independently recognized window text.
function read(request) {
    const K = NativeKit, material = sense.source.read();
    if (material.kind !== "accessibility" || !material.tree) K.fail("Canvas sense needs an accessibility tree");
    const base = K.root(material, "app:com.figma.Desktop"), rows = [], seen = new Set();
    let count = 0;
    function string(value) {
        if (typeof value === "string") return value;
        if (typeof value === "boolean" || typeof value === "number" && Number.isFinite(value)) return String(value);
        // Native MacScreenText's redacted representation is authoritative.
        if (value && typeof value === "object" && value.redacted === true) return "[redacted]";
        if (value && typeof value === "object" && typeof value.text === "string") return value.text;
        return "";
    }
    function walk(node, path) {
        if (!node || typeof node !== "object") K.fail("Malformed canvas accessibility node");
        if (++count > 10000 || path.length > 64) K.fail("Canvas accessibility tree exceeds reader limits");
        const role = string(node.role || node.AXRole), name = string(node.label || node.title || node.AXTitle || node.name || node.description || node.AXDescription || node.text);
        const secret = /SecureTextField|Password/i.test(role) || node.secret === true || node.secret_field === true || node.redacted === true;
        const identifier = string(node.identifier || node.AXIdentifier || node.source_id);
        const axPath = node.sourceAXPath || node.source_ax_path || node.ax_path || node.path;
        if (axPath && (!Array.isArray(axPath) || axPath.some(n => !Number.isSafeInteger(n) || n < 0))) K.fail("Invalid canvas accessibility path");
        const identity = identifier ? "id/" + encodeURIComponent(identifier) : Array.isArray(axPath) ? "ax/" + axPath.join(".") : "ax/" + path.join(".");
        const at = base + "/" + identity;
        if (name || role) {
            if (seen.has(at)) K.fail("Canvas accessibility identity is ambiguous: " + at); seen.add(at);
            const value = secret ? "[redacted]" : string(node.value === undefined ? node.AXValue : node.value);
            const detail = [role, value, node.selected === true ? "selected" : "", node.enabled === false ? "disabled" : "", !identifier ? "Address follows the accessibility path; reread after layout changes." : ""].filter(Boolean).join(" · ");
            const kind = /Outline|Row|Cell/i.test(role) ? "layer" : /Button/i.test(role) ? "button" : /Text/i.test(role) ? "text" : /Group|Canvas/i.test(role) ? "group" : "element";
            rows.push(K.thing(secret ? "Protected field" : name || role, kind, at, detail));
        }
        const children = node.children || node.AXChildren || [];
        if (!Array.isArray(children)) K.fail("Canvas accessibility children are not an array");
        children.forEach((child, i) => walk(child, path.concat(i)));
    }
    const tree = material.tree;
    // Accept both an AX tree and the current four-verbs observation's target
    // list. Handle numbers are never relabeled as persistent identifiers.
    const roots = Array.isArray(tree) ? tree : Array.isArray(tree.nodes) ? tree.nodes : Array.isArray(tree.targets) ? tree.targets : Array.isArray(tree.affordances) ? tree.affordances : Array.isArray(tree.windows) ? tree.windows : [tree.root || tree];
    roots.forEach((node, i) => walk(node, [i]));
    (tree.recognized_text || []).forEach((row, i) => {
        const text = string(row.text), f = row.frame;
        if (!text || !f) return;
        rows.push(K.thing(text, "window text", base + "/recognized/" + i,
            "On-device window text recognition · x=" + f.x + " y=" + f.y + " width=" + f.w + " height=" + f.h));
    });
    if (!rows.length) K.fail("The canvas exposes no named accessibility elements");
    K.publish("app:com.figma.Desktop", base, "Figma canvas", rows, request,
        typeof tree.renderer_wait_note === "string" ? tree.renderer_wait_note : "");
}
function watch() { sense.source.watch(); }
function changed(material) { read({address: null}); sense.notify({address: "app:com.figma.Desktop", summary: "Figma canvas changed."}); }
