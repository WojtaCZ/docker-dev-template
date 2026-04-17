#!/usr/bin/env bash
set -euo pipefail

# Devcontainer post-create hook. Runs once after the container is created.
git config --global init.defaultBranch main
git config --global --add safe.directory /workspace
git config --global --add safe.directory '*'

echo "post-create: git defaults configured"
