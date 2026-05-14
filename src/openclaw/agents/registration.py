"""Centralized A2A agent registration.

All agent_bus.register() calls are collected here instead of living
as module-level side effects in individual agent files.
"""

from openclaw.a2a import agent_bus


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
