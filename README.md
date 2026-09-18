# docker-dev-template

A baseline dev container for Claude Code-driven development.

- **Base OS:** Arch Linux (`archlinux:latest`) — rolling release, very recent toolchains
- **User:** non-root `dev` with passwordless `sudo` inside the container
- **Claude Code:** pre-installed, self-updates on container start, safe to run with `--dangerously-skip-permissions`
- **Workspace:** bind-mounted at `/workspace`
- **Auth sharing:** host `~/.claude.json` is shared across every container built from this template
- **Skill isolation:** each container ships its own `~/.claude/skills|agents|commands|settings.json` baked into the image

## Quick start (VSCode)

1. Install **Docker Desktop** and the **Dev Containers** VSCode extension.
2. Clone this repo (or a project that uses it as a base image) and open it in VSCode.
3. Command palette → **Dev Containers: Reopen in Container**.

On first run the container will:

- Full-upgrade Arch and install the baseline toolchain
- Install Claude Code under `/home/dev/.local/bin`
- Symlink your host `~/.claude.json` into the container so auth is shared
- Run `claude update` on every subsequent start

## Layout

```
.
├── Dockerfile                   # Arch base, dev user, Claude Code
├── .devcontainer/
│   └── devcontainer.json        # VSCode mounts + extensions
├── .github/workflows/
│   ├── publish.yml              # build → smoke test → push → fan out
│   └── promote-stable.yml       # retag a verified digest as :stable
├── scripts/
│   ├── entrypoint.sh            # every start: UID remap, shared state, settings merge
│   ├── post-create.sh           # once after create (git config)
│   └── dev-doctor.sh            # → /usr/local/bin/dev-doctor
└── claude-baseline/
    ├── settings.json            # → ~/.claude-layers/00-baseline.json  (merged at start)
    ├── skills/                  # → ~/.claude/skills/     (per-container)
    ├── agents/                  # → ~/.claude/agents/     (per-container)
    └── commands/                # → ~/.claude/commands/   (per-container)
```

## Layered Claude settings

`settings.json` is **not** copied straight to `~/.claude/settings.json`. Each
image in the inheritance chain drops one file into `~/.claude-layers/`
containing only its own additions:

```
~/.claude-layers/00-baseline.json   docker-dev-template
~/.claude-layers/10-embedded.json   docker-dev-embedded-base
~/.claude-layers/20-arm.json        docker-dev-embedded-arm
```

`entrypoint.sh` merges them in lexical order with jq's recursive merge
(`reduce .[] as $l ({}; . * $l)`) into `~/.claude/settings.json` at container
start. A leaf therefore declares only the MCP servers it adds, instead of
restating everything it inherits — add a baseline MCP once, and every
descendant picks it up on its next start.

To override a single inherited server, redeclare it by the same key in a
higher-numbered layer.

## dev-doctor

Every image ships `/usr/local/bin/dev-doctor`, which self-checks the container:
baseline binaries, Claude auth, merged settings validity, that every declared
MCP server's launcher resolves, `/workspace` writability, and host/container UID
alignment.

```bash
dev-doctor            # human-readable table
dev-doctor --json     # machine-readable; exits non-zero on any FAIL
```

Descendant images extend it by dropping an executable into
`/opt/dev-doctor/checks.d/`. Each check prints `STATUS|name|detail` lines with
`STATUS` in `OK` / `WARN` / `FAIL`; only `FAIL` affects the exit status. CI runs
`dev-doctor --json | jq -e '.ok == true'` before anything is pushed.

## Sharing auth without sharing skills

`.claude.json` holds **auth + settings + history**; it does *not* contain skill content. Skills, agents and commands live as files under `~/.claude/skills/`, `~/.claude/agents/`, `~/.claude/commands/`.

The devcontainer mounts the host's `~/.claude.json` and `~/.claude` directory under `/host-claude-auth.json` and `/host-claude-dir/`. The entrypoint then **symlinks only the sharable bits** (`projects/`, `memory/`, `.credentials.json`) into the container's `~/.claude/`, leaving the baked-in `skills/`, `agents/`, `commands/` and `settings.json` untouched.

Result: a specialised container (embedded, web, data) shares conversation history and auth with the host, but carries its **own** skill/agent/MCP set.

## Baseline MCP servers

Declared in `claude-baseline/settings.json`:

| Server                | Purpose                                  |
| --------------------- | ---------------------------------------- |
| `github`              | Repos, issues, PRs, Actions (needs `GITHUB_TOKEN`) |
| `git`                 | Local repo inspection                    |
| `context7`            | Up-to-date library/framework docs        |
| `sequential-thinking` | Structured multi-step reasoning          |

Set `GITHUB_TOKEN` in your host environment (or in VSCode's `remoteEnv`) for the GitHub MCP to work.

## Baseline skills (suggested, to be dropped into `claude-baseline/skills/`)

- `init` — bootstrap CLAUDE.md in a new project
- `review` — PR review pass
- `security-review` — pre-merge security review
- `simplify` — code quality pass
- `less-permission-prompts` — reduce permission friction

The placeholder `.gitkeep` files keep the dirs in git until you drop skill content in.

## Building a specialised image

Specialised containers inherit everything baked into the baseline by using it as their `FROM` image. Any change you push here flows to every downstream image on its next `docker build --pull`.

### How propagation works

1. **Push** a change to this repo (`main`).
2. The **`publish.yml`** GitHub Action rebuilds the image and pushes to GHCR at `ghcr.io/wojtacz/docker-dev-template` with tags:
   - `latest`       — rolling, tracks `main`
   - `main-<sha>`   — immutable, per commit
   - `vX.Y.Z`, `vX.Y` — on git tags, for pinned releases
3. A specialised Dockerfile does `FROM ghcr.io/wojtacz/docker-dev-template:latest`.
4. Its `dev-up.sh`/`.ps1` runs `docker build --pull`, which **refreshes the base layer** before rebuilding on top. Updated skills, scripts, MCP config, and toolchain all propagate.

### Example specialised Dockerfile

```Dockerfile
ARG BASE_TAG=latest
FROM ghcr.io/wojtacz/docker-dev-template:${BASE_TAG}

# Extra toolchain.
# NOTE Arch package names: use `gdb` (built --enable-targets=all, so it IS the
# multiarch gdb — there is no `gdb-multiarch` package), and do not ask for
# `clang-tools-extra`; clangd/clang-tidy/clang-format ship inside `clang`.
USER root
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        arm-none-eabi-gcc arm-none-eabi-newlib \
        openocd gdb stlink probe-rs cmake ninja picocom dfu-util \
    && pacman -Scc --noconfirm
USER dev

# Stack additional skills/agents on top of the baseline.
# Use distinct filenames to avoid overwriting baseline skills; reuse a baseline
# skill's filename only if you intentionally want to override it.
COPY --chown=dev:dev skills/ /home/dev/.claude/skills/
COPY --chown=dev:dev agents/ /home/dev/.claude/agents/

# MCP servers: ship ONLY your additions as a numbered layer. The entrypoint
# merges every ~/.claude-layers/*.json in lexical order, so there is no need to
# restate the baseline servers.
COPY --chown=dev:dev settings.layer.json /home/dev/.claude-layers/10-myimage.json

# Optional: contribute a dev-doctor check for whatever you just installed.
COPY --chown=root:root checks/50-mytoolchain.sh /opt/dev-doctor/checks.d/
RUN chmod +x /opt/dev-doctor/checks.d/50-mytoolchain.sh
```

### Release channels: `latest` vs `stable`

| Tag | Moves when | Use for |
| --- | --- | --- |
| `latest` | every green build of `main` (after this repo's own smoke test) | personal dev, you want fixes immediately |
| `stable` | only after the downstream leaves also build green against it | when you want a quiet week |
| `vX.Y.Z` | never — immutable | shared/production templates |

`stable` is moved by `.github/workflows/promote-stable.yml`, which retags an
existing digest via `docker buildx imagetools create` (no rebuild, no layer
re-upload). It fires on a `downstream-verified` repository dispatch from a leaf
repo, or manually via `workflow_dispatch`.

Leaf Dockerfiles take a `BASE_TAG` build arg so you can switch channel without
editing the `FROM` line:

```bash
docker build --build-arg BASE_TAG=stable -t my-leaf .
DEV_CHANNEL=stable ./scripts/dev-up.sh     # same thing, via the helper
```

> `BASE_TAG` defaults to `latest` because `:stable` does not exist until the
> first promotion runs. Flip the default in each leaf once you have promoted.

### Triggering downstream rebuilds automatically

Two common setups, in increasing order of plumbing:

1. **On-demand** (simplest) — developer runs `dev-up.sh` / `.ps1`; the built-in `--pull` picks up new base layers.
2. **Renovate PRs** — add a `renovate.json` to each specialised repo pinning `ghcr.io/wojtacz/docker-dev-template` — Renovate opens a PR whenever a new tag publishes.
3. **Fan-out dispatch** — the base repo's workflow fires a `repository_dispatch` event at each specialised repo after a successful publish, triggering their own rebuild workflow.

## Git / SSH

The devcontainer relies on VSCode's built-in SSH agent forwarding. Ensure your host SSH agent is running and has your key loaded:

**Windows (PowerShell, admin):**
```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

**Linux/macOS:**
```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

Inside the container, verify with `ssh -T git@github.com`.

## Running Claude Code

Inside the container:

```bash
claude --dangerously-skip-permissions
```

Running as `dev` (UID 1000), not root — safe to use the skip-permissions flag since the container is already an isolation boundary.

## Headless CLI (no VSCode)

Helper scripts build the image and drop you into a shell with all mounts and SSH agent forwarding set up:

**Windows (PowerShell):**
```powershell
.\scripts\dev-up.ps1                              # workspace = current dir
.\scripts\dev-up.ps1 -Workspace C:\code\my-proj   # mount a specific project
.\scripts\dev-up.ps1 -Rebuild                     # force clean rebuild
.\scripts\dev-up.ps1 -NoBuild                     # skip build, just run
```

**Linux / macOS:**
```bash
./scripts/dev-up.sh                        # workspace = $(pwd)
./scripts/dev-up.sh ~/code/my-proj         # mount a specific project
DEV_REBUILD=1 ./scripts/dev-up.sh          # force clean rebuild
DEV_NO_BUILD=1 ./scripts/dev-up.sh         # skip build, just run
DEV_SKIP_UPDATE=1 ./scripts/dev-up.sh      # skip `claude update` (fast/offline start)
DEV_DOCTOR=1 ./scripts/dev-up.sh           # run dev-doctor and exit
DEV_NO_CACHE_VOLUMES=1 ./scripts/dev-up.sh # don't mount the package caches
```

Both scripts mount `~/.claude.json` + `~/.claude/` (shared auth & history) and forward the host SSH agent via Docker Desktop's magic socket (`/run/host-services/ssh-auth.sock`). On Windows this requires the **OpenSSH Authentication Agent** service to be running; on macOS Docker Desktop wires it up automatically; on Linux it uses `$SSH_AUTH_SOCK` from the host shell.

### Persistent caches

`--rm` containers otherwise re-download every dependency on each launch. The
helpers mount four named volumes:

| Volume | Mounted at |
| --- | --- |
| `dev-cache-npm` | `/home/dev/.npm` |
| `dev-cache-uv` | `/home/dev/.cache/uv` |
| `dev-cache-cargo` | `/home/dev/.cargo` |
| `dev-cache-pkg` | `/home/dev/.cache/pkg` |

Wipe them with `docker volume rm dev-cache-npm dev-cache-uv dev-cache-cargo dev-cache-pkg`.

### Host UID alignment

The `dev` user is UID 1000 in the image. On Linux, if your host UID differs,
everything written into `/workspace` lands with the wrong owner. `dev-up.sh`
detects this and starts the container as root with `HOST_UID`/`HOST_GID` set;
`entrypoint.sh` then remaps `dev` and drops privileges with `setpriv` before
running anything. Docker Desktop (Windows/macOS) presents bind mounts as UID
1000 already, so no remap happens there.

`dev-doctor` warns when the container UID and `/workspace` owner disagree.

**Aliasing for convenience:**

Windows — add to your PowerShell profile (`$PROFILE`):
```powershell
function dev-up { & C:\Users\you\Documents\docker-dev-template\scripts\dev-up.ps1 @args }
```

Linux/macOS — add to `~/.bashrc` or `~/.zshrc`:
```bash
alias dev-up='~/Documents/docker-dev-template/scripts/dev-up.sh'
```
