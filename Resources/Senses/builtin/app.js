// Generic app authoring example. Prepend frame.js when making a complete sense.
// No app names, launch routes, focus changes or desktop actions.
var AppKit = (() => {
    let baseline;
    const verbs = role => {
        const out = ["press"];
        if (["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField"].includes(role)) out.push("type", "focus");
        if (["AXRow", "AXCell", "AXOutlineRow", "AXListItem", "AXRadioButton", "AXTab"].includes(role)) out.push("select");
        if (["AXCheckBox", "AXSwitch"].includes(role)) out.push("toggle");
        return out;
    };
    function tree(material) {
        if (material.kind !== "accessibility" || !Array.isArray(material.tree.nodes)
            || typeof material.tree.app_bundle_id !== "string") NativeKit.fail("App sense needs the running window's AX material");
        return material.tree;
    }
    function selection(source, control) {
        return JSON.stringify({app: source.app_bundle_id, frame_id: source.frame_id, handle: control.handle});
    }
    function signature(source) {
        // Frame handles are read bindings, never evidence of a content change.
        return JSON.stringify({nodes: source.nodes, recognized_text: source.recognized_text, seam: source.seam});
    }
    function publish(material, request = {}) {
        const source = tree(material), root = "app:" + source.app_bundle_id;
        const content = source.nodes.map(node => [node.title, node.value, node.state]
            .filter(value => typeof value === "string" && value).join("\n")).filter(Boolean);
        if (source.recognized_text_body) content.push("On-device window text recognition\n" + source.recognized_text_body);
        const full = content.join("\n\n");
        let offset = 0, controlOffset = 0;
        if (request.address && request.address.startsWith(root + "?read=more&")) {
            const cursor = /^.*\?read=more&text=(\d+)&controls=(\d+)$/.exec(request.address);
            if (!cursor) NativeKit.fail("Invalid app reading place");
            offset = Number(cursor[1]); controlOffset = Number(cursor[2]);
        }
        const controls = (source.affordances || []).filter(control => typeof control.handle === "string");
        if (offset > full.length || controlOffset > controls.length) NativeKit.fail("App reading place changed; read the app again");
        const note = source.renderer_wait_note || "";
        const text = NativeKit.prefix(full.slice(offset), NativeKit.maximumTextBytes - NativeKit.utf8Length(note + "\n"));
        const shown = controls.slice(controlOffset, controlOffset + 80);
        const things = shown.map(control => ({name: control.label || control.role, kind: control.role,
            address: selection(source, control), detail: control.value || "",
            verbs: control.enabled === false ? [] : verbs(control.role)}));
        const page = {address: request.address || root, title: source.app_bundle_id,
            text: (note ? note + "\n" : "") + text, things, folded: []};
        if (offset + text.length < full.length || controlOffset + shown.length < controls.length) {
            page.folded = ["Remaining window text and controls"];
            page.more = root + "?read=more&text=" + (offset + text.length) + "&controls=" + (controlOffset + shown.length);
        }
        sense.publish(page);
        return source;
    }
    function read(request) { baseline = signature(publish(sense.source.read(), request)); }
    function act(request) {
        const source = tree(sense.source.read()), target = JSON.parse(request.address);
        const control = (source.affordances || []).find(control => control.handle === target.handle);
        if (target.app !== source.app_bundle_id || target.frame_id !== source.frame_id || !control
            || control.enabled === false || !verbs(control.role).includes(request.verb)) NativeKit.fail("Read the app again before acting on this thing");
        const args = request.args || {};
        return sense.act("mac.act", request.address, {app: target.app, frame_id: target.frame_id,
            handle: target.handle, verb: request.verb === "press" ? "click" : request.verb,
            ...(args.text === undefined ? {} : {text: args.text}), ...(args.mode === undefined ? {} : {mode: args.mode})});
    }
    function changed(material) {
        const source = publish(material), next = signature(source);
        if (baseline !== undefined && baseline !== next) sense.notify({address: "app:" + source.app_bundle_id,
            summary: "The app's AX text or recognized window text changed."});
        baseline = next;
    }
    return {read, act, changed};
})();
function read(request) { AppKit.read(request); }
function act(request) { return AppKit.act(request); }
function watch() { sense.source.watch(); }
function changed(material) { AppKit.changed(material); }
