import asyncio
from typing import Any

from openclaw.agents.ba import BADeps
from openclaw.agents.review import ReviewDeps
from openclaw.tools.docs import update_documentation
from openclaw.tools.memory import log_activity, query_history


class MockContext:
    def __init__(self, deps: Any) -> None:
        self.deps = deps


async def simulate_ba_work(pass_num: int):
    print(f"\n--- [PASS {pass_num}] BA Agent Starting ---")
    deps = BADeps(pass_num=pass_num)
    ctx = MockContext(deps=deps)

    print("BA: Defining 'Payments' Bounded Context...")
    await update_documentation(
        ctx,
        "Bounded Contexts.md",
        f"## Payments Context (Pass {pass_num})\n- Focus: Secure transaction processing.\n- Events: PaymentStarted, PaymentCompleted.",
        mode="append",
    )

    print("BA: Logging activity to project memory...")
    await log_activity(
        ctx,
        action="Defined Bounded Context",
        summary="Established the Payments bounded context with initial event triggers.",
        artifact_ids=["US-001"],
    )
    print("BA: Activity logged.")


async def simulate_review_spot_check(pass_num: int):
    print(f"\n--- [PASS {pass_num}] Review Agent Spot-Checking ---")
    deps = ReviewDeps(pass_num=pass_num)
    ctx = MockContext(deps=deps)

    print("Reviewer: Querying history for early decisions (Pass 1)...")
    history = await query_history(ctx, "Payments bounded context", pass_num=1)
    print(f"Reviewer: Found History:\n{history}")

    if "Payments bounded context" in history:
        print("Reviewer: SUCCESS - Current work aligns with Pass 1 architectural vision.")
        await log_activity(
            ctx,
            action="Spot Check Passed",
            summary="Verified that current implementation still honors the Payments Bounded Context defined in Pass 1.",
        )
    else:
        print("Reviewer: ALERT - Could not find architectural context from Pass 1!")


async def run_simulation():
    await simulate_ba_work(pass_num=1)

    # Skip some time...

    await simulate_review_spot_check(pass_num=10)


if __name__ == "__main__":
    asyncio.run(run_simulation())
