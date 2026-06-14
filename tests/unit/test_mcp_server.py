import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from orchestration.mcp_server import run_agent_by_name


@pytest.fixture
def mock_registry():
    with patch("orchestration.mcp_server.registry") as mock_reg:
        yield mock_reg


@pytest.mark.asyncio
async def test_run_agent_by_name_local(mock_registry):
    # Setup mock agent
    mock_agent = AsyncMock()
    mock_result = MagicMock()
    mock_result.data = "local_result_data"
    mock_agent.run.return_value = mock_result

    mock_registry.get.return_value = mock_agent
    mock_registry._agents = {"test_agent": (None, None, lambda: {}, None)}

    with patch("orchestration.mcp_server.retrieve_context", return_value="some_context"):
        result = await run_agent_by_name("test_agent", "do local work", run_on_gks=False)

    assert result == "local_result_data"
    mock_agent.run.assert_called_once()


@pytest.mark.asyncio
async def test_run_agent_by_name_gks_success():
    mock_config = {"gateway": {"remote": {"url": "wss://test.gks.com", "token": "secret_token"}}}

    # Mock config reading
    mock_open = MagicMock()
    mock_open.return_value.__enter__.return_value.read.return_value = json.dumps(mock_config)

    # Mock subprocess
    mock_proc = AsyncMock()
    mock_proc.returncode = 0
    # Simulate a JSON response from orchestration gateway
    mock_proc.communicate.return_value = (b'{"result": "gks_result_data"}', b"")

    with (
        patch("orchestration.mcp_server.os.path.expanduser", return_value="dummy_path"),
        patch("builtins.open", mock_open),
        patch("json.load", return_value=mock_config),
        patch("asyncio.create_subprocess_exec", return_value=mock_proc) as mock_exec,
    ):
        result = await run_agent_by_name("test_agent", "do remote work", run_on_gks=True)

        assert result == "gks_result_data"

        # Verify the subprocess was called with correct arguments
        mock_exec.assert_called_once()
        args = mock_exec.call_args[0]
        assert "orchestration" in args
        assert "--url" in args
        assert "wss://test.gks.com" in args
        assert "--token" in args
        assert "secret_token" in args


@pytest.mark.asyncio
async def test_run_agent_by_name_gks_raw_fallback():
    mock_config = {"gateway": {"remote": {"url": "wss://test.gks.com", "token": "secret_token"}}}

    mock_open = MagicMock()

    mock_proc = AsyncMock()
    mock_proc.returncode = 0
    # Simulate a raw string response that is not JSON (e.g. CLI fallback or raw output)
    mock_proc.communicate.return_value = (b"raw string response", b"")

    with (
        patch("orchestration.mcp_server.os.path.expanduser", return_value="dummy_path"),
        patch("builtins.open", mock_open),
        patch("json.load", return_value=mock_config),
        patch("asyncio.create_subprocess_exec", return_value=mock_proc),
    ):
        result = await run_agent_by_name("test_agent", "do remote work", run_on_gks=True)

        assert result == "raw string response"


@pytest.mark.asyncio
async def test_run_agent_by_name_gks_error_code():
    mock_config = {"gateway": {"remote": {"url": "wss://test.gks.com", "token": "secret_token"}}}

    mock_open = MagicMock()

    mock_proc = AsyncMock()
    mock_proc.returncode = 1
    mock_proc.communicate.return_value = (b"", b"connection refused")

    with (
        patch("orchestration.mcp_server.os.path.expanduser", return_value="dummy_path"),
        patch("builtins.open", mock_open),
        patch("json.load", return_value=mock_config),
        patch("asyncio.create_subprocess_exec", return_value=mock_proc),
    ):
        result = await run_agent_by_name("test_agent", "do remote work", run_on_gks=True)

        assert "ERROR running on GKS" in result
        assert "connection refused" in result


@pytest.mark.asyncio
async def test_run_agent_by_name_gks_missing_config():
    # Empty config
    mock_config = {}

    mock_open = MagicMock()

    with (
        patch("orchestration.mcp_server.os.path.expanduser", return_value="dummy_path"),
        patch("builtins.open", mock_open),
        patch("json.load", return_value=mock_config),
    ):
        result = await run_agent_by_name("test_agent", "do remote work", run_on_gks=True)

        assert "ERROR: GKS remote URL or token is not configured" in result
