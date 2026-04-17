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

```Dockerfile
FROM ghcr.io/wojtacz/docker-dev-template:latest

# Add toolchain
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed arm-none-eabi-gcc openocd gdb-multiarch stlink

# Ship container-specific skills/agents/MCP config
COPY --chown=dev:dev skills/    /home/dev/.claude/skills/
COPY --chown=dev:dev agents/    /home/dev/.claude/agents/
COPY --chown=dev:dev commands/  /home/dev/.claude/commands/
COPY --chown=dev:dev settings.json /home/dev/.claude/settings.json
```

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
