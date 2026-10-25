/* NativeAgent ability
{"id":"make-title","kind":"tool","version":1,
 "reach":{"capabilities":[]},"face":{"projection":true},
 "record":{"description":"The title of a Make preview, from its decoded HTML title, prompt or filename.","actions":[],"inputSchema":{"type":"object","required":["html","prompt","filename"]}}}
*/
function face(input) {
    // Foundation's whitespacesAndNewlines, including NEL and excluding BOM.
    const trim = text => text.replace(/^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/g, "");
    let title = "";
    if (input.html.state === "available") {
        const html = input.html.text;
        const open = /<title>/i.exec(html);
        if (open) {
            const body = html.slice(open.index + open[0].length);
            const close = /<\/title>/i.exec(body);
            if (close) title = trim(body.slice(0, close.index));
        }
    }
    if (!title && input.prompt !== null) title = trim(input.prompt);
    if (!title) title = input.filename;
    return {sections:[{id:"preview",rows:[{id:"title",title}]}]};
}
function run(input) { return face(input); }
