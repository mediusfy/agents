import os
import json
import re

def parse_agent_md(file_path):
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()
    
    # Extract YAML frontmatter
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", content, re.DOTALL)
    if not match:
        return None
        
    frontmatter_str, prompt = match.groups()
    
    frontmatter = {}
    for line in frontmatter_str.split("\n"):
        if ":" in line:
            key, val = line.split(":", 1)
            frontmatter[key.strip()] = val.strip()
            
    return {
        "name": frontmatter.get("name"),
        "description": frontmatter.get("description"),
        "model": frontmatter.get("model", "sonnet"),
        "prompt": prompt.strip()
    }

def main():
    shared_agents_dir = "/Users/jocham/programming/projects/mediusfy/agents/shared/agents"
    opencode_json_path = "/Users/jocham/programming/projects/mediusfy/agents/opencode/opencode.json"
    auth_json_path = "/Users/jocham/programming/projects/mediusfy/agents/opencode/auth.json"
    
    # 1. Parse all agents
    agents_config = {}
    for filename in sorted(os.listdir(shared_agents_dir)):
        if filename.endswith(".md"):
            agent_id = filename[:-3] # remove .md
            parsed = parse_agent_md(os.path.join(shared_agents_dir, filename))
            if parsed:
                # Map model to LiteLLM router groups
                # Sonnet/Opus/Orchestrator -> gpt-4o (routes to orchestrator)
                # Others -> deepseek-chat (routes to subagent)
                model_str = parsed["model"].lower()
                opencode_model = f"openai/{model_str}"
                    
                agents_config[agent_id] = {
                    "mode": "subagent",
                    "model": opencode_model,
                    "description": parsed["description"],
                    "prompt": parsed["prompt"]
                }
                
    # 2. Update all opencode.json files
    opencode_json_paths = [
        "/Users/jocham/programming/projects/mediusfy/agents/opencode/opencode.json",
        "/Users/jocham/programming/projects/mediusfy/agents/agents/opencode.json"
    ]
    
    for opencode_json_path in opencode_json_paths:
        if os.path.exists(opencode_json_path):
            with open(opencode_json_path, "r", encoding="utf-8") as f:
                config = json.load(f)
        else:
            config = {}
            
        config["$schema"] = "https://opencode.ai/config.json"
        
        # Configure provider to use local LiteLLM proxy
        config["provider"] = {
            "anthropic": {
                "options": {
                    "baseURL": "http://localhost:4000/v1"
                }
            },
            "openai": {
                "options": {
                    "baseURL": "http://localhost:4000/v1"
                }
            }
        }
        
        config["agent"] = agents_config
        
        # Write back to opencode.json
        with open(opencode_json_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=4)
        print(f"Updated {opencode_json_path} with {len(agents_config)} agents.")

    
    # 3. Update auth.json to use the LiteLLM key
    key = os.environ.get("LITELLM_VIRTUAL_KEY") or os.environ.get("LITELLM_MASTER_KEY") or ""
    auth_config = {
        "anthropic": {
            "type": "api",
            "key": key
        },
        "openai": {
            "type": "api",
            "key": key
        }
    }
    with open(auth_json_path, "w", encoding="utf-8") as f:
        json.dump(auth_config, f, indent=4)
    print(f"Updated {auth_json_path} with LiteLLM virtual keys.")

if __name__ == "__main__":
    main()
