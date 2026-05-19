#!/bin/bash
set -e

# 1. Create a virtual environment
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

# 2. Activate the virtual environment and install dependencies
source venv/bin/activate
pip install -r requirements.txt

# 3. Create a .env file if it doesn't exist
if [ ! -f ".env" ]; then
    cp .env.example .env
fi

echo "Setup complete. Please edit the .env file to add your API keys."
