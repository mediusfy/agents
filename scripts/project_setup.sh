#!/bin/bash
set -e

# Dynamically determine the repository root directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( dirname "$SCRIPT_DIR" )"

echo "============================================="
echo " Setting up AI Provider Configurations"
echo " Repo Directory: $REPO_DIR"
echo "============================================="

# Function to create symlink with backup
setup_symlink() {
    local source_file="$1"
    local target_link="$2"
    local target_dir
    target_dir="$(dirname "$target_link")"

    # Ensure target directory exists
    mkdir -p "$target_dir"

    # Backup existing file if it exists and is not already a symlink
    if [ -f "$target_link" ] || [ -d "$target_link" ] || [ -L "$target_link" ]; then
        if [ -L "$target_link" ]; then
            echo "Removing existing symlink: $target_link"
            rm "$target_link"
        else
            local backup_file="${target_link}.bak.$(date +%Y%m%d_%H%M%S)"
            echo "Backing up existing config to: $backup_file"
            mv "$target_link" "$backup_file"
        fi
    fi

    echo "Creating symlink: $target_link -> $source_file"
    ln -s "$source_file" "$target_link"
}

# 1. OpenCode Configuration
setup_symlink "$REPO_DIR/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"
setup_symlink "$REPO_DIR/opencode/auth.json" "$HOME/.config/opencode/auth.json"

# 2. OpenClaw Configuration
setup_symlink "$REPO_DIR/openclaw/openclaw.json" "$HOME/.openclaw/openclaw.json"

# 3. Claude Code Configuration
setup_symlink "$REPO_DIR/claude/settings.json" "$HOME/.claude/settings.json"

# 4. Hermes Configuration
setup_symlink "$REPO_DIR/hermes/config.yaml" "$HOME/.hermes/config.yaml"

# 5. Antigravity Configuration
setup_symlink "$REPO_DIR/antigravity/settings.json" "$HOME/.gemini/antigravity-cli/settings.json"

echo "============================================="
echo " Symlinks successfully set up!"
echo " Next step: Start LiteLLM proxy in llm-lite/"
echo "     cd $REPO_DIR/llm-lite && docker compose up -d"
echo "============================================="
