#!/bin/bash
docker exec llm-lite-postgres-1 psql -U litellm -d litellm -c "SELECT model, COUNT(*) as request_count, SUM(completion_tokens + prompt_tokens) AS total_tokens FROM \"LiteLLM_SpendLogs\" GROUP BY model ORDER BY total_tokens DESC;"
