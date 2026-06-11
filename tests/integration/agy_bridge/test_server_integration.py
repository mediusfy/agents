import asyncio
import json
import sys

import pytest


@pytest.mark.asyncio
async def test_server_ping_integration():
    """
    Tests that the agy_bridge server can be started as a subprocess
    and responds to a 'ping' command.
    """
    proc = await asyncio.create_subprocess_exec(
        sys.executable,
        "-m",
        "orchestration.agy_bridge.server",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    command = json.dumps({"command": "ping"}) + "\n"

    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(input=command.encode()), timeout=5)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        pytest.fail("Server process timed out.")

    assert proc.returncode == 0

    response = json.loads(stdout)
    assert "response" in response
    assert response["response"] == "pong"
