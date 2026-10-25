/* NativeAgent ability
{"id":"make-generated","kind":"tool","version":1,
 "reach":{"capabilities":[]},
 "record":{"description":"Compose raw generated images with make.add, preserving their prompt, model and requested ref, and report each registration failure.","actions":["make.add"],"inputSchema":{"type":"object","required":["generated","prompt","ref"]}}}
*/
function run(input) {
    const response = input.generated;
    if (response.status !== "ok" || !Array.isArray(response.images)) return response;
    const result = Object.assign({},response);
    let ref = input.ref, landed = false;
    const failed = [];
    for (const image of response.images) {
        if (!image || typeof image.path !== "string") continue;
        const args = {path:image.path,prompt:input.prompt};
        if (ref !== null) args.ref = ref;
        if (typeof response.model === "string") args.model = response.model;
        try {
            const added = app.make.add(args);
            ref = added.ref;
            landed = true;
        } catch (error) {
            if (error.name !== "AppError" || error.stopped || error.reason === "cancelled") throw error;
            failed.push({path:image.path,error:error.message});
        }
    }
    if (landed) result.make_ref = ref;
    if (failed.length) result.make_failed = failed;
    return result;
}
