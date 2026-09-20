"""Generate pinned wire fixtures with a2a-sdk==1.0.0, in the temp venv.

Source: https://github.com/a2aproject/a2a-python/tree/v1.0.0
Uses the same serializers as the official server and its 0.3 adapter.
Output contains fixed synthetic identities; no hand-authored wire payloads.
"""
import importlib.metadata
import json
import sys
from pathlib import Path

from google.protobuf.json_format import MessageToDict
from a2a.types import (Message, Part, Role, SendMessageRequest, SendMessageConfiguration,
                       SendMessageResponse, Task, TaskStatus, TaskState, StreamResponse,
                       TaskStatusUpdateEvent, TaskArtifactUpdateEvent, Artifact)
from a2a.server.request_handlers.response_helpers import prepare_response_object as build_response, agent_card_to_dict
from a2a.compat.v0_3.conversions import (to_compat_agent_card, to_compat_send_message_request,
    to_compat_send_message_response, to_compat_stream_response, to_compat_task)
from peer import make_card

assert importlib.metadata.version("a2a-sdk") == "1.0.0"
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
message = Message(message_id="m1", role=Role.ROLE_USER, parts=[Part(text="Hello")])
request = SendMessageRequest(message=message, configuration=SendMessageConfiguration(return_immediately=True))
reply = SendMessageResponse(message=Message(message_id="m2", role=Role.ROLE_AGENT, parts=[Part(text="Hello from the SDK")]))
task = Task(id="t1", context_id="c1", status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED))
events = [StreamResponse(task=task)]
for state in [TaskState.TASK_STATE_WORKING, TaskState.TASK_STATE_INPUT_REQUIRED]:
    events.append(StreamResponse(status_update=TaskStatusUpdateEvent(task_id="t1", context_id="c1",
        status=TaskStatus(state=state, message=Message(message_id="m3", role=Role.ROLE_AGENT,
            parts=[Part(text="Please answer before I continue")])))))
artifact = StreamResponse(artifact_update=TaskArtifactUpdateEvent(task_id="t1", context_id="c1",
    artifact=Artifact(artifact_id="a1", parts=[Part(text="A"), Part(raw=b"sample", media_type="text/plain")]), last_chunk=True))
completed = Task(id="t1", context_id="c1", status=TaskStatus(state=TaskState.TASK_STATE_COMPLETED))

def dump(value):
    return value.model_dump(mode="json", by_alias=True, exclude_none=True)

for version in ["1.0", "0.3"]:
    card = make_card("http://127.0.0.1:9999", version)
    if version == "1.0":
        wire = {"card": agent_card_to_dict(card),
                "send": {"jsonrpc": "2.0", "id": "r1", "method": "SendMessage", "params": MessageToDict(request)},
                "reply": build_response("r1", reply, (SendMessageResponse,)),
                "task": build_response("r1", SendMessageResponse(task=task), (SendMessageResponse,)),
                "get": build_response("r1", completed, (Task,)),
                "events": [build_response("r1", event, (StreamResponse,)) for event in events],
                "artifact": build_response("r1", artifact, (StreamResponse,))}
    else:
        wire = {"card": dump(to_compat_agent_card(card)),
                "send": dump(to_compat_send_message_request(request, request_id="r1")),
                "reply": dump(to_compat_send_message_response(reply, request_id="r1")),
                "task": dump(to_compat_send_message_response(SendMessageResponse(task=task), request_id="r1")),
                "get": {"jsonrpc": "2.0", "id": "r1", "result": dump(to_compat_task(completed))},
                "events": [dump(to_compat_stream_response(event, request_id="r1")) for event in events],
                "artifact": dump(to_compat_stream_response(artifact, request_id="r1"))}
    (destination / f"sdk-{version}.json").write_text(json.dumps(wire, indent=2, sort_keys=True) + "\n")
