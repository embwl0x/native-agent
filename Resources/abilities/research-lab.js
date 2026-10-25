/* NativeAgent ability
{"id":"research-lab","kind":"tool","version":1,
 "face":{"page":"web"},
 "record":{"description":"Select sources and compose a Research Lab brief from the native SearXNG evidence packet. NativeAgent commits the run and its receipts; this part owns selection and wording.","actions":[],"inputSchema":{"type":"object","readOnly":true,"properties":{"objective":{"type":"string"},"maxResults":{"type":"integer"},"search":{"type":"object"}},"required":["objective","maxResults","search"],"additionalProperties":false}}}
*/
function run(input) {
    const search = input.search;
    if (!["available", "unavailable"].includes(search.availability)) throw new Error("Search availability is required.");
    const maximum = Math.max(1, Math.min(8, input.maxResults === 0 ? 5 : input.maxResults));
    const sources = search.results.slice(0, maximum);
    let brief;
    if (search.reason === "engines_failed") brief = search.error;
    else if (search.reason === "not_configured") brief = "Research connector needs setup before this can run fully: " + search.error;
    else if (search.availability === "unavailable") brief = "Research failed: " + search.error;
    else if (!sources.length) brief = "No sources returned. Configure SearXNG or broaden the query.";
    else {
        const titles = sources.slice(0, 3).map(row => row.title.trim() || row.url.trim() || "Source");
        brief = "Captured " + sources.length + " source(s) for: " + input.objective + ". Top sources: " + titles.join("; ");
    }
    return {sources, brief};
}
