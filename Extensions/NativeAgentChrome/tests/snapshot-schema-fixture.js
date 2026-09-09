import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const schema = JSON.parse(await readFile(new URL("../protocol/protocol-v1.schema.json", import.meta.url), "utf8"));

// Offline fixture validator for the vocabulary used by structuredPageSnapshot.
// Unknown validation keywords fail, so schema growth cannot silently skip a rule.
function validate(value, rule) {
  const supported = new Set(["$ref", "type", "properties", "additionalProperties", "required", "items",
    "enum", "const", "oneOf", "uniqueItems", "minimum", "maximum", "maxItems", "maxLength", "minLength", "pattern", "format"]);
  for (const key of Object.keys(rule)) assert.ok(supported.has(key), `Unsupported fixture keyword: ${key}`);
  if (rule.$ref) return validate(value, rule.$ref.split("/").slice(1).reduce((node, key) => node[key], schema));
  if (rule.oneOf) {
    const matches = rule.oneOf.filter((branch) => { try { validate(value, branch); return true; } catch { return false; } });
    assert.equal(matches.length, 1);
  }
  if (rule.type) {
    const types = [].concat(rule.type);
    assert.ok(types.some((type) => type === "null" ? value === null
      : type === "array" ? Array.isArray(value) : type === "integer" ? Number.isInteger(value)
        : type === "object" ? value !== null && typeof value === "object" && !Array.isArray(value)
          : typeof value === type), `Expected ${types}, got ${JSON.stringify(value)}`);
  }
  if (rule.enum) assert.ok(rule.enum.includes(value), `Invalid enum: ${value}`);
  if ("const" in rule) assert.deepEqual(value, rule.const);
  if (typeof value === "number") {
    if (rule.minimum !== undefined) assert.ok(value >= rule.minimum);
    if (rule.maximum !== undefined) assert.ok(value <= rule.maximum);
  }
  if (typeof value === "string") {
    if (rule.maxLength !== undefined) assert.ok([...value].length <= rule.maxLength);
    if (rule.minLength !== undefined) assert.ok([...value].length >= rule.minLength);
    if (rule.pattern) assert.match(value, new RegExp(rule.pattern));
    if (rule.format === "date-time") assert.ok(Number.isFinite(Date.parse(value)));
    else if (rule.format === "uri") assert.ok(new URL(value));
    else assert.equal(rule.format, undefined);
  }
  if (Array.isArray(value)) {
    if (rule.maxItems !== undefined) assert.ok(value.length <= rule.maxItems);
    if (rule.uniqueItems) assert.equal(new Set(value.map((item) => JSON.stringify(item))).size, value.length);
    if (rule.items) for (const item of value) validate(item, rule.items);
  } else if (value && typeof value === "object") {
    for (const key of rule.required ?? []) assert.ok(Object.hasOwn(value, key), `Missing ${key}`);
    for (const [key, item] of Object.entries(value)) {
      if (rule.properties?.[key]) validate(item, rule.properties[key]);
      else assert.notEqual(rule.additionalProperties, false, `Unexpected ${key}`);
    }
  }
}

export function assertSnapshotSchema(snapshot) { validate(snapshot, schema.$defs.structuredPageSnapshot); }
