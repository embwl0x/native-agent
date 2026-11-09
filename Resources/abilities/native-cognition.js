/* NativeAgent ability
{
 "id":"native-cognition", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"Draw my cognition reading, controls and evidence from the resident mind's packet.",
 "actions":[],"inputSchema":{"type":"object","required":["title","sections","keys"]}}
}
*/
function face(input) {
    return {title: input.title, sections: input.sections};
}
function run(input) { return face(input); }
