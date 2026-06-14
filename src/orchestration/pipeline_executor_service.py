"""
Pipeline Executor service — runs agent SDLC pipelines as a long-lived GKE pod.

Connects to NATS JetStream to receive work requests, runs the LangGraph
pipeline via pipeline_jobs, and publishes results back to NATS.
"""

import asyncio
import json
import logging
import os

import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from orchestration.agents.registration import register_all_agents
from orchestration.observability import configure_observability
from orchestration.pipeline_jobs import get_pipeline_run, submit_pipeline_run

logger = logging.getLogger(__name__)

NATS_URL = os.environ.get("NATS_URL", "nats://localhost:4222")
NATS_CONSUMER_GROUP = os.environ.get("NATS_CONSUMER_GROUP", "pipeline-executor")
WORK_SUBJECT = "agents.orchestrator.inbox"
RESULT_SUBJECT = "agents.orchestrator.results"

configure_observability()
register_all_agents()

app = FastAPI(title="Pipeline Executor")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/ready")
async def ready():
    return {"status": "ready"}


@app.post("/pipeline")
async def trigger_pipeline(project: str, requirement: str = ""):
    run_id = await submit_pipeline_run(project, requirement)
    run = await get_pipeline_run(run_id)
    return {"run_id": run_id, "status": run.get("status", "pending") if run else "pending"}


@app.get("/pipeline/{run_id}")
async def pipeline_status(run_id: str):
    run = await get_pipeline_run(run_id)
    if not run:
        return JSONResponse(status_code=404, content={"error": "not found"})
    return {
        "run_id": run_id,
        "status": run.get("status", "unknown"),
        "result": run.get("result"),
        "error": run.get("error"),
        "elapsed_seconds": run.get("elapsed_seconds"),
    }


async def _nats_listener():
    try:
        from nats import connect as nats_connect
        from nats.js import JetStreamContext

        nc = await nats_connect(NATS_URL, name="pipeline-executor")
        js: JetStreamContext = nc.jetstream()

        await js.add_stream(name="orchestrator", subjects=[WORK_SUBJECT, RESULT_SUBJECT])

        sub = await js.subscribe(WORK_SUBJECT, durable=NATS_CONSUMER_GROUP)
        logger.info("NATS listener started on %s (consumer group: %s)", WORK_SUBJECT, NATS_CONSUMER_GROUP)

        async for msg in sub.messages:
            try:
                data = json.loads(msg.data.decode())
                project = data.get("project", "default")
                requirement = data.get("requirement", "")
                logger.info("Pipeline request received: project=%s", project)
                run_id = await submit_pipeline_run(project, requirement)
                await js.publish(RESULT_SUBJECT, json.dumps({"run_id": run_id, "project": project, "status": "started"}).encode())
                await msg.ack()
            except Exception as e:
                logger.error("Failed to process NATS message: %s", e)
                await msg.term()
    except Exception as e:
        logger.warning("NATS not available: %s — running in HTTP-only mode", e)


@app.on_event("startup")
async def startup():
    asyncio.create_task(_nats_listener())


def main():
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
