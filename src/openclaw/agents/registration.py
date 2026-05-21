"""Centralized agent registration.

All agent_bus.register() and registry.register() calls are collected here
instead of living as module-level side effects in individual agent files.
"""

from openclaw.registry import registry


def register_pipeline_agents():
    """Register all agents on the pipeline registry for orchestrated runs."""
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

    # Pipeline agents
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


def register_a2a_agents():
    """Register travel/finance agents on the unified registry for A2A delegation."""

    from openclaw.agents.accountant import AccountantDeps, accountant_agent
    from openclaw.agents.asymmetric_reviewer import AsymmetricReviewerDeps, asymmetric_reviewer_agent
    from openclaw.agents.current_events import CurrentEventsDeps, current_events_agent
    from openclaw.agents.non_technical.crypto_oracle import CryptoOracleDeps, crypto_oracle_agent
    from openclaw.agents.non_technical.holiday_planner import HolidayPlannerDeps, holiday_planner_agent
    from openclaw.agents.non_technical.market_shark import MarketSharkDeps, market_shark_agent
    from openclaw.agents.non_technical.price_analyst import PriceAnalystDeps, price_analyst_agent
    from openclaw.agents.region_analyzer import RegionAnalyzerDeps, region_analyzer_agent
    from openclaw.agents.weather import WeatherDeps, weather_agent

    registry.register("accountant", accountant_agent, ["finance"], lambda: AccountantDeps(pass_num=1))
    registry.register(
        "asymmetric_reviewer",
        asymmetric_reviewer_agent,
        ["legal", "finance"],
        lambda: AsymmetricReviewerDeps(pass_num=1),
    )
    registry.register(
        "current_events", current_events_agent, ["news", "history"], lambda: CurrentEventsDeps(pass_num=1)
    )
    registry.register("region_analyzer", region_analyzer_agent, ["analysis"], lambda: RegionAnalyzerDeps(pass_num=1))
    registry.register("weather", weather_agent, ["weather"], lambda: WeatherDeps(pass_num=1))
    registry.register(
        "crypto_oracle", crypto_oracle_agent, ["finance", "news", "research"], lambda: CryptoOracleDeps(pass_num=1)
    )
    registry.register(
        "holiday_planner",
        holiday_planner_agent,
        ["planning", "travel"],
        lambda: HolidayPlannerDeps(pass_num=1),
    )
    registry.register(
        "market_shark",
        market_shark_agent,
        ["finance", "crypto", "stocks", "investing"],
        lambda: MarketSharkDeps(pass_num=1),
    )
    registry.register(
        "price_analyst",
        price_analyst_agent,
        ["pricing", "analysis", "purchasing"],
        lambda: PriceAnalystDeps(pass_num=1),
    )
