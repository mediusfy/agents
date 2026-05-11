import asyncio
import json
import datetime
from dataclasses import dataclass
from typing import List, Optional, Any
from pydantic_ai import RunContext

# Import our new models and tools
from src.models.core import ActivityLog, UserStory, ReviewResult, RiskLevel
from src.tools.memory import log_activity, query_history
from src.tools.docs import update_documentation
from src.agents.ba import BADeps
from src.agents.review import ReviewDeps

# Mocking the context for tool execution
@dataclass
class MockContext:
    deps: Any

async def simulate_ba_work(pass_num: int):
    print(f"\n--- [PASS {pass_num}] BA Agent Starting ---")
    deps = BADeps(pass_num=pass_num)
    ctx = MockContext(deps=deps)
    
    # Step 1: BA defines a Bounded Context
    print("BA: Defining 'Payments' Bounded Context...")
    await update_documentation(
        ctx, 
        "Bounded Contexts.md", 
        f"## Payments Context (Pass {pass_num})\n- Focus: Secure transaction processing.\n- Events: PaymentStarted, PaymentCompleted.",
        mode="append"
    )
    
    # Step 2: BA logs the activity
    print("BA: Logging activity to project memory...")
    await log_activity(
        ctx, 
        action="Defined Bounded Context", 
        summary="Established the Payments bounded context with initial event triggers.",
        artifact_ids=["US-001"]
    )
    print("BA: Activity logged.")

async def simulate_review_spot_check(pass_num: int):
    print(f"\n--- [PASS {pass_num}] Review Agent Spot-Checking ---")
    deps = ReviewDeps(pass_num=pass_num)
    ctx = MockContext(deps=deps)
    
    # Step 1: Reviewer queries history from 9 passes ago (Pass 1)
    print(f"Reviewer: Querying history for early decisions (Pass 1)...")
    history = await query_history(ctx, "Payments bounded context", pass_num=1)
    print(f"Reviewer: Found History:\n{history}")
    
    # Step 2: Reviewer performs a "spot check"
    if "Payments bounded context" in history:
        print("Reviewer: SUCCESS - Current work aligns with Pass 1 architectural vision.")
        await log_activity(
            ctx,
            action="Spot Check Passed",
            summary="Verified that current implementation still honors the Payments Bounded Context defined in Pass 1."
        )
    else:
        print("Reviewer: ALERT - Could not find architectural context from Pass 1!")

async def run_simulation():
    # Pass 1: Initial setup
    await simulate_ba_work(pass_num=1)
    
    # Skip some time...
    
    # Pass 10: Spot checking
    await simulate_review_spot_check(pass_num=10)

if __name__ == "__main__":
    asyncio.run(run_simulation())
