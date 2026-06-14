
import pytest

from orchestration.validation_gate import CompositeGate, GateResult


class TestGateResult:
    def test_defaults(self):
        r = GateResult()
        assert r.passed is False
        assert r.score == 0
        assert r.feedback == []
        assert r.agent_name == ""

    def test_custom_values(self):
        r = GateResult(passed=True, score=85, feedback=["looks good"], agent_name="review")
        assert r.passed is True
        assert r.score == 85


class FakeGate:
    def __init__(self, result: GateResult):
        self._result = result

    async def validate(self, artifacts: list, context: dict) -> GateResult:
        return self._result


class TestCompositeGate:
    @pytest.mark.asyncio
    async def test_all_pass(self):
        a = FakeGate(GateResult(passed=True, agent_name="gate_a"))
        b = FakeGate(GateResult(passed=True, agent_name="gate_b"))
        composite = CompositeGate([("a", a), ("b", b)])
        results = await composite.validate_all([], {})
        assert len(results) == 2
        assert all(r.passed for r in results)

    @pytest.mark.asyncio
    async def test_one_fails(self):
        a = FakeGate(GateResult(passed=True, agent_name="gate_a"))
        b = FakeGate(GateResult(passed=False, feedback=["failed"], agent_name="gate_b"))
        composite = CompositeGate([("a", a), ("b", b)])
        results = await composite.validate_all([], {})
        assert results[0].passed is True
        assert results[1].passed is False

    @pytest.mark.asyncio
    async def test_exception_handling(self):
        class BrokenGate:
            async def validate(self, artifacts, context):
                raise RuntimeError("gate crashed")

        a = FakeGate(GateResult(passed=True, agent_name="gate_a"))
        composite = CompositeGate([("a", a), ("broken", BrokenGate())])
        results = await composite.validate_all([], {})
        assert results[0].passed is True
        assert results[1].passed is False
