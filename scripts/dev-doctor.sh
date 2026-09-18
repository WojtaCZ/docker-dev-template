#!/usr/bin/env bash
# dev-doctor — self-check the container.
#
# Runs the baseline checks below, then every executable in
# /opt/dev-doctor/checks.d/ so each image in the inheritance chain can add its
# own without editing this file.
#
# Check scripts emit one record per line:
#     STATUS|name|detail
# where STATUS is OK, WARN or FAIL.
#
# Usage:
#   dev-doctor           human-readable table
#   dev-doctor --json    machine-readable, for CI assertions
#
# Exit status: 0 if no FAIL, 1 otherwise. WARN never fails the run.

set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

CHECK_DIR="/opt/dev-doctor/checks.d"
RESULTS=()

emit() { RESULTS+=("$1|$2|$3"); }

have() { command -v "$1" >/dev/null 2>&1; }

check_bin() {
    local bin="$1" label="${2:-$1}"
    if have "$bin"; then
        emit OK "$label" "$(command -v "$bin")"
    else
        emit FAIL "$label" "not found on PATH"
    fi
}

# --------------------------------------------------------------------------
# Baseline checks
# --------------------------------------------------------------------------
for b in git node npm python uv jq gh curl; do
    check_bin "$b"
done

if have claude; then
    emit OK "claude" "$(claude --version 2>/dev/null | head -1)"
else
    emit FAIL "claude" "Claude Code not on PATH"
fi

# Auth
if [ -e "$HOME/.claude.json" ]; then
    emit OK "claude-auth" "$HOME/.claude.json present"
else
    emit WARN "claude-auth" "no ~/.claude.json — run 'claude' on the host, then remount"
fi

# Settings were produced by the layer merge
if [ -s "$HOME/.claude/settings.json" ]; then
    if jq -e . "$HOME/.claude/settings.json" >/dev/null 2>&1; then
        n=$(jq -r '.mcpServers | length // 0' "$HOME/.claude/settings.json")
        emit OK "claude-settings" "valid JSON, ${n} MCP server(s)"
    else
        emit FAIL "claude-settings" "$HOME/.claude/settings.json is not valid JSON"
    fi
else
    emit WARN "claude-settings" "$HOME/.claude/settings.json missing or empty"
fi

# CLAUDE.md was produced by the memory-layer concatenation. This is the image's
# tool inventory — without it the in-container Claude has to rediscover what is
# installed on every session.
if [ -s "$HOME/.claude/CLAUDE.md" ]; then
    layers=$(ls "$HOME/.claude-memory-layers" 2>/dev/null | tr '\n' ' ')
    emit OK "claude-memory" "$HOME/.claude/CLAUDE.md assembled from: ${layers:-unknown}"
else
    emit WARN "claude-memory" "$HOME/.claude/CLAUDE.md missing — tool inventory unavailable to Claude"
fi

# Every MCP server's launcher must at least exist
if [ -s "$HOME/.claude/settings.json" ] && jq -e . "$HOME/.claude/settings.json" >/dev/null 2>&1; then
    while IFS=$'\t' read -r name cmd; do
        [ -z "$name" ] && continue
        if have "$cmd"; then
            emit OK "mcp:$name" "launcher '$cmd' present"
        else
            emit FAIL "mcp:$name" "launcher '$cmd' not on PATH"
        fi
    done < <(jq -r '.mcpServers // {} | to_entries[] | "\(.key)\t\(.value.command)"' \
                "$HOME/.claude/settings.json")
fi

# Workspace
if [ -d /workspace ]; then
    if [ -w /workspace ]; then
        emit OK "workspace" "/workspace writable"
    else
        emit FAIL "workspace" "/workspace not writable by $(id -un) ($(id -u))"
    fi
else
    emit WARN "workspace" "/workspace does not exist"
fi

# UID alignment against the bind-mounted workspace
if [ -d /workspace ]; then
    owner="$(stat -c %u /workspace 2>/dev/null || echo '')"
    if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
        emit WARN "workspace-uid" \
            "/workspace owned by uid $owner, running as $(id -u) — pass HOST_UID=$owner"
    elif [ -n "$owner" ]; then
        emit OK "workspace-uid" "uid $owner matches container user"
    fi
fi

# git safe.directory, otherwise every git call in /workspace fails
if git -C /workspace rev-parse --git-dir >/dev/null 2>&1; then
    emit OK "git-workspace" "git usable in /workspace"
elif [ -d /workspace/.git ]; then
    emit FAIL "git-workspace" "/workspace is a repo but git refuses it (safe.directory?)"
fi

# --------------------------------------------------------------------------
# Layered checks contributed by descendant images
# --------------------------------------------------------------------------
if [ -d "$CHECK_DIR" ]; then
    for script in "$CHECK_DIR"/*; do
        [ -x "$script" ] || continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            RESULTS+=("$line")
        done < <("$script" 2>/dev/null || true)
    done
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
fails=0
warns=0
for r in "${RESULTS[@]}"; do
    case "${r%%|*}" in
        FAIL) fails=$((fails + 1)) ;;
        WARN) warns=$((warns + 1)) ;;
    esac
done

if [ "$JSON" = "1" ]; then
    printf '%s\n' "${RESULTS[@]}" | jq -R -s --argjson fails "$fails" --argjson warns "$warns" '
        {
          ok: ($fails == 0),
          fails: $fails,
          warns: $warns,
          checks: (split("\n") | map(select(length > 0)) | map(split("|") |
                   {status: .[0], name: .[1], detail: (.[2] // "")}))
        }'
else
    printf '%-6s  %-24s  %s\n' "STATUS" "CHECK" "DETAIL"
    printf '%-6s  %-24s  %s\n' "------" "------------------------" "------"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r status name detail <<< "$r"
        printf '%-6s  %-24s  %s\n' "$status" "$name" "$detail"
    done
    echo
    if [ "$fails" -eq 0 ]; then
        echo "dev-doctor: OK (${warns} warning(s))"
    else
        echo "dev-doctor: ${fails} FAILURE(S), ${warns} warning(s)"
    fi
fi

[ "$fails" -eq 0 ]
