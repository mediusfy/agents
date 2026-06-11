#!/usr/bin/env python3
"""
langgraph_example.py - A complete, runnable example demonstrating the integration
of LangGraph (graph orchestration), LangChain (pre-built search tools), and
Pydantic AI (type-safe, structured output agents).
"""

import asyncio
import os
import sys
from typing import List, Literal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from langchain_community.tools import DuckDuckGoSearchRun
from langgraph.graph import StateGraph, START, END

# ============================================================================
# 1. Define Pydantic Models for State and Agent Outputs
# ============================================================================

class StoryRefinement(BaseModel):
    """The structured output schema validated by Pydantic AI."""
    title: str = Field(description="The user story title")
    acceptance_criteria: List[str] = Field(description="List of acceptance criteria")
    is_ready_for_dev: bool = Field(description="True if the story is refined and clear for developers")
    missing_details: List[str] = Field(description="If not ready, list what details are missing")

class WorkflowState(BaseModel):
    """The state model managed and passed between nodes in LangGraph."""
    requirement: str
    refinement_attempts: int = 0
    refinement: StoryRefinement | None = None
    feedback: str = ""

# ============================================================================
# 2. Setup Pydantic AI Agent & Bridge LangChain Search Tool
# ============================================================================

# LangChain Search tool instance
search_tool = DuckDuckGoSearchRun()

# Define the Pydantic AI Agent.
# Using a cheap/mock model for safety, or matching project settings.
# Note: we resolve model naming through Pydantic AI's openai or deepseek interfaces.
ba_agent = Agent(
    "openai:gpt-4o-mini",
    output_type=StoryRefinement,
    system_prompt=(
        "You are an expert Business Analyst. Your job is to refine user requirements "
        "into structured user stories with acceptance criteria. "
        "Use the search_web tool if you need to research standard patterns or specifications."
    )
)

# Bridge the LangChain tool into Pydantic AI
@ba_agent.tool
def search_web(ctx: RunContext[None], query: str) -> str:
    """Useful to search the web for industry standards, schema specs, or common practices."""
    print(f"  [LangChain Tool] Searching for: {query}")
    try:
        return search_tool.run(query)
    except Exception as e:
        return f"Search failed: {e}"

# ============================================================================
# 3. Define LangGraph Workflow Nodes & Routing
# ============================================================================

async def refine_requirement_node(state: WorkflowState) -> dict:
    """Node that executes the Pydantic AI refinement agent."""
    print(f"\n--- [Node: Refine Requirement] Attempt #{state.refinement_attempts + 1} ---")
    
    prompt = f"Requirement: {state.requirement}"
    if state.feedback:
        prompt += f"\nPrevious Feedback: {state.feedback}"

    # In production, we run the agent. For this example, we handle fallback
    # if API keys aren't set so the script is safe to run.
    has_keys = os.environ.get("OPENAI_API_KEY") or os.environ.get("LITELLM_MASTER_KEY")
    result_data = None
    if has_keys:
        try:
            # Run actual Pydantic AI Agent
            result = await ba_agent.run(prompt)
            result_data = result.data
        except Exception as e:
            print(f"  [Warning] Model call failed: {e}. Falling back to simulation.")
            
    if result_data is None:
        print("  [Simulator Mode] Simulating Pydantic AI response...")
        # Simulate a refined output
        if state.refinement_attempts == 0:
            result_data = StoryRefinement(
                title="Create User Profile",
                acceptance_criteria=["Verify profile is stored in DB"],
                is_ready_for_dev=False,
                missing_details=["Missing details on profile pictures and storage limitations."]
            )
        else:
            result_data = StoryRefinement(
                title="Create User Profile with Avatar",
                acceptance_criteria=["Verify profile is stored in DB", "Avatar file size must be < 5MB"],
                is_ready_for_dev=True,
                missing_details=[]
            )

    return {
        "refinement": result_data,
        "refinement_attempts": state.refinement_attempts + 1
    }

async def feedback_node(state: WorkflowState) -> dict:
    """Node that simulates a quality gate providing feedback on what is missing."""
    print("--- [Node: Provide Feedback] Analyzing story quality ---")
    missing = ", ".join(state.refinement.missing_details)
    feedback = f"Please address the following missing details: {missing}. Define limits and residency rules."
    return {
        "feedback": feedback
    }

def should_continue(state: WorkflowState) -> Literal["add_feedback", "done"]:
    """Conditional router determining transition in the graph."""
    if state.refinement.is_ready_for_dev or state.refinement_attempts >= 3:
        return "done"
    return "add_feedback"

# ============================================================================
# 4. Build and Compile the Graph
# ============================================================================

workflow = StateGraph(WorkflowState)

# Add Nodes
workflow.add_node("refine", refine_requirement_node)
workflow.add_node("provide_feedback", feedback_node)

# Connect Edges
workflow.add_edge(START, "refine")
workflow.add_conditional_edges(
    "refine",
    should_continue,
    {
        "add_feedback": "provide_feedback",
        "done": END
    }
)
workflow.add_edge("provide_feedback", "refine")

# Compile into a runnable state machine
app = workflow.compile()

# ============================================================================
# 5. Main Execution Entrypoint
# ============================================================================

async def main():
    initial_state = WorkflowState(
        requirement="Create a REST endpoint to store user profiles in us-east-1 and eu-west-1."
    )
    
    print("Starting LangGraph + Pydantic AI + LangChain workflow...")
    
    # Run the compiled Graph asynchronously
    async for event in app.astream(initial_state):
        for node_name, state_delta in event.items():
            print(f"Node '{node_name}' finished. State changes: {list(state_delta.keys())}")
            if "refinement" in state_delta:
                ref = state_delta["refinement"]
                print(f"  Current Title: {ref.title}")
                print(f"  Ready for Dev: {ref.is_ready_for_dev}")
                if ref.missing_details:
                    print(f"  Missing Details: {ref.missing_details}")

if __name__ == "__main__":
    asyncio.run(main())
