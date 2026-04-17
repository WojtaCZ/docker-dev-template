#!/usr/bin/env bash
set -euo pipefail

# Wire up host-side Claude state selectively:
#   - auth (~/.claude.json)         — always shared
#   - credentials, history, memory  — shared if present on host
# Everything else (skills, agents, commands, settings.json) stays baked into
# the image layer so specialised containers keep their own toolsets.

if [ -f /host-claude-auth.json ]; then
    ln -sfn /host-claude-auth.json "$HOME/.claude.json"
fi

if [ -d /host-claude-dir ]; then
    for shared in projects memory .credentials.json; do
        src="/host-claude-dir/${shared}"
        if [ -e "$src" ]; then
            ln -sfn "$src" "$HOME/.claude/${shared}"
        fi
    done
fi

# Best-effort self-update; don't block container start if offline
claude update >/dev/null 2>&1 || true

exec "$@"
