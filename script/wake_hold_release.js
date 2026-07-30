#!/usr/bin/env node
// wake_hold_release.js — release a wake session's commit hold (task #49).
//
// Every wake job record is created with commitPolicy:"hold" (see
// claude_thread_wakeup.js claimRecord): the wake session builds and
// verifies but must not git commit/push until this script stamps
// holdReleasedAt/holdReleasedBy into its job record. Run by User or the
// interactive Claude from the CLI, or by Agent through her shell tool
// once her desk's verification step passes.
//
//   node script/wake_hold_release.js <jobId-or-messageId> --by user|agent|claude
//
// <jobId> matches the wake-jobs filename (with or without .json).
//
// AUTHORITY LIVES IN A SIDECAR, NOT THE JOB RECORD (gpt-5.5 BLOCKING,
// 2026-07-25): the runner rewrites <id>.json constantly (heartbeats,
// settlement) via read-merge-rename with no lock, so a release stamped into
// that file can be resurrected-away by a racing stale read. The release is
// therefore an O_EXCL-created wake-releases/<id>.json the runner NEVER
// writes — existence of that file IS the release, immune to lost updates by
// construction. Releases live in their OWN directory (delta re-review
// BLOCKING, 2026-07-25): a sidecar inside wake-jobs/ shares the job-record
// namespace, so a messageId of "<id>.release" would collide into it and the
// runner's dead-job takeover (renameJobAside) could rename the authority
// file aside. The runner never lists or writes wake-releases/. The job record is annotated best-effort for humans; the
// wake session's pre-commit check reads the sidecar. Idempotent: an
// existing sidecar reports the original stamp and changes nothing. Unknown
// or malformed jobs fail LOUD with exit 1 — a hold that cannot be found
// must never read as released.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

// Same override the wakeup runner honors — tests point both at a tmp root.
const BRIDGE_DIR = process.env.NATIVE_AGENT_CLAUDE_BRIDGE_DIR ||
  path.join(os.homedir(), ".config", "claude-bridge");
const WAKE_JOBS_DIR = path.join(BRIDGE_DIR, "wake-jobs");
const WAKE_RELEASES_DIR = path.join(BRIDGE_DIR, "wake-releases");
const ALLOWED_RELEASERS = new Set(["user", "agent", "claude"]);

function fail(reason, extra) {
  process.stdout.write(JSON.stringify({ status: "failed", reason, ...extra }, null, 2) + "\n");
  process.exit(1);
}

function writeJSONAtomic(target, value) {
  const dir = path.dirname(target);
  const tmp = path.join(dir, `.${path.basename(target)}.tmp-${process.pid}`);
  const fd = fs.openSync(tmp, "wx", 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(value, null, 2));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, target);
}

function main() {
  const args = process.argv.slice(2);
  const byIndex = args.indexOf("--by");
  const by = byIndex >= 0 ? String(args[byIndex + 1] || "").toLowerCase() : "";
  const positional = args.filter((a, i) => a !== "--by" && i !== byIndex + 1);
  const rawId = positional[0];

  if (!rawId) fail("missing_job_id", { usage: "wake_hold_release.js <jobId> --by user|agent|claude" });
  if (!ALLOWED_RELEASERS.has(by)) {
    fail("invalid_releaser", { got: by || null, allowed: [...ALLOWED_RELEASERS] });
  }
  // Filename-shape guard: job ids are uuid-ish; anything with a path
  // separator is an attempt to write outside wake-jobs/.
  const jobId = rawId.endsWith(".json") ? rawId.slice(0, -5) : rawId;
  if (!/^[A-Za-z0-9._-]+$/.test(jobId)) fail("invalid_job_id", { got: rawId });

  const jobPath = path.join(WAKE_JOBS_DIR, `${jobId}.json`);
  let record;
  try {
    record = JSON.parse(fs.readFileSync(jobPath, "utf8"));
  } catch (error) {
    fail("job_not_found_or_unreadable", { jobPath, error: String((error && error.message) || error) });
  }
  // gpt-5.5 MED: typeof [] === "object" — arrays and other non-plain shapes
  // must fail loud, and a record with no messageId is not a job.
  if (!record || typeof record !== "object" || Array.isArray(record)
      || typeof record.messageId !== "string" || record.messageId === "") {
    fail("job_malformed", { jobPath });
  }

  const releasePath = path.join(WAKE_RELEASES_DIR, `${jobId}.json`);
  try { fs.mkdirSync(WAKE_RELEASES_DIR, { recursive: true, mode: 0o700 }); } catch {}
  const stamp = { holdReleasedAt: new Date().toISOString(), holdReleasedBy: by, messageId: record.messageId };
  let fd;
  try {
    fd = fs.openSync(releasePath, "wx", 0o600);
  } catch (error) {
    if (error && error.code === "EEXIST") {
      let prior = null;
      try { prior = JSON.parse(fs.readFileSync(releasePath, "utf8")); } catch {}
      process.stdout.write(JSON.stringify({
        status: "already_released",
        releasePath,
        holdReleasedAt: (prior && prior.holdReleasedAt) || null,
        holdReleasedBy: (prior && prior.holdReleasedBy) || null,
      }, null, 2) + "\n");
      return;
    }
    fail("release_write_failed", { releasePath, error: String((error && error.message) || error) });
  }
  try {
    fs.writeFileSync(fd, JSON.stringify(stamp, null, 2));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }

  // Best-effort human-readable mirror in the job record. A racing runner
  // write may clobber this — that is FINE, the sidecar is the authority.
  try {
    const current = JSON.parse(fs.readFileSync(jobPath, "utf8"));
    if (current && typeof current === "object" && !Array.isArray(current)) {
      writeJSONAtomic(jobPath, { ...current, commitPolicy: "released",
        holdReleasedAt: stamp.holdReleasedAt, holdReleasedBy: by, updatedAt: stamp.holdReleasedAt });
    }
  } catch {}

  process.stdout.write(JSON.stringify({
    status: "released",
    releasePath,
    jobPath,
    holdReleasedAt: stamp.holdReleasedAt,
    holdReleasedBy: by,
  }, null, 2) + "\n");
}

main();
