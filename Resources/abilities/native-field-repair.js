/* NativeAgent ability
{
 "id":"native-field-repair", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]}, "wake":[], "resident":false,
 "record":{
   "description":"Choose bounded dream and residual field repairs from the organism's captured numeric evidence.",
   "actions":[], "inputSchema":{"type":"object","readOnly":true,"additionalProperties":false,
   "properties":{"residual":{"type":"boolean"},
                 "nodes":{"type":"array","items":{"type":"array","items":{"type":"number"}}},
                 "edges":{"type":"array","items":{"type":"array","items":{"type":"number"}}}},
   "required":["residual","nodes","edges"]}
 }
}
*/
function run(input) {
    const clamp = value => Math.min(1, Math.max(0, value));
    const limit = 16;
    const edits = [];
    const nodes = input.nodes.map(([charge, activation], target) => ({charge, activation, target}));
    const edges = input.edges.map(([weight, uncertainty, eligibility], target) => ({weight, uncertainty, eligibility, target}));

    const charged = nodes.filter(node => node.charge >= 0.12)
        .sort((a, b) => b.charge - a.charge || a.target - b.target);
    for (const node of charged.slice(0, limit)) {
        edits.push({kind: "softenHighArousal", target: node.target,
            values: [clamp(node.charge * 0.52), Math.max(0.05, clamp(node.activation * 0.82))]});
    }

    if (!input.residual) {
        const warm = edges.filter(edge => edge.uncertainty <= 0.12 && edge.weight > 0)
            .sort((a, b) => b.weight - a.weight || a.target - b.target);
        for (const edge of warm.slice(0, Math.min(3, limit - edits.length))) {
            edge.weight = clamp(edge.weight + 0.035);
            edge.eligibility = clamp(edge.eligibility * 0.65);
            edits.push({kind: "strengthenWarmAssociation", target: edge.target,
                values: [edge.weight, edge.uncertainty, edge.eligibility]});
        }
    }

    const noisy = edges.filter(edge => edge.uncertainty >= 0.18 || (edge.eligibility >= 0.45 && edge.weight >= 0.12))
        .sort((a, b) => b.uncertainty - a.uncertainty
            || (input.residual ? 0 : b.eligibility - a.eligibility) || a.target - b.target);
    const noiseLimit = input.residual ? limit - edits.length : Math.min(4, limit - edits.length);
    for (const edge of noisy.slice(0, noiseLimit)) {
        edits.push({kind: "weakenNoisyLoop", target: edge.target,
            values: [Math.max(0.01, clamp(edge.weight * 0.76)), clamp(edge.uncertainty * 0.62), clamp(edge.eligibility * 0.50)]});
    }
    return edits;
}
