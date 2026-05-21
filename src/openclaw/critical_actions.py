# A list of agent capabilities that require human approval before execution.

CRITICAL_CAPABILITIES = [
    "db_schema",  # Modifying database schemas can be destructive.
    "infrastructure",  # Infrastructure changes can be costly.
    "sre",  #  production changes.
    "devops",  # infrastructure changes.
]
