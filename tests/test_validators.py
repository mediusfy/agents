import pytest
import asyncio
from openclaw.models.core import Artifact
from openclaw.validators import CodeValidator

def test_validate_vue_success():
    art = Artifact(
        agent_name="test",
        files={
            "Component.vue": "<template><div>Test</div></template>\n<script>export default {}</script>"
        }
    )
    result = asyncio.run(CodeValidator.validate_vue_async([art]))
    assert result is True

def test_validate_vue_failure_missing_template_close():
    art = Artifact(
        agent_name="test",
        files={
            "Component.vue": "<template><div>Test</div>\n<script>export default {}</script>"
        }
    )
    result = asyncio.run(CodeValidator.validate_vue_async([art]))
    assert result is False

def test_validate_go_empty():
    art = Artifact(agent_name="test", files={"main.py": "print('hello')"})
    result = asyncio.run(CodeValidator.validate_go_async([art]))
    assert result is True

def test_run_all():
    art = Artifact(
        agent_name="test",
        files={
            "Component.vue": "<template><div>Test</div></template>\n<script>export default {}</script>",
            "main.py": "print('hello')"
        }
    )
    result = CodeValidator.run_all([art])
    assert result is True
