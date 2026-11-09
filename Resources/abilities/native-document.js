/* NativeAgent ability
{
  "id":"native-document", "kind":"ability", "version":1,
  "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
  "face":{"projection":true},
  "record":{
    "description":"My passive document page from its owner's title and frozen reading, with selection, Find and Copy at every door.",
    "actions":[], "inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":true}
  }
}
*/
function face(input) {
    return {sections: [{id: "document", title: input.title,
        block: {kind: "document", key: "body", format: input.format, copy: true}}]};
}
