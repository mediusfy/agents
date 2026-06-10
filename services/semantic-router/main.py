import os
import httpx
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse
from semantic_router import Route
from semantic_router.encoders import HuggingFaceEncoder
from semantic_router.layer import RouteLayer

app = FastAPI(title="Semantic Router Gateway")

# 1. Define routes based on task complexity
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

# 2. Initialize the Local Encoder (sentence-transformers/all-MiniLM-L6-v2 is fast and runs offline)
encoder = HuggingFaceEncoder(name="sentence-transformers/all-MiniLM-L6-v2")
rl = RouteLayer(encoder=encoder, routes=[orchestrator, subagent])

# Target URL for the LiteLLM proxy (usually running in docker on host localhost:4000)
LITELLM_URL = os.environ.get("LITELLM_URL", "http://localhost:4000")

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    # Parse incoming request body
    body = await request.json()
    messages = body.get("messages", [])
    original_model = body.get("model", "orchestrator")

    # Extract the latest user query for semantic routing
    user_query = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            user_query = msg.get("content", "")
            break

    # If the user explicitly requested a specific model (e.g. deepseek-v4-pro, gemini-2.5-pro),
    # respect that explicit override. Otherwise, routing kicks in.
    if original_model in ["orchestrator", "subagent", "default"]:
        target_pool = "subagent"  # Default to cheap/local models
        if user_query:
            decision = rl(user_query)
            if decision.name == "orchestrator":
                target_pool = "orchestrator"
        
        body["model"] = target_pool
        print(f"[Semantic Router] Routed query '{user_query[:50]}...' to pool: {target_pool}")
    else:
        print(f"[Semantic Router] Respecting explicit model override: {original_model}")

    # Forward headers (carrying auth/master keys)
    headers = {k: v for k, v in request.headers.items() if k.lower() not in ["host", "content-length"]}

    # Ensure Authorization header is present
    has_auth = any(k.lower() == "authorization" for k in headers)
    if not has_auth:
        auth_key = os.environ.get("LITELLM_VIRTUAL_KEY") or os.environ.get("LITELLM_MASTER_KEY") or "sk-MPQ3A_kKYzNrhTpL6tYUVg"
        headers["Authorization"] = f"Bearer {auth_key}"

    # Proxy the request to the local LiteLLM gateway
    client = httpx.AsyncClient(timeout=120.0)
    
    # Handle streaming response
    if body.get("stream", False):
        async def stream_generator():
            try:
                async with client.stream(
                    "POST",
                    f"{LITELLM_URL}/v1/chat/completions",
                    json=body,
                    headers=headers
                ) as response:
                    async for chunk in response.aiter_raw():
                        yield chunk
            except Exception as e:
                print(f"[Semantic Router] Streaming proxy error: {e}")
            finally:
                await client.aclose()
        return StreamingResponse(stream_generator(), media_type="text/event-stream")
    
    # Handle non-streaming response
    else:
        try:
            response = await client.post(
                f"{LITELLM_URL}/v1/chat/completions",
                json=body,
                headers=headers
            )
            return response.json()
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Proxy error: {e}")
        finally:
            await client.aclose()

@app.get("/healthz")
async def healthz():
    return {"status": "healthy", "routes": [r.name for r in rl.routes]}
