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
├── scripts/
│   ├── entrypoint.sh            # runs on every start (symlinks shared state, self-update)
│   └── post-create.sh           # runs once after create (git config)
└── claude-baseline/             # baked into /home/dev/.claude/
    ├── settings.json            # MCP servers
    ├── skills/                  # per-container skills (placeholder)
    ├── agents/                  # per-container agents (placeholder)
    └── commands/                # per-container slash commands (placeholder)
```

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
FROM ghcr.io/wojtacz/docker-dev-template:latest

# Extra toolchain
USER root
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        arm-none-eabi-gcc arm-none-eabi-newlib \
        openocd gdb-multiarch stlink cmake ninja picocom dfu-util \
    && pacman -Scc --noconfirm
USER dev

# Stack additional skills/agents on top of the baseline.
# Use distinct subdir names to avoid overwriting baseline skills; reuse a
# baseline skill's dir name only if you intentionally want to override it.
COPY --chown=dev:dev skills/    /home/dev/.claude/skills/
COPY --chown=dev:dev agents/    /home/dev/.claude/agents/

# If you need to merge MCP servers, ship a complete settings.json that
# includes baseline servers plus specialisation-specific ones.
COPY --chown=dev:dev settings.json /home/dev/.claude/settings.json
```

### Pinning vs. rolling

- **`latest`** — zero-friction propagation. Good for personal dev templates where you want every fix immediately. Trade-off: a bad commit in base breaks every downstream until reverted.
- **`vX.Y.Z`** — immutable pin. Use in shared/production templates. Bump the tag in each specialised repo when you want to adopt a new baseline. Pair with **Renovate** or **Dependabot** to auto-open PRs when a new tag lands.

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
./scripts/dev-up.sh                   # workspace = $(pwd)
./scripts/dev-up.sh ~/code/my-proj    # mount a specific project
DEV_REBUILD=1 ./scripts/dev-up.sh     # force clean rebuild
DEV_NO_BUILD=1 ./scripts/dev-up.sh    # skip build, just run
```

Both scripts mount `~/.claude.json` + `~/.claude/` (shared auth & history) and forward the host SSH agent via Docker Desktop's magic socket (`/run/host-services/ssh-auth.sock`). On Windows this requires the **OpenSSH Authentication Agent** service to be running; on macOS Docker Desktop wires it up automatically; on Linux it uses `$SSH_AUTH_SOCK` from the host shell.

**Aliasing for convenience:**

Windows — add to your PowerShell profile (`$PROFILE`):
```powershell
function dev-up { & C:\Users\you\Documents\docker-dev-template\scripts\dev-up.ps1 @args }
```

Linux/macOS — add to `~/.bashrc` or `~/.zshrc`:
```bash
alias dev-up='~/Documents/docker-dev-template/scripts/dev-up.sh'
```
