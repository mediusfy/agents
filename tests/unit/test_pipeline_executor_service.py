"""Tests for the Pipeline Executor FastAPI service."""

from unittest.mock import AsyncMock, patch

import pytest

from orchestration.pipeline_executor_service import app


@pytest.fixture
def client():
    """FastAPI test client."""
    from fastapi.testclient import TestClient
    with TestClient(app) as c:
        yield c


class TestHealthEndpoint:
    def test_health_returns_ok(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}

    def test_ready_returns_ready(self, client):
        resp = client.get("/ready")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ready"}


class TestPipelineTrigger:
    @patch("orchestration.pipeline_executor_service.submit_pipeline_run", new_callable=AsyncMock)
    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_trigger_pipeline_returns_run_id(self, mock_get_run, mock_submit, client):
        mock_submit.return_value = "pipe_test123"
        mock_get_run.return_value = {"status": "pending"}

        resp = client.post("/pipeline?project=test-project&requirement=Build+a+test")

        assert resp.status_code == 200
        data = resp.json()
        assert data["run_id"] == "pipe_test123"
        assert data["status"] == "pending"

    @patch("orchestration.pipeline_executor_service.submit_pipeline_run", new_callable=AsyncMock)
    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_trigger_multiple_pipelines(self, mock_get_run, mock_submit, client):
        mock_submit.side_effect = [f"pipe_{i}abc" for i in range(3)]
        mock_get_run.return_value = {"status": "pending"}

        resp1 = client.post("/pipeline?project=proj-a&requirement=Req+A")
        resp2 = client.post("/pipeline?project=proj-b&requirement=Req+B")
        resp3 = client.post("/pipeline?project=proj-c&requirement=Req+C")

        assert resp1.json()["run_id"] == "pipe_0abc"
        assert resp2.json()["run_id"] == "pipe_1abc"
        assert resp3.json()["run_id"] == "pipe_2abc"

    @patch("orchestration.pipeline_executor_service.submit_pipeline_run", new_callable=AsyncMock)
    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_trigger_without_requirement(self, mock_get_run, mock_submit, client):
        mock_submit.return_value = "pipe_no_req"
        mock_get_run.return_value = {"status": "pending"}

        resp = client.post("/pipeline?project=test")
        assert resp.status_code == 200
        assert resp.json()["run_id"] == "pipe_no_req"


class TestPipelineStatus:
    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_status_returns_pending(self, mock_get_run, client):
        mock_get_run.return_value = {"status": "pending"}

        resp = client.get("/pipeline/pipe_123")
        assert resp.status_code == 200
        assert resp.json()["status"] == "pending"

    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_status_returns_completed(self, mock_get_run, client):
        mock_get_run.return_value = {"status": "completed", "elapsed_seconds": 45.2, "result": "Done"}

        resp = client.get("/pipeline/pipe_456")
        assert resp.status_code == 200
        assert resp.json()["status"] == "completed"
        assert resp.json()["elapsed_seconds"] == 45.2
        assert resp.json()["result"] == "Done"

    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_status_returns_404_for_unknown(self, mock_get_run, client):
        mock_get_run.return_value = None

        resp = client.get("/pipeline/nonexistent_run")
        assert resp.status_code == 404
        assert resp.json()["error"] == "not found"

    @patch("orchestration.pipeline_executor_service.get_pipeline_run", new_callable=AsyncMock)
    def test_status_returns_error(self, mock_get_run, client):
        mock_get_run.return_value = {"status": "failed", "error": "ValueError: something broke"}

        resp = client.get("/pipeline/pipe_fail")
        assert resp.status_code == 200
        assert resp.json()["status"] == "failed"
        assert "something broke" in resp.json()["error"]
