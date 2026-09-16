#!/usr/bin/env python3
"""Bounded, opt-in developer evaluation of NativeAgent conversations.

No invocation runs a scenario by default. Results are private evidence for human
review, not an automated success grade. An uncertain send is never retried.
"""
import argparse
import collections
import datetime
import ipaddress
import json
import os
from pathlib import Path
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

REPO = Path(__file__).resolve().parents[1]
MAX_RESPONSE = 2 * 1024 * 1024


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def exact_uuid(value):
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Expected a UUID") from error
    if str(parsed) != value.lower():
        raise argparse.ArgumentTypeError("Expected a hyphenated UUID")
    return value  # Receipt identity is exact; validation must not rewrite it.


def read_regular(path, maximum, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError("Input is not a bounded regular file")
        if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError("Bridge descriptor must be user-owned and private")
        data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("Input exceeded its size bound")
        return data


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Bridge:
    def __init__(self, descriptor):
        config = json.loads(read_regular(descriptor, 65536, private=True))
        parsed = urllib.parse.urlsplit(config["url"])
        # Literal IP only: no DNS rebinding, remote hosts, proxies, or redirects.
        if (parsed.scheme not in ("http", "https") or not parsed.hostname
                or not ipaddress.ip_address(parsed.hostname).is_loopback
                or parsed.username or parsed.password or parsed.query or parsed.fragment
                or parsed.path not in ("", "/")):
            raise ValueError("Bridge destination must be a literal loopback origin")
        self.base = config["url"].rstrip("/")
        self.token = config["token"]
        if not isinstance(self.token, str) or not self.token or "\n" in self.token or "\r" in self.token:
            raise ValueError("Invalid bridge credential")
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, body=None, timeout=10):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with self.opener.open(req, timeout=timeout) as response:
                raw = response.read(MAX_RESPONSE + 1)
                if len(raw) > MAX_RESPONSE:
                    return {"transport_error": "response_limit"}
                return {"http_status": response.status, "body": json.loads(raw)}
        except urllib.error.HTTPError as error:
            return {"http_status": error.code, "transport_error": "http_error"}
        except (OSError, ValueError, urllib.error.URLError):
            # Never expose exception URLs, headers, credentials, or opaque bodies.
            return {"transport_error": "request_failed_or_timed_out", "acceptance": "unknown"}


def save(directory, name, value):
    with (directory / name).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def receipts(data_root, session, run_id):
    coverage = {"complete": False, "scope": "exact_session_and_returned_run"}
    if not run_id:
        return [], dict(coverage, reason="no_returned_run_id")
    path = data_root / "chat" / "messages" / (session + ".jsonl")
    try:
        raw = read_regular(path, 32 * 1024 * 1024)
    except (OSError, ValueError):
        return [], dict(coverage, reason="transcript_unavailable_or_bounded_out")
    result = []
    malformed = 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            metadata = row.get("metadata", {})
            if isinstance(metadata, str):
                metadata = json.loads(metadata)
            if not isinstance(metadata, dict):
                raise ValueError("metadata")
            if (row.get("runId", metadata.get("runId")) != run_id or row.get("role") != "tool"
                    or row.get("sessionId") != session):
                continue
            # Strict allowlist: no assistant content, reasoning, context snapshots,
            # arbitrary metadata, or other sessions/runs is copied.
            if metadata.get("kind") not in ("tool_use", "approval_pending"):
                continue
            result.append({"id": row.get("id"), "createdAt": row.get("createdAt"),
                           "runId": run_id, "sessionId": session,
                           "metadata": {key: metadata[key] for key in
                                        ("kind", "toolName", "inputJSON", "resultSummary", "ok", "durationMs")
                                        if key in metadata}})
        except (ValueError, TypeError, AttributeError):
            malformed += 1
    return result, dict(coverage, complete=malformed == 0, malformed_rows=malformed,
                        note="One bounded transcript snapshot; later writes are not included.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--run", metavar="CASE")
    parser.add_argument("--allow-agent-sends", action="store_true")
    parser.add_argument("--session", type=exact_uuid)
    parser.add_argument("--request-id", type=exact_uuid)
    parser.add_argument("--bot-name")
    parser.add_argument("--wait-seconds", type=int, default=180)
    parser.add_argument("--poll-seconds", type=int, default=10)
    parser.add_argument("--descriptor", type=Path, default=Path.home() / ".config/claude-bridge/bridge.json")
    parser.add_argument("--data-root", type=Path, default=REPO / "data")
    parser.add_argument("--output-parent", type=Path, default=Path.home() / ".codex/agent-conversation-evals")
    args = parser.parse_args()
    catalog = json.loads((REPO / "docs/agent-conversation-scenarios.json").read_text())
    cases = {case["id"]: case for case in catalog["cases"]}
    if args.list or not args.run:
        print(json.dumps(catalog, indent=2))
        return
    if args.run not in cases:
        parser.error("Unknown scenario; use --list")
    case = cases[args.run]
    if not 0 <= args.wait_seconds <= 1800 or not 10 <= args.poll_seconds <= 60:
        parser.error("wait-seconds must be 0..1800 and poll-seconds 10..60")
    for required in case.get("requires", []):
        if not getattr(args, required):
            parser.error("This case requires --" + required.replace("_", "-"))
    if case["mode"] == "message" and not args.allow_agent_sends:
        parser.error("Sending any evaluation prompt requires --allow-agent-sends")
    if case["mode"] == "message" and args.request_id:
        parser.error("--request-id is observation-only; sends always receive a fresh identity")
    if args.bot_name and (len(args.bot_name) > 200 or any(ord(char) < 32 for char in args.bot_name)):
        parser.error("bot-name must be a short printable name")
    os.umask(0o077)
    bridge = Bridge(args.descriptor)
    args.output_parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output = args.output_parent / (args.run + "-" + str(uuid.uuid4()))
    output.mkdir(mode=0o700)
    session = args.session or str(uuid.uuid4()).upper()
    request_id = args.request_id or str(uuid.uuid4()).upper()
    manifest = {"case": case["id"], "tags": case["tags"], "coached": case["coached"],
                "session_id": session, "request_id": request_id, "started_at": now(),
                "send_attempts": 0, "review_required": True, "success": None,
                "session_reused": bool(args.session), "wait_seconds": args.wait_seconds}
    state = bridge.request("/codex/state")
    body = state.get("body", {})
    if not isinstance(body, dict):
        body = {}
    identity = body.get("buildIdentity", {})
    if not isinstance(identity, dict):
        identity = {}
    readiness = {key: body.get(key) for key in
                 ("chatReady", "buildVersion", "activeModel", "activeProvider", "uptimeSeconds")}
    readiness["buildIdentity"] = {key: identity.get(key) for key in
                                  ("version", "build", "sourceRevision", "sourceDirty", "exactSourceRevision")}
    context_flow = body.get("contextFlow", {})
    if not isinstance(context_flow, dict):
        context_flow = {}
    readiness["contextFlow"] = {key: context_flow.get(key) for key in
                                 ("mode", "started", "storeGeneration", "arenaGeneration", "degradedSources")}
    readiness["http_status"] = state.get("http_status")
    readiness["transport_error"] = state.get("transport_error")
    save(output, "readiness.json", readiness)
    save(output, "request.json", manifest)
    if case["mode"] == "message" and (state.get("http_status") != 200 or body.get("chatReady") is not True):
        manifest.update(finished_at=now(), stopped_reason="chat_not_ready", exact_reply_observed=False)
        save(output, "result.json", manifest)
        print(json.dumps({"result_directory": str(output), "send_attempts": 0, "stopped_reason": "chat_not_ready"}))
        return
    deadline = time.monotonic() + args.wait_seconds
    if case["mode"] == "message":
        prompt = case["prompt"].format(nonce="A2A-" + uuid.uuid4().hex[:12],
                                      missing_id=str(uuid.uuid4()), bot_name=args.bot_name)
        save(output, "prompt.json", {"text": prompt, "coached": False})
        manifest["send_attempts"] = 1
        # Exactly one HTTP attempt; timeout means uncertain admission, never retry.
        ack = bridge.request("/agent/message", {"text": prompt, "sessionId": session,
                                               "request_id": request_id}, timeout=min(10, max(1, args.wait_seconds)))
        save(output, "acknowledgement.json", ack)
    polls = []
    final = None
    last_poll = 0.0
    while time.monotonic() < deadline:
        sleep_for = max(0, args.poll_seconds - (time.monotonic() - last_poll))
        if sleep_for >= deadline - time.monotonic():
            break
        time.sleep(sleep_for)
        last_poll = time.monotonic()
        response = bridge.request("/agent/reply", {"request_id": request_id, "session_id": session,
                                                  "max_chars": 16000}, timeout=min(10, max(0.1, deadline - last_poll)))
        polls.append({"at": now(), "response": response})
        receipt = response.get("body", {})
        if not isinstance(receipt, dict):
            continue
        if (receipt.get("status") == "ok" and receipt.get("evidence") == "exact_receipt"
                and receipt.get("request_id") == request_id and receipt.get("session_id") == session):
            final = receipt
            break
    save(output, "reply-observations.json", polls)
    save(output, "final-reply.json", final)
    rows, coverage = receipts(args.data_root, session, final.get("run_id") if final else None)
    save(output, "tool-receipts.json", {"coverage": coverage, "rows": rows})
    manifest.update(finished_at=now(), exact_reply_observed=final is not None,
                    reply_has_more=final.get("has_more") if final else None,
                    run_id=final.get("run_id") if final else None,
                    tool_receipt_count=len(rows),
                    tool_counts=dict(collections.Counter(row["metadata"].get("toolName", "unknown") for row in rows)),
                    failed_tool_receipts=sum(row["metadata"].get("ok") is False for row in rows),
                    receipt_coverage=coverage)
    save(output, "result.json", manifest)
    print(json.dumps({"result_directory": str(output), "session_id": session, "request_id": request_id,
                      "exact_reply_observed": final is not None, "success": None}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        # No traceback or descriptor contents; evidence files retain safe context.
        raise SystemExit("Evaluation stopped: " + type(error).__name__ + "; inspect arguments and local bridge readiness.")
