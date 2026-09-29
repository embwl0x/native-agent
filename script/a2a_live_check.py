# /// script
# requires-python = ">=3.11"
# dependencies = ["a2a-sdk[http-server,grpc]==1.0.0", "protobuf>=6.33.5,<7", "httpx>=0.28,<1"]
# ///
"""Call an already running app. Uses only A2A_BASE_URL and A2A_BEARER_TOKEN.

Exercises JSON-RPC, HTTP+JSON and gRPC, with three tasks and one cancellation each.
Runs its own temporary loopback webhook; the app listener is never changed. It never
reads local credentials/configuration or installs/restarts the application.
"""
import asyncio
import json
from contextlib import AsyncExitStack
from functools import partial
import ipaddress
import grpc
import os
from uuid import uuid4
from urllib.parse import urlsplit

import httpx
from google.protobuf.json_format import MessageToDict, ParseDict
from a2a.client import A2ACardResolver
from a2a.client.client import ClientCallContext
from a2a.client.transports.grpc import GrpcTransport
from a2a.client.transports.jsonrpc import JsonRpcTransport
from a2a.client.transports.rest import RestTransport
from a2a.types import (
    AgentCard, CancelTaskRequest, GetTaskRequest, ListTasksRequest,
    GetExtendedAgentCardRequest, TaskPushNotificationConfig,
    GetTaskPushNotificationConfigRequest, ListTaskPushNotificationConfigsRequest,
    DeleteTaskPushNotificationConfigRequest, StreamResponse,
    SendMessageRequest, SubscribeToTaskRequest, TaskState,
)


def show(label, value):
    if hasattr(value, "DESCRIPTOR"):
        value = MessageToDict(value)
    print(f"{label}: {json.dumps(value, ensure_ascii=False)}", flush=True)


def message(text, *, immediate=False, context=None, parts=None, push=None):
    body = {"message": {"messageId": str(uuid4()), "role": "ROLE_USER",
                        "parts": [{"text": text}] + (parts or [])},
            "configuration": {"returnImmediately": immediate}}
    if context:
        body["message"]["contextId"] = context
    if push:
        body["configuration"]["taskPushNotificationConfig"] = push
    return ParseDict(body, SendMessageRequest())


def endpoint(card, base, version, binding="JSONRPC"):
    interface = next(i for i in card.supported_interfaces
                     if i.protocol_version.startswith(version) and i.protocol_binding == binding)
    # gRPC is a separate loopback listener. Never forward the bearer off-host.
    original, selected = urlsplit(base), urlsplit(interface.url)
    if binding == "GRPC":
        if (original.scheme != "http" or selected.scheme != "http"
                or original.hostname != selected.hostname
                or not ipaddress.ip_address(selected.hostname).is_loopback
                or selected.port is None or selected.path not in ("", "/")):
            raise ValueError("Advertised gRPC endpoint must be on the same loopback host")
        return interface.url
    if (original.scheme, original.hostname, original.port) != (selected.scheme, selected.hostname, selected.port):
        raise ValueError("Advertised A2A endpoint differs from the supplied base URL origin")
    return interface.url


class Webhook:
    """Ephemeral loopback receiver, with strict official 1.0 payload decoding."""
    def __init__(self):
        self.bearer = uuid4().hex
        self.token = uuid4().hex
        self.receipts = asyncio.Queue()

    async def __aenter__(self):
        self.server = await asyncio.start_server(self.receive, "127.0.0.1", 0)
        self.url = f"http://127.0.0.1:{self.server.sockets[0].getsockname()[1]}/notify"
        return self

    async def __aexit__(self, *args):
        self.server.close()
        await self.server.wait_closed()

    async def receive(self, reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
            lines = head.decode("latin-1").split("\r\n")
            assert lines[0] == "POST /notify HTTP/1.1"
            original = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
            original = {k.lower(): v.strip() for k, v in original.items()}
            assert original.get("authorization") == "Bearer " + self.bearer
            assert original.get("x-a2a-notification-token") == self.token
            length = int(original.get("content-length", "0"))
            assert 0 < length <= 4 * 1024 * 1024
            payload = json.loads(await asyncio.wait_for(reader.readexactly(length), 10))
            event = ParseDict(payload, StreamResponse())
            assert event.WhichOneof("payload") is not None
            await self.receipts.put(event)
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
            await writer.drain()
        except Exception as error:
            await self.receipts.put(error)
        finally:
            writer.close()
            await writer.wait_closed()

    async def notification(self, task_id, state):
        async with asyncio.timeout(20):
            while True:
                event = await self.receipts.get()
                if isinstance(event, Exception):
                    raise event
                show("Push webhook delivered", event)
                if event.HasField("status_update"):
                    if event.status_update.task_id == task_id and event.status_update.status.state == state:
                        return
                if event.HasField("task"):
                    if event.task.id == task_id and event.task.status.state == state:
                        return


async def exercise(base, token, *, fixture=False, binding="JSONRPC"):
    print(f"Binding: {binding}", flush=True)
    headers = {"Authorization": "Bearer " + token, "A2A-Version": "1.0"}
    async with AsyncExitStack() as stack, Webhook() as webhook, httpx.AsyncClient(headers=headers, timeout=180, trust_env=False, follow_redirects=False) as http:
        card = await A2ACardResolver(http, base).get_agent_card()
        show("Agent card", card)
        advertised = {(i.protocol_binding, i.protocol_version) for i in card.supported_interfaces}
        assert {("JSONRPC", "1.0"), ("JSONRPC", "0.3"), ("HTTP+JSON", "1.0")} <= advertised
        assert card.capabilities.push_notifications
        assert card.capabilities.extended_agent_card
        # Resolver permits unknown fields; strict ProtoJSON parsing proves the
        # actual 1.0 card also has no removed legacy fields.
        raw_card = await http.get(base.rstrip("/") + "/.well-known/agent-card.json")
        ParseDict(raw_card.json(), AgentCard())
        selected = endpoint(card, base, "1.0", binding)
        if binding == "GRPC":
            channel = await stack.enter_async_context(grpc.aio.insecure_channel(urlsplit(selected).netloc))
            transport = GrpcTransport(channel, card)
            grpc_context = ClientCallContext(service_parameters={"authorization": "Bearer " + token}, timeout=180)
            # Supply metadata through the SDK public per-call context API.
            class AuthenticatedClient:
                def __getattr__(self, name):
                    return partial(getattr(transport, name), context=grpc_context)
            client = AuthenticatedClient()
        else:
            transport = JsonRpcTransport if binding == "JSONRPC" else RestTransport
            client = transport(http, card, selected)
        extended = await client.get_extended_agent_card(GetExtendedAgentCardRequest())
        show("GetExtendedAgentCard", extended)
        assert extended.name and extended.supported_interfaces
        if binding == "HTTP+JSON":
            response = await http.get(endpoint(card, base, "1.0", binding).rstrip("/") + "/extendedAgentCard")
            assert response.headers["content-type"].split(";")[0] == "application/a2a+json"
        parts = ([{"raw": "Zml4dHVyZQ==", "filename": "fixture.txt", "mediaType": "text/plain"},
                  {"data": [1, "two", True], "metadata": {"fixture": True}}] if fixture else [])
        inline_push = {"id": "sdk-send-time", "url": webhook.url, "token": webhook.token,
            "authentication": {"scheme": "Bearer", "credentials": webhook.bearer}}
        reply = await client.send_message(message("Reply briefly with hello for an A2A connection check.",
            parts=parts, push=inline_push))
        show("SendMessage", reply)
        assert reply.HasField("task") and reply.task.id
        task_id, context = reply.task.id, reply.task.context_id
        assert reply.task.status.state == TaskState.TASK_STATE_COMPLETED
        assert any(p.text for a in reply.task.artifacts for p in a.parts)
        await webhook.notification(task_id, TaskState.TASK_STATE_COMPLETED)
        show("SendMessage taskPushNotificationConfig delivery", {"taskId": task_id, "delivered": True})
        await client.delete_task_push_notification_config(
            DeleteTaskPushNotificationConfigRequest(task_id=task_id, id="sdk-send-time"))
        if fixture:
            output = [MessageToDict(p) for a in reply.task.artifacts for p in a.parts]
            assert any(p.get("raw") == "Zml4dHVyZQ==" for p in output)
            assert any(p.get("data") == [1, "two", True] for p in output)
        fetched = await client.get_task(GetTaskRequest(id=task_id, history_length=0))
        show("GetTask", fetched)
        assert fetched.id == task_id and fetched.status.state == TaskState.TASK_STATE_COMPLETED
        events = []
        async for event in client.send_message_streaming(message("Reply briefly with a streamed hello.", context=context)):
            show("SendStreamingMessage", event)
            events.append(event)
        assert events and events[0].HasField("task")
        assert any(e.HasField("artifact_update") or (e.HasField("task") and e.task.artifacts) for e in events)
        assert any((e.HasField("status_update") and e.status_update.status.state == TaskState.TASK_STATE_COMPLETED)
                   or (e.HasField("task") and e.task.status.state == TaskState.TASK_STATE_COMPLETED) for e in events)

        pending = await client.send_message(message(
            "This is a cancel connection check. Please write a long counting reply; I will cancel this task immediately.",
            immediate=True, context=context))
        show("SendMessage returnImmediately", pending)
        pending_id = pending.task.id
        config = ParseDict({"taskId": pending_id, "id": "sdk-proof", "url": webhook.url,
            "token": webhook.token, "authentication": {"scheme": "Bearer", "credentials": webhook.bearer}},
            TaskPushNotificationConfig())
        created = await client.create_task_push_notification_config(config)
        show("CreateTaskPushNotificationConfig", created)
        assert created.task_id == pending_id and created.id
        config_id = created.id
        fetched_config = await client.get_task_push_notification_config(
            GetTaskPushNotificationConfigRequest(task_id=pending_id, id=config_id))
        show("GetTaskPushNotificationConfig", fetched_config)
        assert fetched_config.url == webhook.url
        configs = await client.list_task_push_notification_configs(
            ListTaskPushNotificationConfigsRequest(task_id=pending_id))
        show("ListTaskPushNotificationConfigs", configs)
        assert config_id in {c.id for c in configs.configs}
        updates = client.subscribe(SubscribeToTaskRequest(id=pending_id))
        try:
            first = await anext(updates)
            show("SubscribeToTask", first)
            canceled = await client.cancel_task(CancelTaskRequest(id=pending_id))
            show("CancelTask", canceled)
            assert canceled.status.state == TaskState.TASK_STATE_CANCELED
            async for event in updates:
                show("SubscribeToTask", event)
        finally:
            await updates.aclose()

        await webhook.notification(pending_id, TaskState.TASK_STATE_CANCELED)
        await client.delete_task_push_notification_config(
            DeleteTaskPushNotificationConfigRequest(task_id=pending_id, id=config_id))
        show("DeleteTaskPushNotificationConfig", {"id": config_id, "deleted": True})
        configs = await client.list_task_push_notification_configs(
            ListTaskPushNotificationConfigsRequest(task_id=pending_id))
        assert config_id not in {c.id for c in configs.configs}

        listing = await client.list_tasks(ListTasksRequest(context_id=context, page_size=1, include_artifacts=True))
        show("ListTasks page 1", listing)
        seen = {t.id for t in listing.tasks}
        while listing.next_page_token:
            listing = await client.list_tasks(ListTasksRequest(context_id=context, page_size=1,
                include_artifacts=True, page_token=listing.next_page_token))
            show("ListTasks next page", listing)
            assert not seen.intersection(t.id for t in listing.tasks)
            seen.update(t.id for t in listing.tasks)
        assert {task_id, pending_id}.issubset(seen)
        filtered = await client.list_tasks(ListTasksRequest(context_id=context,
            status=TaskState.TASK_STATE_CANCELED))
        show("ListTasks canceled filter", filtered)
        assert pending_id in {t.id for t in filtered.tasks}
        assert all(t.status.state == TaskState.TASK_STATE_CANCELED and not t.artifacts for t in filtered.tasks)
        return card, task_id, context


async def main():
    for binding in ("JSONRPC", "HTTP+JSON", "GRPC"):
        await exercise(os.environ["A2A_BASE_URL"].rstrip("/"), os.environ["A2A_BEARER_TOKEN"], binding=binding)
    print("All eleven A2A 1.0 operations passed over JSON-RPC, HTTP+JSON and gRPC; authenticated push delivered.", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
