import time
import json
import asyncio
import logging
from typing import Optional, Dict, Any

logger = logging.getLogger(__name__)


class Telemetry:
    def __init__(self, log_file: str = "telemetry.jsonl"):
        self.log_file = log_file

    async def log_call(self, agent_name: str, duration: float, success: bool, metadata: Optional[Dict[str, Any]] = None):
        entry = {
            "timestamp": time.time(),
            "agent": agent_name,
            "duration_sec": duration,
            "success": success,
            "metadata": metadata or {}
        }
        line = json.dumps(entry) + "\n"
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._write_line, line)

    def _write_line(self, line: str):
        with open(self.log_file, "a") as f:
            f.write(line)

    async def track(self, agent_name: str, func, *args, **kwargs):
        start = time.time()
        success = False
        try:
            result = await func(*args, **kwargs)
            success = True
            return result
        except Exception:
            raise
        finally:
            duration = time.time() - start
            try:
                await self.log_call(agent_name, duration, success)
            except Exception as e:
                logger.warning("Telemetry logging failed for %s: %s", agent_name, e)

telemetry = Telemetry()
