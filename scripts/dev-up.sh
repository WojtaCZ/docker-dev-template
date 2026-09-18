#!/usr/bin/env bash
# Headless build + run for the baseline dev container on Linux/macOS.
#
# Usage:
#   ./scripts/dev-up.sh                 # workspace = $(pwd)
#   ./scripts/dev-up.sh /path/to/proj   # workspace = /path/to/proj
#
# Env vars:
#   DEV_IMAGE=<name>      image tag              (default: dev-template-baseline)
#   DEV_CONTAINER=<name>  running container name (default: dev-template)
#   DEV_NO_BUILD=1        skip docker build
#   DEV_NO_PULL=1         don't `--pull` the base image (offline / pin)
#   DEV_REBUILD=1         docker build --no-cache
#   DEV_NO_CACHE_VOLUMES=1  don't mount the persistent package-cache volumes
#   DEV_SKIP_UPDATE=1     skip `claude update` on container start
#   DEV_DOCTOR=1          run dev-doctor instead of an interactive shell

set -euo pipefail

IMAGE_NAME="${DEV_IMAGE:-dev-template-baseline}"
CONTAINER_NAME="${DEV_CONTAINER:-dev-template}"
WORKSPACE="${1:-$(pwd)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${DEV_NO_BUILD:-0}" != "1" ]; then
    BUILD_FLAGS=()
    [ "${DEV_NO_PULL:-0}" != "1" ] && BUILD_FLAGS+=("--pull")
    [ "${DEV_REBUILD:-0}" = "1" ]  && BUILD_FLAGS+=("--no-cache")
    docker build "${BUILD_FLAGS[@]}" -t "$IMAGE_NAME" "$REPO_ROOT"
fi

CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_DIR="$HOME/.claude"

if [ ! -f "$CLAUDE_JSON" ]; then
    echo "WARN: $CLAUDE_JSON not found. Run 'claude' on the host at least once." >&2
fi
mkdir -p "$CLAUDE_DIR"

MOUNTS=(
    -v "$WORKSPACE:/workspace"
    -v "$CLAUDE_JSON:/host-claude-auth.json"
    -v "$CLAUDE_DIR:/host-claude-dir"
)

# Persistent package caches. Without these every `--rm` run re-downloads npm,
# uv and cargo content from scratch — the single biggest startup cost.
if [ "${DEV_NO_CACHE_VOLUMES:-0}" != "1" ]; then
    MOUNTS+=(
        -v "dev-cache-npm:/home/dev/.npm"
        -v "dev-cache-uv:/home/dev/.cache/uv"
        -v "dev-cache-cargo:/home/dev/.cargo"
        -v "dev-cache-pkg:/home/dev/.cache/pkg"
    )
fi

# UID/GID alignment. Files written into the bind-mounted workspace must be
# owned by the host user. When the host UID is not the baked-in 1000 we start
# the container as root and let entrypoint.sh remap and drop privileges.
USER_ARGS=()
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
if [ "$HOST_UID" != "1000" ] || [ "$HOST_GID" != "1000" ]; then
    USER_ARGS=(--user 0:0 -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")
fi

ENV_ARGS=()
[ "${DEV_SKIP_UPDATE:-0}" = "1" ] && ENV_ARGS+=(-e DEV_SKIP_UPDATE=1)
[ -n "${GITHUB_TOKEN:-}" ] && ENV_ARGS+=(-e "GITHUB_TOKEN=$GITHUB_TOKEN")

SSH_ARGS=()
case "$(uname -s)" in
    Darwin)
        # Docker Desktop for Mac exposes host ssh-agent at this magic socket
        SSH_ARGS=(-v /run/host-services/ssh-auth.sock:/ssh-agent
                  -e SSH_AUTH_SOCK=/ssh-agent)
        ;;
    Linux)
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
            SSH_ARGS=(-v "$SSH_AUTH_SOCK:/ssh-agent"
                      -e SSH_AUTH_SOCK=/ssh-agent)
        else
            echo "WARN: SSH_AUTH_SOCK not set; git over SSH won't work inside the container." >&2
        fi
        ;;
esac

CMD_ARGS=()
[ "${DEV_DOCTOR:-0}" = "1" ] && CMD_ARGS=(dev-doctor)

exec docker run --rm -it \
    --name "$CONTAINER_NAME" \
    --init \
    "${MOUNTS[@]}" \
    "${USER_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "${SSH_ARGS[@]}" \
    "$IMAGE_NAME" "${CMD_ARGS[@]}"
