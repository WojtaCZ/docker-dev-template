# docker-dev-template — Functional Writeup

> Position in the fleet: **root image**. Everything else descends from this.
> Full-fleet architecture notes live in `docker-dev-embedded-base/WRITEUP.md`.

> **Note:** the analysis below describes the repo *as it was audited* on
> 2026-09-02. Every defect listed has since been fixed and every proposal
> implemented — see **Status: implemented** at the end for the mapping. The
> analysis is kept because it records *why* the current design is the way it is.


## 1. Purpose

`docker-dev-template` is the generic, domain-agnostic foundation for a family of
Docker images built for **AI-driven development** — containers whose primary
"user" is Claude Code running with `--dangerously-skip-permissions`, where the
container boundary (not a permission prompt) is the safety mechanism.

It implements three things and nothing else:

1. A current Arch Linux userland with a general dev toolchain.
2. A non-root `dev` user with passwordless sudo.
3. Claude Code, installed and self-updating, with a **layerable** configuration
   scheme that lets descendant images ship their own skills/agents/commands
   while sharing host authentication.

Everything architecture-specific is deliberately absent.

## 2. Inheritance model

```
archlinux:latest
  └── docker-dev-template                    ← this image
       ├── docker-dev-embedded-base          probe/debug tooling, no compilers
       │    ├── docker-dev-embedded-arm      arm-none-eabi, CMSIS (STM32 / RP2040 / MSPM0)
       │    └── docker-dev-embedded-wch      riscv-none-elf, ch32v003fun
       ├── docker-dev-embedded-telink        tc32 via host-mounted SDK (bypasses embedded-base)
       └── docker-dev-web                    PHP / Bun / Deno / Playwright
```

Inheritance is by **floating `FROM` tag** (`ghcr.io/wojtacz/docker-dev-template:latest`),
not by digest pin. Freshness is driven by two mechanisms:

- `dev-up.sh` passes `--pull` on every build unless `DEV_NO_PULL=1`.
- CI `repository_dispatch` fan-out (see §6).

## 3. Implemented functionality, file by file

### `Dockerfile`

| Stage | What it does |
| --- | --- |
| `FROM archlinux:latest` | Rolling release — chosen so cross-toolchains in the leaves stay near upstream (currently `arm-none-eabi-gcc` 16.2, `clang` 22.1). |
| Single `pacman -Syu` + `-S` | One transaction; avoids the partial-upgrade breakage Arch is prone to. Installs `base-devel git openssh sudo nodejs npm python uv which less man-db unzip zip curl wget jq github-cli`. |
| `groupadd` / `useradd` + sudoers drop-in | Creates `dev` (UID/GID 1000 by default, overridable via `ARG`), passwordless sudo. |
| `/workspace` | Pre-created and chowned so a bind mount lands on a correctly-owned target. |
| `COPY scripts/*` | `entrypoint.sh` and `post-create.sh` to `/usr/local/bin`. |
| `COPY claude-baseline/ → ~/.claude/` | **The layering primitive.** Baked-in Claude config, not a volume. |
| `curl claude.ai/install.sh` | Official installer → `~/.local/bin`, so `claude update` works in place. |

### `scripts/entrypoint.sh` — the state-sharing policy

This is the most load-bearing design decision in the fleet. It splits Claude
state into *shared* and *per-image*:

| State | Location | Shared with host? | Rationale |
| --- | --- | --- | --- |
| Auth / settings / history | `~/.claude.json` | **Yes** — symlink to `/host-claude-auth.json` | One login covers every container. |
| `projects/` | `~/.claude/projects` | Yes, if present on host | Conversation history follows you. |
| `memory/` | `~/.claude/memory` | Yes, if present on host | Persistent memory follows you. |
| `.credentials.json` | `~/.claude/.credentials.json` | Yes, if present on host | Token refresh. |
| `skills/`, `agents/`, `commands/`, `settings.json` | `~/.claude/` | **No** — baked into the image layer | An ARM container must not see Telink skills. |

The host `~/.claude` is bind-mounted at `/host-claude-dir` and only the four
allow-listed entries are symlinked back in. The container's own `~/.claude`
directory stays image content.

It then runs `claude update || true` — best-effort, never blocks startup offline.

### `scripts/post-create.sh`

Devcontainer one-shot hook: sets `init.defaultBranch=main` and marks `/workspace`
(plus `*`) as a git safe directory, required because the bind-mounted repo is
owned by the host UID.

### `claude-baseline/settings.json`

Declares four MCP servers available to every descendant: `github`, `git`,
`context7`, `sequential-thinking`.

### `.devcontainer/devcontainer.json`

VSCode path. Mounts host `~/.claude.json` and `~/.claude`, sets `remoteUser: dev`,
`--init` for correct PID-1 signal handling, and installs a baseline extension set.

### `scripts/dev-up.sh` / `dev-up.ps1`

Headless path (no VSCode). `dev-up.sh` builds, then `docker run --rm -it` with the
workspace, Claude auth, and SSH agent forwarded. `dev-up.ps1` is a thin WSL2 shim
that translates the Windows path via `wslpath` and re-enters `dev-up.sh`.

Env knobs: `DEV_IMAGE`, `DEV_CONTAINER`, `DEV_NO_BUILD`, `DEV_NO_PULL`, `DEV_REBUILD`.

## 4. Verified issues

| # | Severity | Finding |
| --- | --- | --- |
| T1 | Low | `claude update` runs on **every** container start. On a cold `docker run` loop that is a network round-trip per launch. Gate it behind `DEV_SKIP_UPDATE`. |
| T2 | Low | `settings.json` is duplicated verbatim into every descendant (each leaf re-declares all four baseline MCPs). Adding one baseline MCP means editing five repos. See §5.1. |
| T3 | Low | The `dev` UID is fixed at build time (`ARG USER_UID=1000`). If the host user is not UID 1000, files written into `/workspace` get the wrong owner. |
| T4 | Info | `FROM archlinux:latest` + `pacman -Syu` means **no reproducibility**: two builds a week apart produce different toolchains. Acceptable for a dev container, but a green CI build is not evidence that today's build is green. |

## 5. Proposed features

### 5.1 Additive Claude config instead of whole-file replacement — high value

Today each leaf's `settings.json` *replaces* the parent's, so the four baseline
MCP definitions are copy-pasted into five repos. Replace with a merge at
entrypoint time:

```
/home/dev/.claude-layers/00-baseline.json
/home/dev/.claude-layers/10-embedded.json
/home/dev/.claude-layers/20-arm.json
```

Entrypoint runs:

```bash
jq -s 'reduce .[] as $x ({}; . * $x)' /home/dev/.claude-layers/*.json > ~/.claude/settings.json
```

Each layer then declares only its own additions. The same trick assembles a
`CLAUDE.md` from per-layer fragments.

### 5.2 Runtime UID/GID remap

When `HOST_UID`/`HOST_GID` are passed, have `entrypoint.sh` call `usermod -u` /
`groupmod -g` before dropping to `dev`. Fixes T3 without a rebuild.

### 5.3 Pin-and-promote release channel

Publish `:latest` (rolling) and `:stable` (a digest promoted only after the whole
downstream matrix builds green). Leaves track `:stable` by default;
`DEV_CHANNEL=latest` opts into the bleeding edge. Directly addresses T4.

### 5.4 Persistent caches as named volumes

`~/.cache/paru`, `~/.npm`, `~/.cache/uv`, `~/.cargo` are lost on every `--rm` run.
Mounting named volumes for these in `dev-up.sh` is the biggest single
startup-time win available.

### 5.5 A `dev-doctor` command

One script that self-checks the container: Claude auth present, MCP servers
resolvable, `/workspace` writable, toolchain versions, probe visibility. Add a
`--json` mode so CI can assert on it.

### 5.6 Image smoke tests in CI

CI currently builds and pushes with no verification. Add a post-build step that
runs the image and asserts every advertised binary exists:

```yaml
- run: |
    docker run --rm ${{ steps.meta.outputs.tags }} bash -lc '
      set -e
      for b in git node python uv claude jq gh; do
        command -v $b >/dev/null || { echo "MISSING $b"; exit 1; }
      done
    '
```

This alone would have caught the four non-existent package names currently in
`docker-dev-embedded-base` (see that repo's writeup, §5).

## 6. CI propagation

`.github/workflows/publish.yml` builds multi-tag (`branch`, `pr`, `semver`, `sha`,
`latest`) into GHCR with GHA layer caching, then fires `repository_dispatch`:

- `base-image-updated` → `docker-dev-embedded-base`
- `template-image-updated` → `docker-dev-embedded-telink` (directly, because
  Telink does not inherit from embedded-base)

Requires a `DOWNSTREAM_DISPATCH_PAT` fine-grained PAT secret.

> **Gap:** `docker-dev-web` is not in the dispatch fan-out, so it never rebuilds
> automatically when the template changes. Either add it or document that it is
> refreshed manually.

---

## Status: implemented 2026-09-02

Everything proposed in section 5 is now in the repo, and the issues in section 4
are fixed. The sections above are kept as the record of *why*.

| Item | Where |
| --- | --- |
| T1 — gate `claude update` | `scripts/entrypoint.sh` (`DEV_SKIP_UPDATE`) |
| T2 / 5.1 — additive settings layers | `~/.claude-layers/NN-*.json` merged by `entrypoint.sh` with `jq`; each image ships only its own additions |
| T3 / 5.2 — runtime UID/GID remap | `entrypoint.sh` root phase + `setpriv`; `dev-up.sh` triggers it when the host UID is not 1000 |
| T4 / 5.3 — pin-and-promote channel | `.github/workflows/promote-stable.yml`, `BASE_TAG` build arg, `DEV_CHANNEL` |
| 5.4 — persistent caches | named volumes in `dev-up.sh` / `dev-up.ps1` / `devcontainer.json` |
| 5.5 — `dev-doctor` | `scripts/dev-doctor.sh` becomes `/usr/local/bin/dev-doctor`, extensible via `/opt/dev-doctor/checks.d/` |
| 5.6 — CI smoke tests | `tests/smoke.sh`, run before anything is pushed; shellcheck over all scripts |
| Section 6 gap — web not in fan-out | `docker-dev-web` added to the dispatch list |

`BASE_TAG` defaults to `latest` because `:stable` does not exist until the first
promotion runs. Flip the default in each leaf once you have promoted one.
