
import json
from unittest.mock import patch, mock_open, AsyncMock
from openclaw.agy_bridge.server import _handle_command

@patch("openclaw.agy_bridge.server.registry")
@patch("openclaw.agy_bridge.server.BridgeAgent")
@patch("openclaw.agy_bridge.server.sync_agent_definitions", new_callable=AsyncMock)
async def test_sync_definitions_command(mock_sync, MockBridgeAgent, mock_registry):
    # Arrange
    mock_sync.return_value = 1
    
    # Act
    response = await _handle_command({"command": "sync-definitions"})
    
    # Assert
    assert response == {"response": {"synced": 1}}
    mock_sync.assert_called_once()
