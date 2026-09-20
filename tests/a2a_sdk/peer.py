"""Test-only agent using the official SDK's routes, handlers, store and codecs.

No model, NativeAgent server, real credentials, or live application data.
"""
import asyncio
import json
import os
import socket
import sys
from pathlib import Path

import httpx
import grpc
from a2a.server.request_handlers.grpc_handler import GrpcHandler
from a2a.types.a2a_pb2_grpc import add_A2AServiceServicer_to_server
import uvicorn
from google.protobuf.json_format import ParseDict
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

from a2a.helpers import new_task_from_user_message, new_text_message, new_text_status_update_event
from a2a.server.agent_execution import AgentExecutor
from a2a.server.context import ServerCallContext
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes, create_rest_routes
from a2a.server.tasks import InMemoryTaskStore, InMemoryPushNotificationConfigStore, BasePushNotificationSender
from a2a.types import AgentCard, TaskState, StreamResponse


class Executor(AgentExecutor):
    def __init__(self):
        self.canceled = set()

    async def execute(self, context, event_queue):
        text = context.get_user_input()
        if text == "hello":
            await event_queue.enqueue_event(new_text_message("Hello from the SDK"))
            return
        task = context.current_task or new_task_from_user_message(context.message)
        await event_queue.enqueue_event(task)
        state = TaskState.TASK_STATE_WORKING
        if text == "input":
            state = TaskState.TASK_STATE_INPUT_REQUIRED
        elif text == "auth":
            state = TaskState.TASK_STATE_AUTH_REQUIRED
        await event_queue.enqueue_event(new_text_status_update_event(
            task_id=task.id, context_id=task.context_id, state=state,
            text="Please answer before I continue" if text == "input" else "Working"))
        if text in ("input", "auth"):
            return
        await asyncio.sleep(1 if text != "cancel" else 30)
        if task.id not in self.canceled:
            await event_queue.enqueue_event(new_text_status_update_event(
                task_id=task.id, context_id=task.context_id,
                state=TaskState.TASK_STATE_COMPLETED, text="Finished by the SDK"))

    async def cancel(self, context, event_queue):
        task = context.current_task
        self.canceled.add(task.id)
        await event_queue.enqueue_event(new_text_status_update_event(
            task_id=task.id, context_id=task.context_id,
            state=TaskState.TASK_STATE_CANCELED, text="Stopped"))


class Disconnected(Exception):
    pass


class Boundary:
    """Auth and deliberate connection loss around the unmodified SDK wire."""
    def __init__(self, app, token, revoke_file):
        self.app, self.token, self.revoke_file = app, token, revoke_file

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        if scope["path"] not in ("/.well-known/agent-card.json", "/incompatible.json", "/notify") and (
            self.revoke_file.exists() or headers.get(b"authorization") != ("Bearer " + self.token).encode()
        ):
            return await JSONResponse({"detail": "Access refused"}, status_code=401)(scope, receive, send)
        body = bytearray()
        while True:
            message = await receive()
            body.extend(message.get("body", b""))
            if not message.get("more_body", False):
                break
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        cut = b'"interrupt"' in body
        async def forward(message):
            if cut and message["type"] == "http.response.body" and (
                b'TASK_STATE_WORKING' in message.get("body", b'') or b'"working"' in message.get("body", b'')
            ):
                await send({**message, "more_body": False})
                raise Disconnected()
            await send(message)

        try:
            await self.app(scope, replay, forward)
        except BaseException as error:
            # SSE implementations may wrap the deliberate disconnection.
            def only_disconnect(value):
                return isinstance(value, Disconnected) or (
                    isinstance(value, BaseExceptionGroup) and all(only_disconnect(e) for e in value.exceptions))
            if not only_disconnect(error):
                raise


class GRPCBoundary(grpc.aio.ServerInterceptor):
    """Authenticate before the SDK handler; simulate a broken streaming peer."""
    def __init__(self, token, revoke_file):
        self.token, self.revoke_file = token, revoke_file

    async def intercept_service(self, continuation, details):
        handler = await continuation(details)
        metadata = dict(details.invocation_metadata)
        denied = self.revoke_file.exists() or metadata.get("authorization") != "Bearer " + self.token
        async def unary(request, context):
            if denied:
                await context.abort(grpc.StatusCode.UNAUTHENTICATED, "Access refused")
            return await handler.unary_unary(request, context)
        async def stream(request, context):
            if denied:
                await context.abort(grpc.StatusCode.UNAUTHENTICATED, "Access refused")
            cut = any(p.text == "interrupt" for p in request.message.parts) if hasattr(request, "message") else False
            async for event in handler.unary_stream(request, context):
                yield event
                if cut and event.HasField("status_update") and event.status_update.status.state == TaskState.TASK_STATE_WORKING:
                    await context.abort(grpc.StatusCode.UNAVAILABLE, "Fixture stream interrupted")
        factory = grpc.unary_stream_rpc_method_handler if handler.response_streaming else grpc.unary_unary_rpc_method_handler
        return factory(stream if handler.response_streaming else unary,
                       request_deserializer=handler.request_deserializer, response_serializer=handler.response_serializer)


def make_card(base, version, binding="JSONRPC", grpc_url=None):
    # Advertise the protocol under test first; clients honor this preference.
    interfaces = [{"url": base + "/rpc", "protocolBinding": "JSONRPC", "protocolVersion": "0.3"}]
    if version == "1.0":
        interfaces.insert(0, {"url": grpc_url if binding == "GRPC" else base + ("/rest" if binding == "HTTP+JSON" else "/rpc"),
                           "protocolBinding": binding, "protocolVersion": "1.0"})
    return ParseDict({
        "name": "SDK test peer", "description": "Temporary interoperability peer", "version": "1",
        "supportedInterfaces": interfaces, "capabilities": {"streaming": True,
            "extendedAgentCard": version == "1.0", "pushNotifications": version == "1.0"},
        "defaultInputModes": ["text/plain"], "defaultOutputModes": ["text/plain"],
        "skills": [{"id": "test", "name": "Test", "description": "Interoperability", "tags": ["test"]}],
        "securitySchemes": {"token": {"httpAuthSecurityScheme": {"scheme": "bearer"}}},
        "securityRequirements": [{"schemes": {"token": {"list": []}}}],
    }, AgentCard())


async def main():
    directory = Path(sys.argv[1])
    servers, sockets, entries, grpc_servers = [], [], [], []
    for version, binding in [("1.0", "JSONRPC"), ("0.3", "JSONRPC"), ("1.0", "HTTP+JSON"), ("1.0", "GRPC")]:
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        sock.listen(128)
        sockets.append(sock)
        base = f"http://127.0.0.1:{sock.getsockname()[1]}"
        token = os.urandom(24).hex()
        revoke = directory / f"revoke-{len(entries)}"
        grpc_server = None
        grpc_url = None
        if binding == "GRPC":
            grpc_server = grpc.aio.server(interceptors=[GRPCBoundary(token, revoke)])
            grpc_port = grpc_server.add_insecure_port("127.0.0.1:0")
            grpc_url = f"http://127.0.0.1:{grpc_port}"
        card = make_card(base, version, binding, grpc_url)
        extended = AgentCard()
        extended.CopyFrom(card)
        extended.name = "SDK test peer extended"
        push_store = InMemoryPushNotificationConfigStore()
        push_sender = BasePushNotificationSender(httpx.AsyncClient(timeout=5, trust_env=False,
            follow_redirects=False), push_store, ServerCallContext())
        handler = DefaultRequestHandler(agent_executor=Executor(), task_store=InMemoryTaskStore(), agent_card=card,
            extended_agent_card=extended if version == "1.0" else None,
            push_config_store=push_store, push_sender=push_sender)
        if grpc_server is not None:
            add_A2AServiceServicer_to_server(GrpcHandler(handler), grpc_server)
            await grpc_server.start()
            grpc_servers.append(grpc_server)
        routes = create_agent_card_routes(card)
        routes += create_jsonrpc_routes(handler, rpc_url="/rpc", enable_v0_3_compat=True)
        routes += create_rest_routes(handler, path_prefix="/rest")
        async def incompatible(request):
            return JSONResponse({"supportedInterfaces": [{"url": str(request.base_url) + "rpc",
                "protocolVersion": "9.0", "protocolBinding": "JSONRPC"}]})
        routes.append(Route("/incompatible.json", incompatible))
        # Real reachable fixture sink used for client push-registration proof.
        async def notify(request):
            payload = await request.json()
            event = ParseDict(payload, StreamResponse())
            if event.WhichOneof("payload") is None:
                return JSONResponse({"error": "Missing notification payload"}, status_code=400)
            return JSONResponse({})
        routes.append(Route("/notify", notify, methods=["POST"]))
        server = uvicorn.Server(uvicorn.Config(Boundary(Starlette(routes=routes), token, revoke),
                                               log_level="error", lifespan="off"))
        servers.append(asyncio.create_task(server.serve(sockets=[sock])))
        entries.append({"url": base + "/.well-known/agent-card.json", "version": version,
                        "binding": binding, "token": token, "revoke": str(revoke), "webhook": base + "/notify"})
    (directory / "peers.json").write_text(json.dumps(entries))
    try:
        await asyncio.gather(*servers)
    finally:
        await asyncio.gather(*(server.stop(0) for server in grpc_servers))


if __name__ == "__main__":
    asyncio.run(main())
