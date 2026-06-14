"""PromptManager — centralized loading and caching of agent system prompts from YAML files.

Prompts live in ``src/orchestration/prompts/{agent_name}.yaml``.
If a prompt file is missing, ``defaults.yaml`` is used as fallback.
"""

import logging
import os
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

_PROMPTS_DIR = Path(__file__).resolve().parent / "prompts"


class PromptManager:
    """Singleton prompt manager that loads and caches YAML prompts."""

    def __init__(self, prompts_dir: str | Path | None = None):
        self._prompts_dir = Path(prompts_dir) if prompts_dir else _PROMPTS_DIR
        self._cache: dict[str, str] = {}
        self._default_prompt: str | None = None

    def _load_default(self) -> str:
        if self._default_prompt is not None:
            return self._default_prompt
        default_path = self._prompts_dir / "defaults.yaml"
        if default_path.exists():
            with open(default_path) as f:
                data = yaml.safe_load(f)
            self._default_prompt = (data or {}).get("prompt", "")
        else:
            self._default_prompt = ""
        return self._default_prompt

    def get_prompt(self, agent_name: str) -> str:
        cached = self._cache.get(agent_name)
        if cached is not None:
            return cached

        filepath = self._prompts_dir / f"{agent_name}.yaml"
        if filepath.exists():
            with open(filepath) as f:
                data = yaml.safe_load(f)
            prompt = (data or {}).get("prompt", "")
            if prompt:
                self._cache[agent_name] = prompt
                return prompt

        fallback = self._load_default()
        self._cache[agent_name] = fallback
        return fallback

    def reload(self, agent_name: str | None = None) -> None:
        if agent_name:
            self._cache.pop(agent_name, None)
        else:
            self._cache.clear()
            self._default_prompt = None

    def list_available(self) -> list[str]:
        files = []
        for f in os.listdir(self._prompts_dir):
            if f.endswith(".yaml") and f != "defaults.yaml":
                files.append(f.removesuffix(".yaml"))
        return sorted(files)


prompt_manager = PromptManager()
