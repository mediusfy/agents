# AI Providers and Clients Configuration Setup

This repository contains shared configurations for the different AI CLI tools and clients. Using this configuration ensures all tools leverage the centralized **LiteLLM** proxy, sharing standardized agent prompts, rate limits, and model routing parameters.

Supported clients:
- **Hermes** (`~/.hermes/config.yaml`)
- **OpenCode** (`~/.config/opencode/opencode.json` & `~/.config/opencode/auth.json`)
- **Claude Code** (`~/.claude/settings.json`)
- **Antigravity CLI** (`~/.gemini/antigravity-cli/settings.json`)
- **OpenClaw** (`~/.openclaw/openclaw.json`)

---

## 1. Prerequisites (Software Installation)

Ensure the following tools are installed on your machine:

1. **Docker & Docker Compose**: Used to run the LiteLLM proxy, PostgreSQL, Redis, and NATS.
2. **Node.js (v18+)**: Needed for OpenCode and Claude Code.
3. **Python (3.10+)**: Required for running customized setup/generation scripts.
4. **Tailscale (Optional)**: If connecting to services across a secure tailnet.

---

## 2. Setting Up Symlinks

Run the helper script from the root of this repository. This script automatically backs up any existing configuration files in your home directories and creates symlinks back to this repository so that any edits are version-tracked in Git:

```bash
./scripts/project_setup.sh
```

---

## 3. Starting the LiteLLM Proxy

The configurations are mapped to route requests through a local LiteLLM instance running on `http://localhost:4000`.

To start the LiteLLM instance:

1. Navigate to the `llm-lite/` directory:
   ```bash
   cd llm-lite
   ```
2. Set your API keys in a `.env` file (e.g. `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `TOGETHERAI_API_KEY`, `XAI_API_KEY`).
3. Launch the stack:
   ```bash
   docker compose up -d
   ```

LiteLLM is pre-configured with a master key (`sk-MPQ3A_kKYzNrhTpL6tYUVg`) and routes requests to:
- **Orchestrator Layer** (Complex plans/reasoning): DeepSeek-V4-Pro / Gemini 2.5 Pro / Grok 4.3.
- **Subagent Layer** (Volume code-gen / quick tasks): Qwen 2.5 Coder 7B / DeepSeek-V4-Flash / Gemini 2.5 Flash.

---

## 4. Keeping Configurations Synced

If you edit or add new agent definitions in `shared/agents/`, you should regenerate the OpenCode configuration block by running:

```bash
python3 scripts/generate_opencode_config.py
```

This updates `opencode/opencode.json` with the updated system prompts and models, which are instantly active via the symlink.
