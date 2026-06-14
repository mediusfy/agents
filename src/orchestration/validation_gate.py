"""ValidationGate — protocol for cross-agent output validation."""

import asyncio
from dataclasses import dataclass, field
from typing import Any, Protocol


class ValidationGate(Protocol):
    async def validate(self, artifacts: list, context: dict[str, Any]) -> "GateResult":
        ...


@dataclass
class GateResult:
    passed: bool = False
    score: int = 0
    feedback: list[str] = field(default_factory=list)
    agent_name: str = ""


class CompositeGate:
    def __init__(self, gates: list[tuple[str, ValidationGate]]):
        self.gates = gates

    async def validate_all(self, artifacts: list, context: dict[str, Any]) -> list[GateResult]:
        results = await asyncio.gather(
            *[gate.validate(artifacts, context) for _, gate in self.gates],
            return_exceptions=True,
        )
        output: list[GateResult] = []
        for (name, _), r in zip(self.gates, results):
            if isinstance(r, BaseException):
                output.append(GateResult(passed=False, feedback=[f"{name}: {r}"], agent_name=name))
            else:
                output.append(r)
        return output
