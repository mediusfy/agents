import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from semantic_router import Route
from semantic_router.encoders import HuggingFaceEncoder
from semantic_router.layer import RouteLayer

LITELLM_URL = os.environ.get("LITELLM_URL", "http://localhost:4000")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.client = httpx.AsyncClient(timeout=120.0)
    yield
    await app.state.client.aclose()


app = FastAPI(title="Semantic Router Gateway", lifespan=lifespan)

# ── Route Definitions ──────────────────────────────────────────────────────

orchestrator = Route(
    name="orchestrator",
    utterances=[
        "design a database schema for our order management service",
        "solve this complex performance bottleneck in our event loop",
        "write a deep architectural comparison between postgres and mongo for our system",
        "ab test these two model implementations and evaluate code quality",
        "debug this concurrent race condition in go",
        "refactor this entire module for better testability and solid principles",
        "write a distributed consensus algorithm using raft",
    ],
)

subagent = Route(
    name="subagent",
    utterances=[
        "write unit tests for this function",
        "generate markdown API documentation from these docstrings",
        "add a quick logs wrapper to print execution time",
        "scaffold a basic script to parse this json output",
        "comment this code block to explain the arguments",
        "create a simple helper function to format dates",
    ],
)

encoder = HuggingFaceEncoder(name="sentence-transformers/all-MiniLM-L6-v2")
rl = RouteLayer(encoder=encoder, routes=[orchestrator, subagent])


def _resolve_auth(headers: dict, request: Request) -> dict:
    out = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
    has_auth = any(k.lower() == "authorization" for k in out)
    if not has_auth:
        key = os.environ.get("LITELLM_VIRTUAL_KEY") or os.environ.get("LITELLM_MASTER_KEY") or ""
        if not key:
            raise HTTPException(status_code=500, detail="LITELLM_VIRTUAL_KEY or LITELLM_MASTER_KEY not configured")
        out["Authorization"] = f"Bearer {key}"
    return out


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    messages = body.get("messages", [])
    original_model = body.get("model", "orchestrator")

    user_query = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            user_query = msg.get("content", "")
            break

    if original_model in ("orchestrator", "subagent", "default"):
        target_pool = "subagent"
        if user_query:
            decision = rl(user_query)
            if decision.name == "orchestrator":
                target_pool = "orchestrator"
        body["model"] = target_pool

    headers = _resolve_auth(body, request)
    client: httpx.AsyncClient = request.app.state.client

    if body.get("stream", False):

        async def stream_generator():
            async with client.stream(
                "POST", f"{LITELLM_URL}/v1/chat/completions", json=body, headers=headers
            ) as response:
                async for chunk in response.aiter_raw():
                    yield chunk

        return StreamingResponse(stream_generator(), media_type="text/event-stream")

    response = await client.post(f"{LITELLM_URL}/v1/chat/completions", json=body, headers=headers)
    return response.json()


@app.get("/healthz")
async def healthz():
    return {"status": "healthy", "routes": [r.name for r in rl.routes]}
