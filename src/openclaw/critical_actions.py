# A list of agent capabilities that require human approval before execution.
# This provides a safety net for potentially destructive or costly actions.

CRITICAL_CAPABILITIES = [
    "db_schema",  # Modifying database schemas can be destructive.
    "infrastructure",  # Infrastructure changes can be costly.
    "sre",  # Site Reliability Engineering often involves production changes.
    "devops",  # DevOps tasks can involve deployments and infrastructure changes.
]
