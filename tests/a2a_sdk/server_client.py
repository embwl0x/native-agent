"""Official 1.0 + 0.3 SDK clients against the temporary Swift app server."""
import asyncio
import os
from grpc_status import rpc_status
from google.rpc import error_details_pb2
from urllib.parse import urlsplit
import grpc
from a2a.types import a2a_pb2, a2a_pb2_grpc

import httpx
from google.protobuf.json_format import ParseDict
from a2a.client import A2ACardResolver
from a2a.compat.v0_3.jsonrpc_transport import CompatJsonRpcTransport
from a2a.compat.v0_3.types import AgentCard as LegacyCard
from a2a.types import GetTaskRequest, TaskState
from call_live_server import endpoint, exercise, message, show


async def grpc_boundaries(card, base, token, task_id):
    """Official generated client proves metadata auth and task ownership."""
    address = urlsplit(endpoint(card, base, "1.0", "GRPC")).netloc
    async with grpc.aio.insecure_channel(address) as channel:
        stub = a2a_pb2_grpc.A2AServiceStub(channel)
        async def rejected(method, request, code, metadata=(), stream=False, reason=None):
            try:
                call = getattr(stub, method)(request, metadata=metadata, timeout=10)
                if stream:
                    await call.read()
                else:
                    await call
            except grpc.aio.AioRpcError as error:
                assert error.code() == code, (method, error.code(), error.details())
                if reason is not None:
                    status = rpc_status.from_call(error)
                    assert status is not None, "Missing grpc-status-details-bin"
                    infos = []
                    for detail in status.details:
                        if detail.Is(error_details_pb2.ErrorInfo.DESCRIPTOR):
                            info = error_details_pb2.ErrorInfo()
                            detail.Unpack(info)
                            infos.append(info)
                    assert any(info.domain == "a2a-protocol.org" and info.reason == reason for info in infos), infos
            else:
                raise AssertionError(f"{method} unexpectedly accepted")
        unary = [
            ("SendMessage", a2a_pb2.SendMessageRequest()),
            ("GetTask", a2a_pb2.GetTaskRequest(id=task_id)),
            ("ListTasks", a2a_pb2.ListTasksRequest()),
            ("CancelTask", a2a_pb2.CancelTaskRequest(id=task_id)),
            ("GetExtendedAgentCard", a2a_pb2.GetExtendedAgentCardRequest()),
            ("CreateTaskPushNotificationConfig", a2a_pb2.TaskPushNotificationConfig()),
            ("GetTaskPushNotificationConfig", a2a_pb2.GetTaskPushNotificationConfigRequest()),
            ("ListTaskPushNotificationConfigs", a2a_pb2.ListTaskPushNotificationConfigsRequest()),
            ("DeleteTaskPushNotificationConfig", a2a_pb2.DeleteTaskPushNotificationConfigRequest()),
        ]
        for method, request in unary:
            await rejected(method, request, grpc.StatusCode.UNAUTHENTICATED)
        for method, request in [("SendStreamingMessage", a2a_pb2.SendMessageRequest()),
                                ("SubscribeToTask", a2a_pb2.SubscribeToTaskRequest(id=task_id))]:
            await rejected(method, request, grpc.StatusCode.UNAUTHENTICATED, stream=True)
        other = (("authorization", "Bearer " + os.environ["A2A_OTHER_TOKEN"]), ("a2a-version", "1.0"))
        assert not (await stub.ListTasks(a2a_pb2.ListTasksRequest(), metadata=other)).tasks
        for method, request in [("GetTask", a2a_pb2.GetTaskRequest(id=task_id)),
                                ("CancelTask", a2a_pb2.CancelTaskRequest(id=task_id))]:
            await rejected(method, request, grpc.StatusCode.NOT_FOUND, other)
        await rejected("SubscribeToTask", a2a_pb2.SubscribeToTaskRequest(id=task_id),
                       grpc.StatusCode.NOT_FOUND, other, stream=True)
        own = (("authorization", "Bearer " + token), ("a2a-version", "1.0"))
        await rejected("ListTasks", a2a_pb2.ListTasksRequest(page_size=101), grpc.StatusCode.INVALID_ARGUMENT, own)
        await rejected("GetTask", a2a_pb2.GetTaskRequest(id="missing-sdk-task"), grpc.StatusCode.NOT_FOUND,
                       own, reason="TASK_NOT_FOUND")
        future = (("authorization", "Bearer " + token), ("a2a-version", "2.0"))
        await rejected("GetExtendedAgentCard", a2a_pb2.GetExtendedAgentCardRequest(),
                       grpc.StatusCode.UNIMPLEMENTED, future, reason="VERSION_NOT_SUPPORTED")
        existing = await stub.GetTask(a2a_pb2.GetTaskRequest(id=task_id), metadata=own)
        context_id = existing.context_id
        try:
            await stub.SendMessage(message("cancel fixture after RPC deadline", context=context_id),
                                   metadata=own, timeout=0.2)
        except grpc.aio.AioRpcError as error:
            assert error.code() == grpc.StatusCode.DEADLINE_EXCEEDED, error
        else:
            raise AssertionError("Blocking send ignored deadline")
        listing = await stub.ListTasks(a2a_pb2.ListTasksRequest(context_id=context_id), metadata=own, timeout=10)
        active = [task for task in listing.tasks if task.status.state in (
            TaskState.TASK_STATE_SUBMITTED, TaskState.TASK_STATE_WORKING)]
        assert len(active) == 1, listing
        pending = active[0]
        assert pending.status.state in (TaskState.TASK_STATE_SUBMITTED, TaskState.TASK_STATE_WORKING), pending
        canceled = await stub.CancelTask(a2a_pb2.CancelTaskRequest(id=pending.id), metadata=own, timeout=10)
        assert canceled.status.state == TaskState.TASK_STATE_CANCELED, canceled
        show("gRPC deadline preserves task until explicit CancelTask", canceled)


async def main():
    base, token = os.environ["A2A_BASE_URL"], os.environ["A2A_BEARER_TOKEN"]
    card, task_id, context = await exercise(base, token, fixture=True)
    await exercise(base, token, fixture=True, binding="HTTP+JSON")
    await exercise(base, token, fixture=True, binding="GRPC")
    await grpc_boundaries(card, base, token, task_id)
    async with httpx.AsyncClient(headers={"Authorization": "Bearer " + token, "A2A-Version": "0.3"},
                                 timeout=10, trust_env=False) as http:
        raw = await http.get(base + "/.well-known/agent-card.json")
        LegacyCard.model_validate(raw.json())
        old_card = await A2ACardResolver(http, base).get_agent_card()
        client = CompatJsonRpcTransport(http, old_card, endpoint(card, base, "0.3"))
        reply = await client.send_message(message("Legacy hello", parts=[{"data": {"legacy": True}}]))
        show("0.3 SendMessage", reply)
        assert reply.task.status.state == TaskState.TASK_STATE_COMPLETED
        fetched = await client.get_task(GetTaskRequest(id=reply.task.id))
        assert fetched.id == reply.task.id
        async for event in client.send_message_streaming(message("Legacy stream")):
            show("0.3 stream", event)
    async with httpx.AsyncClient(timeout=10, trust_env=False) as http:
        # No auth, even a malformed or expensive request stops at the door.
        for method, path in [("POST", "/a2a"), ("GET", "/.well-known/agent-card.json"),
                             ("POST", "/a2a/message:send"), ("GET", "/a2a/extendedAgentCard"),
                             ("GET", "/a2a/tasks"), ("POST", f"/a2a/tasks/{task_id}/pushNotificationConfigs")]:
            response = await http.request(method, base + path, content=b"not json")
            assert response.status_code == 401
        url = base + "/a2a"
        headers = {"Authorization": "Bearer " + os.environ["A2A_OTHER_TOKEN"], "A2A-Version": "1.0"}
        async def rpc(method, params, use_headers=headers):
            return (await http.post(url, headers=use_headers,
                json={"jsonrpc": "2.0", "id": "boundary", "method": method, "params": params})).json()
        assert (await rpc("ListTasks", {}))["result"]["tasks"] == []
        for method in ["GetTask", "CancelTask", "SubscribeToTask"]:
            assert (await rpc(method, {"id": task_id}))["error"]["code"] == -32001
        ours = {"Authorization": "Bearer " + token, "A2A-Version": "1.0"}
        for params in [{"pageSize": 0}, {"pageSize": 101}, {"pageSize": True}, {"pageToken": "bad"},
                       {"status": "completed"}, {"historyLength": -1}, {"statusTimestampAfter": "yesterday"}]:
            assert (await rpc("ListTasks", params, ours))["error"]["code"] == -32602
        future = await rpc("ListTasks", {"statusTimestampAfter": "9999-01-01T00:00:00Z"}, ours)
        assert future["result"]["tasks"] == []
        first = (await rpc("ListTasks", {"pageSize": 1}, ours))["result"]
        assert first["nextPageToken"]
        assert (await rpc("ListTasks", {"pageSize": 1, "pageToken": first["nextPageToken"]}))["error"]["code"] == -32602
        assert (await rpc("SendMessage", {}, {**ours, "A2A-Version": "2.0"}))["error"]["code"] == -32009
        for bad_url in ["http://example.com/hook", "https://169.254.169.254/latest/meta-data/", "https://[fe80::1]/hook"]:
            result = await rpc("CreateTaskPushNotificationConfig", {"taskId": task_id, "id": "unsafe",
                "url": bad_url}, ours)
            assert "error" in result, result
        assert "error" in await rpc("GetTaskPushNotificationConfig", {"taskId": task_id, "id": "sdk-proof"})
    print("PASS: SDK 1.0 and 0.3, REST, gRPC, extended card, push CRUD/delivery, parts, pagination, filters, auth and peer isolation", flush=True)


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(main(), timeout=90))
