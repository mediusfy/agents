from dagster import asset, Definitions, Config, get_dagster_logger, ScheduleDefinition, AssetSelection
import asyncio
from openclaw.registry import registry
from openclaw.config import AgentSettings

# Auto-discover all agents (including your new Crypto Oracle and Market Shark)
registry.autodiscover()

class RequirementConfig(Config):
    requirement_text: str = "Build a secure crypto tracking platform."

@asset(group_name="openclaw_pipeline")
async def business_analysis(config: RequirementConfig) -> list[dict]:
    """The BA Agent parses requirements into User Stories."""
    logger = get_dagster_logger()
    logger.info(f"BA Agent Analyzing: {config.requirement_text}")
    ba_agent = registry.get("ba")
    
    result = await ba_agent.run(f"Process these requirements: {config.requirement_text}")
    return [story.model_dump() for story in result.data]

@asset(group_name="openclaw_pipeline")
async def cto_advisory(business_analysis: list) -> list[str]:
    """The CTO Agent reviews the User Stories and provides architecture advice."""
    from openclaw.agents.cto import OrgContext
    cto_agent = registry.get("cto")
    
    story_context = "\n".join(f"- {s['id']}: {s['title']}" for s in business_analysis)
    org_ctx = OrgContext(tech_stack=["Python", "FastAPI", "React", "PostgreSQL"], compliance_tier="Standard", monthly_cloud_budget=500.0)
    
    result = await cto_agent.run(f"Review these user stories and provide architectural advice:\n{story_context}", deps=org_ctx)
    return result.data.recommendations

@asset(group_name="autonomous_finance")
async def daily_crypto_forecast() -> str:
    """Runs the Crypto Oracle autonomously to scrape global laws and forecast."""
    logger = get_dagster_logger()
    logger.info("Waking up Crypto Oracle for daily sweep...")
    
    oracle = registry.get("crypto_oracle")
    # In Dagster, we can instantiate deps here
    from openclaw.agents.non_technial.crypto_oracle import CryptoOracleDeps
    deps = CryptoOracleDeps(pass_num=1)
    
    result = await oracle.run("Perform your daily legislative sweep of .gov sites and generate a new market forecast. Save it to memory.", deps=deps)
    return result.data

@asset(group_name="autonomous_finance")
async def daily_market_shark_analysis() -> str:
    """The Market Shark evaluates the top 5 trending tickers mathematically."""
    shark = registry.get("market_shark")
    from openclaw.agents.non_technial.market_shark import MarketSharkDeps
    deps = MarketSharkDeps(pass_num=1)
    
    result = await shark.run("Pull the current data and historical charts for BTC-USD and AAPL. Provide a mathematically backed risk/reward analysis.", deps=deps)
    return result.data

# A Dagster schedule to trigger the finance agents every morning at 8:00 AM
finance_schedule = ScheduleDefinition(
    name="daily_finance_sweep",
    cron_schedule="0 8 * * *",
    target=AssetSelection.groups("autonomous_finance"),
)

defs = Definitions(
    assets=[business_analysis, cto_advisory, daily_crypto_forecast, daily_market_shark_analysis],
    schedules=[finance_schedule]
)
