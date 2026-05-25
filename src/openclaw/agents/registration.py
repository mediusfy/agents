"""Centralized agent registration.

All registry.register() calls are collected here instead of living
as module-level side effects in individual agent files.
"""

from openclaw.registry import registry

# Module-level flag is the fast path for "we've already registered". Set as the
# LAST step of register_all_agents() so a crash mid-loop correctly leaves the
# flag False and the next call retries.
#
# Tests sometimes mutate the global registry directly (e.g. via a fresh
# AgentRegistry fixture that doesn't share state). To stay correct under that
# pattern, we also confirm the registry actually contains a known agent — if
# the flag claims "done" but the registry is empty, we re-register.
_registered: bool = False
_KNOWN_AGENT = "ba"


def register_all_agents() -> None:
    """Register all agents (pipeline + travel/finance) on the unified registry.

    This is the single registration entry point for the entire ecosystem.
    Safe to call repeatedly — subsequent calls are no-ops. This matters for
    the MCP tools `delegate_to_openclaw_agent` and `modify_existing_code`,
    which both re-invoke this on every call.
    """
    global _registered
    if _registered and registry.is_registered(_KNOWN_AGENT):
        return
    # Either we never registered, or a test cleared the registry — reset.
    _registered = False
    # ── SDLC Pipeline Agents ──────────────────────────────────────────────
    from openclaw.agents.ba import ba_agent
    from openclaw.agents.backend import backend_agent
    from openclaw.agents.cto import cto_agent
    from openclaw.agents.database import database_agent
    from openclaw.agents.devops import devops_agent
    from openclaw.agents.docs import docs_agent
    from openclaw.agents.frontend import component_gen, frontend_agent
    from openclaw.agents.planner_agent import planner_agent
    from openclaw.agents.quality_gate import quality_gate_agent
    from openclaw.agents.review import review_agent
    from openclaw.agents.security import security_agent
    from openclaw.agents.service_engineer import service_engineer_agent
    from openclaw.agents.sre import sre_agent
    from openclaw.agents.test_eng import go_test_agent, test_eng_agent, test_gen
    from openclaw.agents.ux import ux_agent

    registry.register("ba", ba_agent, ["ba", "requirements"])
    registry.register("cto", cto_agent, ["cto", "architecture", "advisory"])
    registry.register("backend", backend_agent, ["backend", "implementation"])
    registry.register("frontend", frontend_agent, ["frontend", "implementation"])
    registry.register("frontend_component", component_gen, ["frontend_component"])
    registry.register("database", database_agent, ["database", "db_schema", "migrations"])
    registry.register("devops", devops_agent, ["devops", "ci_cd", "deployment"])
    registry.register("docs", docs_agent, ["docs", "documentation"])
    registry.register("sre", sre_agent, ["sre", "infrastructure"])
    registry.register("test_eng", test_eng_agent, ["test", "testing"])
    registry.register("test_gen", test_gen, ["test_gen", "test_generation"])
    registry.register("go_test", go_test_agent, ["go_test", "go_testing"])
    registry.register("review", review_agent, ["review", "code_review"])
    registry.register("security", security_agent, ["security", "audit"])
    registry.register("ux", ux_agent, ["ux", "design"])
    registry.register("quality_gate", quality_gate_agent, ["quality_gate", "review"])
    registry.register(
        "service_engineer", service_engineer_agent, ["service_engineer", "existing_code", "implementation"]
    )
    registry.register("planner", planner_agent, ["plan", "planning"])

    # ── Travel & Finance Agents (now all under non_technical/) ───────────
    from openclaw.agents.non_technical.accountant import AccountantDeps, accountant_agent
    from openclaw.agents.non_technical.asymmetric_reviewer import (
        AsymmetricReviewerDeps,
        asymmetric_reviewer_agent,
    )
    from openclaw.agents.non_technical.crypto_oracle import CryptoOracleDeps, crypto_oracle_agent
    from openclaw.agents.non_technical.current_events import CurrentEventsDeps, current_events_agent
    from openclaw.agents.non_technical.holiday_planner import HolidayPlannerDeps, holiday_planner_agent
    from openclaw.agents.non_technical.market_shark import MarketSharkDeps, market_shark_agent
    from openclaw.agents.non_technical.price_analyst import PriceAnalystDeps, price_analyst_agent
    from openclaw.agents.non_technical.region_analyzer import RegionAnalyzerDeps, region_analyzer_agent
    from openclaw.agents.non_technical.weather import WeatherDeps, weather_agent

    registry.register("accountant", accountant_agent, ["finance"], lambda: AccountantDeps())
    registry.register(
        "asymmetric_reviewer",
        asymmetric_reviewer_agent,
        ["legal", "finance"],
        lambda: AsymmetricReviewerDeps(),
    )
    registry.register("current_events", current_events_agent, ["news", "history"], lambda: CurrentEventsDeps())
    registry.register("region_analyzer", region_analyzer_agent, ["analysis"], lambda: RegionAnalyzerDeps())
    registry.register("weather", weather_agent, ["weather"], lambda: WeatherDeps())
    registry.register("crypto_oracle", crypto_oracle_agent, ["finance", "news", "research"], lambda: CryptoOracleDeps())
    registry.register(
        "holiday_planner",
        holiday_planner_agent,
        ["planning", "travel"],
        lambda: HolidayPlannerDeps(),
    )
    registry.register(
        "market_shark",
        market_shark_agent,
        ["finance", "crypto", "stocks", "investing"],
        lambda: MarketSharkDeps(),
    )
    registry.register(
        "price_analyst",
        price_analyst_agent,
        ["pricing", "analysis", "purchasing"],
        lambda: PriceAnalystDeps(),
    )

    _registered = True
