/* NativeAgent ability
{
 "id":"native-dreams", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"My dream diary from the diary owner's bounded reading, with selection and the person's cycle levers.",
 "actions":[],"inputSchema":{"type":"object","required":["sections","keys"]}}
}
*/
function face(input) {
    const page = {title: input.title, sections: input.sections};
    if (input.line !== undefined) page.line = input.line;
    if (input.detail !== undefined) page.detail = input.detail;
    return page;
}
