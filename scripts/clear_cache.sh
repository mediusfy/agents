#!/bin/bash

# Clear Python cache
echo "Clearing Python cache..."
find . -type d -name "__pycache__" -exec rm -r {} +
echo "Python cache cleared."

# Clear Redis cache
if command -v redis-cli &> /dev/null
then
    echo "Clearing Redis cache..."
    redis-cli flushall
    echo "Redis cache cleared."
else
    echo "WARNING: redis-cli command not found, skipping Redis cache clearing."
fi

echo "Cache clearing process finished."
