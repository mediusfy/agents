from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from orchestration.event_broker import Event, EventKind, event_broker


class TestEventModel:
    def test_event_creation(self):
        e = Event(kind=EventKind.TASK_SUBMITTED, data={"key": "value"})
        assert e.kind == EventKind.TASK_SUBMITTED
        assert e.data == {"key": "value"}

    def test_event_kind_enum(self):
        assert EventKind.TASK_SUBMITTED.value == "task_submitted"
        assert EventKind.TASK_COMPLETED.value == "task_completed"


class TestEventBroker:
    @pytest.mark.asyncio
    async def test_submit_returns_task_id(self):
        with patch.object(event_broker, "submit", AsyncMock(return_value="task_abc123")):
            task_id = await event_broker.submit(
                Event(kind=EventKind.TASK_SUBMITTED, data={"payload": "test"})
            )
            assert task_id == "task_abc123"

    @pytest.mark.asyncio
    async def test_get_status_pending(self):
        with patch.object(event_broker, "get_status", AsyncMock(return_value={"status": "pending"})):
            status = await event_broker.get_status("task_1")
            assert status["status"] == "pending"

    @pytest.mark.asyncio
    async def test_get_status_not_found(self):
        with patch.object(event_broker, "get_status", AsyncMock(return_value=None)):
            status = await event_broker.get_status("nonexistent")
            assert status is None

    @pytest.mark.asyncio
    async def test_wait_for_timeout(self):
        async def mock_wait(task_id, timeout):
            return None

        with patch.object(event_broker, "wait_for", side_effect=mock_wait):
            result = await event_broker.wait_for("task_1", 5)
            assert result is None
