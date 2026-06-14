"""Agent execution MCP tools — run agents by name, delegate, list capabilities."""

import asyncio
import contextlib
import json
import logging
import os
import time
from typing import Any

import logfire
from pydantic_ai import UsageLimits

from orchestration.agents.registration import register_all_agents
from orchestration.context_engine import retrieve_context
from orchestration.exceptions import AgentExecutionError, AgentNotFoundError
from orchestration.mcp_server import mcp
from orchestration.registry import instrumented_query, registry
from orchestration.telemetry import telemetry

logger = logging.getLogger(__name__)

register_all_agents()


async def run_agent_by_name(agent_name: str, request: str, run_on_gks: bool = False) -> str:
    if run_on_gks:
        try:
            config_path = os.path.expanduser("~/.orchestration/orchestration.json")
            with open(config_path) as f:
                config = json.load(f)
            remote_url = config.get("gateway", {}).get("remote", {}).get("url")
            remote_token = config.get("gateway", {}).get("remote", {}).get("token")

            if not remote_url or not remote_token:
                return "ERROR: GKS remote URL or token is not configured in ~/.orchestration/orchestration.json"

            params = json.dumps({"agent": agent_name, "message": request})
            cmd = [
                "orchestration",
                "gateway",
                "call",
                "agent",
                "--expect-final",
                "--url",
                remote_url,
                "--token",
                remote_token,
                "--params",
                params,
            ]

            with logfire.span("mcp.delegate_to_gks", agent_name=agent_name, _level="info"):
                proc = await asyncio.create_subprocess_exec(
                    *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
                )
                try:
                    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=300)
                except TimeoutError:
                    proc.kill()
                    return "ERROR running on GKS: Gateway RPC timed out after 300 seconds."

                if proc.returncode != 0:
                    return f"ERROR running on GKS: {stderr.decode()}\nOutput: {stdout.decode()}"

                raw_out = stdout.decode().strip()
                try:
                    parsed = json.loads(raw_out)
                    if isinstance(parsed, dict) and "result" in parsed:
                        return str(parsed["result"])
                    return raw_out
                except Exception:
                    return raw_out
        except Exception as e:
            return f"ERROR routing to GKS: {e}"

    try:
        agent = registry.get(agent_name)
    except ValueError as e:
        raise AgentNotFoundError(f"Agent '{agent_name}' not registered") from e

    agent_tuple = registry._agents.get(agent_name)
    if not agent_tuple:
        raise AgentNotFoundError(f"Agent '{agent_name}' not registered")

    _, _, deps_factory, _ = agent_tuple

    enriched_request = request
    with logfire.span("mcp.retrieve_context", agent_name=agent_name, _level="info"):
        context = await retrieve_context(agent_name, request, top_k=3)
        if context:
            enriched_request = f"Relevant Architecture Context from Knowledge Base:\n{context}\n\n---\n\n{request}"

    span_attrs: dict[str, Any] = {
        "agent_name": agent_name,
        "request_length": len(request),
        "context_retrieved": bool(context),
    }

    start = time.time()
    success = False
    try:
        with logfire.span("mcp.run_agent", **span_attrs, _level="info"):
            resolved_deps = deps_factory() if callable(deps_factory) else {}
            result = await agent.run(enriched_request, deps=resolved_deps, usage_limits=UsageLimits(request_limit=500))
            success = True
            if hasattr(result, "data"):
                return str(result.data)
            return str(result.output) if hasattr(result, "output") else str(result)
    except Exception as e:
        logger.warning("Agent '%s' failed: %s", agent_name, e)
        raise AgentExecutionError(f"Agent '{agent_name}' failed: {e}", is_retryable=False) from e
    finally:
        duration = time.time() - start
        with contextlib.suppress(Exception):
            await telemetry.log_call(agent_name, duration, success, metadata=span_attrs)


def _list_capabilities() -> str:
    register_all_agents()
    lines = []
    for cap, owners in registry.capabilities():
        primary = owners[0]
        rest = f"  (also: {', '.join(owners[1:])})" if len(owners) > 1 else ""
        lines.append(f"  - {cap}: {primary}{rest}")
    return "\n".join(lines)


AGENT_DOCSTRINGS = {
        "holiday_planner": "Invokes the Holiday Planner Agent.",
        "region_analyzer": "Invokes the Region Analyzer Agent.",
        "asymmetric_reviewer": "Invokes the Asymmetric Reviewer Agent (law & corporate tricks for travel savings).",
        "current_events": "Invokes the Current Events Agent (history buff).",
        "weather": "Invokes the Weather Agent.",
        "accountant": "Invokes the Accountant Agent.",
        "ba": "Invokes the Business Analyst (BA) agent to write user stories and requirements.",
        "cto": "Invokes the CTO agent for architectural guidance and advisories.",
        "backend": "Invokes the Backend Engineer agent to generate high-concurrency Go services.",
        "frontend": "Invokes the Frontend Engineer agent to generate user interfaces.",
        "database": "Invokes the Database agent to generate schema migrations and seed scripts.",
        "devops": "Invokes the DevOps agent to generate CI/CD pipelines and docker-compose configurations.",
        "docs": "Invokes the Documentation agent to generate API documentation and READMEs.",
        "sre": "Invokes the SRE agent to generate Kubernetes/Helm infrastructure manifests.",
        "test_eng": "Invokes the Test Engineer agent to run tests and analyze coverage.",
        "test_gen": "Invokes the Test Generator agent to write unit and table-driven tests.",
        "go_test": "Invokes the Go Testing agent to run tests and debug test failures.",
        "review": "Invokes the Code Review agent to verify production readiness and standards.",
        "security": "Invokes the Security agent to audit code and scan for vulnerabilities.",
        "ux": "Invokes the UX Design agent to refine page layout and flow.",
        "quality_gate": "Invokes the Quality Gate agent to check for over-engineering and complexity.",
        "service_engineer": "Invokes the Service Engineer agent to modify existing Go codebases.",
        "planner": "Invokes the Planner agent to create execution plans.",
        "crypto_oracle": "Invokes the Crypto Oracle Agent to analyze crypto markets and trends.",
        "market_shark": "Invokes the Market Shark Agent to analyze stock markets and investments.",
        "price_analyst": "Invokes the Price Analyst Agent to analyze and compare pricing.",
    }



def _register_agent_mcp_tools():
    def make_runner(agent_name: str):
        async def agent_runner(request: str, run_on_gks: bool = False) -> str:
            return await run_agent_by_name(agent_name, request, run_on_gks=run_on_gks)

        return agent_runner

    for name in registry.list_agents():
        tool_name = f"run_{name}"
        runner = make_runner(name)
        docstring = AGENT_DOCSTRINGS.get(name, f"Invokes the {name} agent to perform its designated task.")
        runner.__doc__ = docstring
        runner.__name__ = tool_name
        mcp.tool(name=tool_name)(runner)


_register_agent_mcp_tools()


@mcp.tool()
async def delegate_to_orchestration_agent(
    capability: str,
    context: str,
    task: str,
    run_on_gks: bool = False,
    owner: str | None = None,
) -> str:
    """Delegate a heavy-lifting engineering task to the Orgitration autonomous agents.

    Pass a capability string registered via orchestration.agents.registration; common
    ones include 'backend', 'frontend', 'database', 'security', 'review',
    'quality_gate', 'go_test', 'planning', 'sre', 'docs'. The full live list is
    available via the list_orchestration_capabilities tool.

    If run_on_gks is True, the task is offloaded to the remote GKS Orgitration instance.

    If the capability is ambiguous (claimed by multiple agents), pass
    owner=<agent_name> to disambiguate.
    """
    from orchestration.exceptions import AmbiguousCapabilityError

    register_all_agents()

    full_prompt = (
        f"Context from IDE:\n<ide_context>\n{context}\n</ide_context>\n\nTask:\n<user_task>\n{task}\n</user_task>"
    )

    if run_on_gks:
        return await run_agent_by_name(capability, full_prompt, run_on_gks=True)

    try:
        return await instrumented_query(
            capability=capability,
            prompt=full_prompt,
            span_name="mcp.delegate_to_agent",
            attributes={"capability": capability, "context_length": len(context), "task_length": len(task)},
            owner=owner,
        )
    except AgentNotFoundError as e:
        return f"ERROR: {e}\n\nAvailable capabilities:\n{_list_capabilities()}"
    except AmbiguousCapabilityError as e:
        owners_str = ", ".join(e.owners)
        return f"ERROR: {e}\n\nRe-call delegate_to_orchestration_agent with owner=<agent_name> from: {owners_str}"
    except AgentExecutionError as e:
        return f"ERROR: {e}"


@mcp.tool()
def list_orchestration_capabilities() -> str:
    """List the Orgitration agent capabilities currently registered, with their owning agent."""
    return "Registered capabilities (capability: primary_agent):\n" + _list_capabilities()
