#!/bin/bash
set -e

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

source venv/bin/activate
pip install -e ".[dev]"

if [ ! -f ".env" ]; then
    cp .env.example .env
fi

echo "Setup complete. Please edit the .env file to add your API keys."
