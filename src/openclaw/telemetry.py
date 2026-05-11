import time
import json
import os
from typing import Optional, Dict, Any

class Telemetry:
    def __init__(self, log_file: str = "telemetry.jsonl"):
        self.log_file = log_file

    def log_call(self, agent_name: str, duration: float, success: bool, metadata: Optional[Dict[str, Any]] = None):
        entry = {
            "timestamp": time.time(),
            "agent": agent_name,
            "duration_sec": duration,
            "success": success,
            "metadata": metadata or {}
        }
        with open(self.log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")

    async def track(self, agent_name: str, func, *args, **kwargs):
        start = time.time()
        success = False
        try:
            result = await func(*args, **kwargs)
            success = True
            return result
        finally:
            duration = time.time() - start
            self.log_call(agent_name, duration, success)

telemetry = Telemetry()
