/* NativeAgent ability
{
 "id":"native-graph", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"My knowledge graph from the canonical graph owner's bounded reading, with each selected entity and a reviewed upkeep.",
 "actions":[],"inputSchema":{"type":"object","required":["sections","keys"]}}
}
*/
function face(input) {
    const page = {title: input.title, sections: input.sections};
    if (input.line !== undefined) page.line = input.line;
    if (input.detail !== undefined) page.detail = input.detail;
    return page;
}
