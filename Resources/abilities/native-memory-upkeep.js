/* NativeAgent ability
{
 "id":"native-memory-upkeep", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"Draw memory upkeep, its checked diagnostics and each unavailable reading from the memory owner's packet.",
 "actions":[],"inputSchema":{"type":"object","required":["title","sections","keys"]}}
}
*/
function face(input) {
    return {title: input.title, sections: input.sections};
}
function run(input) { return face(input); }
