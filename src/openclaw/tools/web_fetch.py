import httpx
from pydantic_ai import RunContext

from openclaw.tools.registry import register_tool


async def fetch_url(ctx: RunContext[str], url: str, format: str = "text") -> str:
    try:
        async with httpx.AsyncClient(timeout=15.0, follow_redirects=True) as client:
            resp = await client.get(url, headers={"User-Agent": "OpenClaw-Agent/1.0"})
            resp.raise_for_status()
            content_type = resp.headers.get("content-type", "")
            if "json" in content_type:
                import json

                return json.dumps(resp.json(), indent=2)
            return resp.text
    except httpx.HTTPStatusError as e:
        return f"HTTP error {e.response.status_code} fetching {url}: {e}"
    except httpx.RequestError as e:
        return f"Request failed for {url}: {e}"
    except Exception as e:
        return f"Unexpected error fetching {url}: {e}"


register_tool("fetch_url", fetch_url, "Fetch content from a URL via HTTP GET", ["web", "docs", "research"])
