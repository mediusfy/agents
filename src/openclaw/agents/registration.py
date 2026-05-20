"""Centralized A2A agent registration.

All agent_bus.register() calls are collected here instead of living
as module-level side effects in individual agent files.
"""

from openclaw.a2a import agent_bus
from openclaw.registry import registry


def register_pipeline_agents():
    """Register all agents on the pipeline registry for orchestrated runs."""
    from openclaw.agents.ba import ba_agent
    from openclaw.agents.cto import cto_agent
    from openclaw.agents.backend import backend_agent
    from openclaw.agents.frontend import frontend_agent
    from openclaw.agents.frontend import component_gen
    from openclaw.agents.database import database_agent
    from openclaw.agents.devops import devops_agent
    from openclaw.agents.docs import docs_agent
    from openclaw.agents.sre import sre_agent
    from openclaw.agents.test_eng import test_eng_agent, test_gen
    from openclaw.agents.review import review_agent
    from openclaw.agents.security import security_agent
    from openclaw.agents.ux import ux_agent
    from openclaw.agents.quality_gate import quality_gate_agent

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
    registry.register("review", review_agent, ["review", "code_review"])
    registry.register("security", security_agent, ["security", "audit"])
    registry.register("ux", ux_agent, ["ux", "design"])
    registry.register("quality_gate", quality_gate_agent, ["quality_gate", "review"])


def register_a2a_agents():
    """Register all agents on the A2A bus for inter-agent delegation."""

    from openclaw.agents.accountant import accountant_agent, AccountantDeps
    from openclaw.agents.asymmetric_reviewer import asymmetric_reviewer_agent, AsymmetricReviewerDeps
    from openclaw.agents.current_events import current_events_agent, CurrentEventsDeps
    from openclaw.agents.database import database_agent, DatabaseDeps
    from openclaw.agents.region_analyzer import region_analyzer_agent, RegionAnalyzerDeps
    from openclaw.agents.weather import weather_agent, WeatherDeps

    from openclaw.agents.non_technical.crypto_oracle import crypto_oracle_agent, CryptoOracleDeps
    from openclaw.agents.non_technical.holiday_planner import holiday_planner_agent, HolidayPlannerDeps
    from openclaw.agents.non_technical.market_shark import market_shark_agent, MarketSharkDeps
    from openclaw.agents.non_technical.price_analyst import price_analyst_agent, PriceAnalystDeps

    agent_bus.register("accountant", accountant_agent, ["finance"], lambda: AccountantDeps(pass_num=1))
    agent_bus.register("asymmetric_reviewer", asymmetric_reviewer_agent, ["legal", "finance"], lambda: AsymmetricReviewerDeps(pass_num=1))
    agent_bus.register("current_events", current_events_agent, ["news", "history"], lambda: CurrentEventsDeps(pass_num=1))
    agent_bus.register("database", database_agent, ["db_schema", "migrations"], lambda: DatabaseDeps())
    agent_bus.register("region_analyzer", region_analyzer_agent, ["analysis"], lambda: RegionAnalyzerDeps(pass_num=1))
    agent_bus.register("weather", weather_agent, ["weather"], lambda: WeatherDeps(pass_num=1))

    agent_bus.register("crypto_oracle", crypto_oracle_agent, ["finance", "news", "research"], lambda: CryptoOracleDeps(pass_num=1))
    agent_bus.register("holiday_planner", holiday_planner_agent, ["planning", "travel"], lambda: HolidayPlannerDeps(pass_num=1))
    agent_bus.register("market_shark", market_shark_agent, ["finance", "crypto", "stocks", "investing"], lambda: MarketSharkDeps(pass_num=1))
    agent_bus.register("price_analyst", price_analyst_agent, ["pricing", "analysis", "purchasing"], lambda: PriceAnalystDeps(pass_num=1))
