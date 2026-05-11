import os
import re

AGENT_FILES = [
    "backend.py", "frontend.py", "test_eng.py", "sre.py", 
    "cto.py", "database.py", "devops.py", "quality_gate.py", "security.py", "ux.py"
]

WORKFLOW_PROMPT = """
CRITICAL WORKFLOW:
1. **History Review:** Use `query_history` to recall previous architectural and contextual decisions before generating logic.
2. **Log Progress:** Call `log_activity` after significant actions.
3. **Proactive Docs:** Keep `docs/` updated via `update_documentation` when implementing major features.
"""

def patch_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    agent_name = filepath.split('/')[-1].replace('.py', '')

    # Ensure dataclass import
    if "from dataclasses import dataclass" not in content:
        content = "from dataclasses import dataclass\n" + content

    # Add Deps Class if no existing deps
    deps_name = f"{agent_name.capitalize()}Deps"
    
    if "deps_type=" in content:
        # Existing deps_type (e.g. ProjectState or OrgContext)
        # Find the dataclass and append fields
        if agent_name == "backend":
            content = content.replace("team_owner: str", 'team_owner: str\n    pass_num: int = 1\n    agent_name: str = "backend"')
        elif agent_name == "cto":
            content = content.replace("monthly_cloud_budget: float", 'monthly_cloud_budget: float\n    pass_num: int = 1\n    agent_name: str = "cto"')
    else:
        # No existing deps
        dataclass_def = f"""
@dataclass
class {deps_name}:
    pass_num: int = 1
    agent_name: str = "{agent_name}"
"""
        # Insert before Agent definition
        agent_def_match = re.search(r'^[a-zA-Z_]+_agent\s*=\s*Agent\(', content, flags=re.MULTILINE)
        if agent_def_match:
            insert_idx = agent_def_match.start()
            content = content[:insert_idx] + dataclass_def + "\n" + content[insert_idx:]
            
            # Inject deps_type into Agent
            content = re.sub(
                r'(' + re.escape(agent_name) + r'_agent\s*=\s*Agent\([\s\S]*?AgentSettings\.[A-Z_]+_MODEL,)',
                r'\1\n    deps_type=' + deps_name + ',',
                content
            )

    # Insert CRITICAL WORKFLOW into prompt
    if "CRITICAL WORKFLOW:" not in content:
        prompt_match = re.search(r"'''([\s\S]*?)'''", content)
        if prompt_match:
            old_prompt = prompt_match.group(1)
            new_prompt = old_prompt + "\n" + WORKFLOW_PROMPT
            content = content.replace(f"'''{old_prompt}'''", f"'''{new_prompt}'''")

    with open(filepath, 'w') as f:
        f.write(content)

for agent_file in AGENT_FILES:
    patch_file(os.path.join("src", "agents", agent_file))

print("Patching complete.")
