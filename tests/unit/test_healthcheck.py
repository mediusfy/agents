"""Tests for the startup healthcheck module."""

from unittest.mock import patch
from openclaw.healthcheck import validate_api_keys, validate_directories


class TestValidateAPIKeys:
    def test_no_keys_returns_error(self):
        with patch("openclaw.healthcheck.settings") as mock:
            mock.openai_api_key = None
            mock.anthropic_api_key = None
            mock.gemini_api_key = None
            errors = validate_api_keys()
            assert any("No API keys configured" in e for e in errors)

    def test_placeholder_detected(self):
        with patch("openclaw.healthcheck.settings") as mock:
            mock.openai_api_key = "sk-..."
            mock.anthropic_api_key = None
            mock.gemini_api_key = None
            errors = validate_api_keys()
            assert any("placeholder" in e.lower() for e in errors)

    def test_valid_key_passes(self):
        with patch("openclaw.healthcheck.settings") as mock:
            mock.openai_api_key = "sk-real-key"
            mock.anthropic_api_key = None
            mock.gemini_api_key = None
            errors = validate_api_keys()
            assert len(errors) == 0


class TestValidateDirectories:
    def test_writable_directory_passes(self, tmp_path):
        with patch("openclaw.healthcheck.settings") as mock:
            mock.output_dir = tmp_path / "out"
            mock.checkpoint_dir = tmp_path / "ckpt"
            mock.vector_db_dir = tmp_path / "vdb"
            errors = validate_directories()
            assert len(errors) == 0

    def test_creates_missing_directories(self, tmp_path):
        out_dir = tmp_path / "does-not-exist" / "yet"
        with patch("openclaw.healthcheck.settings") as mock:
            mock.output_dir = out_dir
            mock.checkpoint_dir = tmp_path / "ckpt"
            mock.vector_db_dir = tmp_path / "vdb"
            errors = validate_directories()
            assert len(errors) == 0
            assert out_dir.parent.exists()
