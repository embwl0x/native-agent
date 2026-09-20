#!/usr/bin/env python3
"""Run with `uv run --no-project tests/a2a_sdk/run.py` after both Swift builds.

All SDK dependencies, HOME, credentials and peer state live in system temp.
The official peer processes are terminated even when a Swift assertion fails.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nativeagent-a2a-") as temporary:
    scratch = Path(temporary)
    home = scratch / "home"
    home.mkdir()
    # Dependency code and peers must never inherit developer/CI credentials.
    env = {"PATH": os.environ.get("PATH", os.defpath),
           "HOME": str(home), "CFFIXED_USER_HOME": str(home),
           "TMPDIR": temporary, "UV_CACHE_DIR": str(scratch / "uv-cache"),
           "UV_NO_CONFIG": "1", "PIP_CONFIG_FILE": os.devnull,
           "NATIVE_AGENT_DATA_ROOT": str(scratch / "app-data"),
           "NATIVE_AGENT_WORKSPACE_ROOT": str(scratch / "workspace")}
    python = scratch / "venv/bin/python"
    subprocess.run(["uv", "venv", str(scratch / "venv")], env=env, check=True)
    subprocess.run(["uv", "pip", "install", "--python", str(python),
                    "a2a-sdk[http-server,grpc]==1.0.0", "protobuf>=6.33.5,<7", "uvicorn==0.53.0"], env=env, check=True)
    with (scratch / "peer.log").open("w+") as log:
        peer = subprocess.Popen([str(python), str(root / "tests/a2a_sdk/peer.py"), temporary],
                                env=env, stdout=log, stderr=log)
        try:
            manifest = scratch / "peers.json"
            for _ in range(100):
                if peer.poll() is not None:
                    raise RuntimeError("SDK peer exited before readiness")
                try:
                    entries = json.loads(manifest.read_text())
                    for entry in entries:
                        with urllib.request.urlopen(entry["url"], timeout=1) as response:
                            assert response.status == 200
                    break
                except (OSError, ValueError):
                    time.sleep(0.1)
            else:
                raise RuntimeError("SDK peer did not become ready")
            env["NATIVEAGENT_A2A_TEST_PEERS"] = str(manifest)
            subprocess.run(["swift", "test", "--disable-keychain", "--jobs", "4", "--package-path",
                            "Modules/NativeAgentCore", "--filter",
                            "AgentA2A|AgentCommunicationTests|AgentPeerTransportTests|AgentPeerDiscoveryTests"],
                           cwd=root, env=env, check=True)
            env["NATIVEAGENT_A2A_SDK_PYTHON"] = str(python)
            subprocess.run(["swift", "test", "--disable-keychain", "--jobs", "4", "--filter",
                            "NativeAgentA2A|AgentContactBearerTests|AgentContactRouteAuthenticationTests"],
                           cwd=root, env=env, check=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            peer.terminate()
            try:
                peer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                peer.kill()
                peer.wait()
