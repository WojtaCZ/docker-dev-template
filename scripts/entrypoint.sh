#!/usr/bin/env bash
set -euo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="/home/${DEV_USER}"

# ---------------------------------------------------------------------------
# Phase 1 — root only. Optional UID/GID remap, then drop to ${DEV_USER}.
#
# Bind-mounted /workspace files are owned by the host UID. When that is not
# 1000 (the baked-in default) every file the container writes lands with the
# wrong owner. Pass HOST_UID / HOST_GID to fix it without rebuilding.
#
# This block is skipped entirely when the container is already started as a
# non-root user (VSCode devcontainer `remoteUser`, `docker run --user`, ...).
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    current_uid="$(id -u "${DEV_USER}")"
    current_gid="$(id -g "${DEV_USER}")"
    remapped=0

    if [ -n "${HOST_GID:-}" ] && [ "${HOST_GID}" != "${current_gid}" ]; then
        groupmod -o -g "${HOST_GID}" "${DEV_USER}"
        remapped=1
    fi
    if [ -n "${HOST_UID:-}" ] && [ "${HOST_UID}" != "${current_uid}" ]; then
        usermod -o -u "${HOST_UID}" "${DEV_USER}"
        remapped=1
    fi
    if [ "${remapped}" = "1" ]; then
        chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"
        echo "entrypoint: remapped ${DEV_USER} to ${HOST_UID:-$current_uid}:${HOST_GID:-$current_gid}"
    fi

    exec setpriv --reuid="${DEV_USER}" --regid="${DEV_USER}" --init-groups \
        env HOME="${DEV_HOME}" \
            USER="${DEV_USER}" \
            LOGNAME="${DEV_USER}" \
            PATH="${DEV_HOME}/.local/bin:${PATH}" \
        "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Phase 2 — unprivileged.
# ---------------------------------------------------------------------------

# Wire up host-side Claude state selectively:
#   - auth (~/.claude.json)         — always shared
#   - projects, memory, credentials — shared if present on host
# Everything else (skills, agents, commands) stays baked into the image layer
# so specialised containers keep their own toolsets.

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

# ---------------------------------------------------------------------------
# Merge layered Claude settings.
#
# Each image in the inheritance chain drops ONE file into ~/.claude-layers/
# containing only its own additions:
#     00-baseline.json   (docker-dev-template)
#     10-embedded.json   (docker-dev-embedded-base)
#     20-arm.json        (docker-dev-embedded-arm)
# They are merged in lexical order with jq's recursive merge, so a later layer
# can add MCP servers without restating the ones it inherited, and can override
# a single inherited key by name.
# ---------------------------------------------------------------------------
LAYER_DIR="$HOME/.claude-layers"
if [ -d "$LAYER_DIR" ] && compgen -G "$LAYER_DIR/*.json" >/dev/null 2>&1; then
    if jq -s 'reduce .[] as $layer ({}; . * $layer)' "$LAYER_DIR"/*.json \
            > "$HOME/.claude/settings.json.new" 2>/dev/null; then
        mv "$HOME/.claude/settings.json.new" "$HOME/.claude/settings.json"
    else
        rm -f "$HOME/.claude/settings.json.new"
        echo "WARN: could not merge Claude settings layers from $LAYER_DIR" >&2
        echo "      leaving existing $HOME/.claude/settings.json in place" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Assemble layered CLAUDE.md memory.
#
# Same inheritance idea as the settings layers above, but CLAUDE.md is prose,
# not JSON, so the layers are CONCATENATED in lexical order rather than
# deep-merged:
#     00-baseline.md   (docker-dev-template)
#     10-embedded.md   (docker-dev-embedded-base)
#     20-arm.md        (docker-dev-embedded-arm)
#
# The result is ~/.claude/CLAUDE.md — user-level memory, loaded in every session
# no matter which project is mounted at /workspace. Its job is to tell Claude
# what toolchains and tools this specific image contains, so it never has to go
# looking. A project's own /workspace/CLAUDE.md still loads on top of this.
#
# Regenerated on every container start, so a rebuilt or re-tagged image cannot
# leave a stale inventory behind.
# ---------------------------------------------------------------------------
MEM_DIR="$HOME/.claude-memory-layers"
if [ -d "$MEM_DIR" ] && compgen -G "$MEM_DIR/*.md" >/dev/null 2>&1; then
    if cat "$MEM_DIR"/*.md > "$HOME/.claude/CLAUDE.md.new" 2>/dev/null; then
        mv "$HOME/.claude/CLAUDE.md.new" "$HOME/.claude/CLAUDE.md"
    else
        rm -f "$HOME/.claude/CLAUDE.md.new"
        echo "WARN: could not assemble Claude memory layers from $MEM_DIR" >&2
        echo "      leaving existing $HOME/.claude/CLAUDE.md in place" >&2
    fi
fi

# Best-effort self-update; never block container start.
# Set DEV_SKIP_UPDATE=1 for fast cold starts or offline use.
if [ "${DEV_SKIP_UPDATE:-0}" != "1" ]; then
    claude update >/dev/null 2>&1 || true
fi

exec "$@"
