from pathlib import Path

from openclaw.settings import Settings


def test_settings_defaults():
    s = Settings()
    assert s.ba_model == "gpt-4o-mini"
    assert s.max_retries == 2
    assert s.max_concurrent_llm_calls == 5
    assert s.output_dir == Path("./generated-app")
    assert s.checkpoint_dir == Path("./.claw-checkpoints")


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("BA_MODEL", "gpt-4o")
    monkeypatch.setenv("MAX_RETRIES", "5")
    monkeypatch.setenv("OUTPUT_DIR", "/tmp/my-output")
    s = Settings()
    assert s.ba_model == "gpt-4o"
    assert s.max_retries == 5
    assert s.output_dir == Path("/tmp/my-output")


def test_settings_api_keys_empty_by_default(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    s = Settings(_env_file=None)
    assert s.openai_api_key is None
    assert s.anthropic_api_key is None
    assert s.gemini_api_key is None


def test_settings_api_keys_from_env(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-real-key")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-real-key")
    s = Settings()
    assert s.openai_api_key == "sk-real-key"
    assert s.anthropic_api_key == "sk-ant-real-key"


def test_config_worker_settings_defaults():
    from openclaw.config import worker_settings

    assert worker_settings.max_correction_attempts == 3
    assert worker_settings.task_consume_timeout == 1.0
