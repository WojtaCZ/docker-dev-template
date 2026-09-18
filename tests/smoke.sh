#!/usr/bin/env bash
# Smoke test for docker-dev-template. Runs INSIDE the built image.
#
#   docker run --rm -e DEV_SKIP_UPDATE=1 -v "$PWD/tests:/tests:ro" <image> bash /tests/smoke.sh
#
# Exits non-zero on the first failure so CI never publishes a broken image.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

echo "== baseline binaries =="
for b in git node npm python uv jq gh curl wget ssh sudo setpriv claude; do
    command -v "$b" >/dev/null || fail "missing binary: $b"
    pass "$b"
done

echo "== user identity =="
[ "$(id -un)" = "dev" ] || fail "expected to run as 'dev', got '$(id -un)'"
pass "running as dev ($(id -u):$(id -g))"
sudo -n true 2>/dev/null || fail "dev cannot sudo without a password"
pass "passwordless sudo works"

echo "== claude config layering =="
[ -d "$HOME/.claude-layers" ] || fail "~/.claude-layers missing"
[ -f "$HOME/.claude-layers/00-baseline.json" ] || fail "baseline layer not installed"
pass "layer dir present: $(ls "$HOME/.claude-layers" | tr '\n' ' ')"

[ -s "$HOME/.claude/settings.json" ] || fail "entrypoint did not produce ~/.claude/settings.json"
jq -e . "$HOME/.claude/settings.json" >/dev/null || fail "merged settings.json is not valid JSON"
pass "merged settings.json is valid JSON"

for server in github git context7 sequential-thinking; do
    jq -e --arg s "$server" '.mcpServers | has($s)' "$HOME/.claude/settings.json" >/dev/null \
        || fail "MCP server '$server' missing from merged settings"
    pass "mcp: $server"
done

echo "== every declared MCP launcher resolves =="
while IFS=$'\t' read -r name cmd; do
    [ -n "$name" ] || continue
    command -v "$cmd" >/dev/null || fail "MCP '$name' needs '$cmd', which is not on PATH"
    pass "$name -> $cmd"
done < <(jq -r '.mcpServers // {} | to_entries[] | "\(.key)\t\(.value.command)"' \
            "$HOME/.claude/settings.json")

echo "== claude skills/agents/commands dirs exist =="
for d in skills agents commands; do
    [ -d "$HOME/.claude/$d" ] || fail "~/.claude/$d missing"
    pass "$d/"
done

echo "== workspace =="
[ -d /workspace ] || fail "/workspace missing"
touch /workspace/.smoke-write-test && rm -f /workspace/.smoke-write-test \
    || fail "/workspace not writable by dev"
pass "/workspace writable"

echo "== dev-doctor =="
dev-doctor
dev-doctor --json | jq -e '.ok == true' >/dev/null || fail "dev-doctor reported failures"
pass "dev-doctor clean"

echo "== CLAUDE.md memory layers assembled =="
M="$HOME/.claude/CLAUDE.md"
[ -d "$HOME/.claude-memory-layers" ] || fail "~/.claude-memory-layers missing"
for l in 00-baseline.md; do
    [ -f "$HOME/.claude-memory-layers/$l" ] || fail "memory layer $l not installed"
done
pass "memory layers present: $(ls "$HOME/.claude-memory-layers" | tr '\n' ' ')"
[ -s "$M" ] || fail "entrypoint did not assemble ~/.claude/CLAUDE.md"
grep -q "MAINTENANCE RULE" "$M" || fail "merged CLAUDE.md is missing this image's layer (MAINTENANCE RULE)"
pass "CLAUDE.md assembled, this image's layer present"

echo
echo "SMOKE TEST PASSED"
