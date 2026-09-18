# Container environment

You are running inside a **docker-dev** container image. This file is assembled
at container start from one layer per image in the inheritance chain, so the
inventory below is exactly what THIS container has. Trust it instead of
searching the filesystem to find out what is installed.

Fleet inheritance:

```
archlinux:latest
└── docker-dev-template            ← this layer (00-baseline)
    ├── docker-dev-embedded-base   (10-embedded)
    │   ├── docker-dev-embedded-arm    (20-arm)
    │   └── docker-dev-embedded-wch    (20-wch)
    ├── docker-dev-embedded-telink (20-telink)   branches off template, NOT embedded-base
    └── docker-dev-web             (20-web)
```

If a section for a leaf image appears below, that image's tools are present too.
If it does not appear, they are not installed — do not reach for them.

## Baseline layer (every container in the fleet)

| Area | What is here |
|---|---|
| Distro | Arch Linux, rolling. `pacman -S --needed <pkg>` with `sudo`, no AUR helper |
| User | `dev`, uid 1000 by default, **passwordless sudo** |
| Workspace | `/workspace` — the mounted project, and the default cwd |
| Build basics | `base-devel` (gcc, make, binutils, pkg-config), `git`, `patch` |
| Languages | `node`, `npm`, `python`, `uv` |
| CLI | `jq`, `curl`, `wget`, `gh` (GitHub CLI), `ssh`, `less`, `man`, `zip`/`unzip`, `which` |
| Diagnostics | `dev-doctor` — one command that reports on every tool this image ships |
| Claude CLI | installed via the official installer at `~/.local/bin/claude`; `claude update` works |

MCP servers from this layer: `github`, `git`, `context7`, `sequential-thinking`.

**Run `dev-doctor` first** when something environmental looks wrong. It executes
every check in `/opt/dev-doctor/checks.d/` and reports OK/WARN/FAIL per tool —
faster and more reliable than probing for binaries by hand.

## How Claude config is layered in this fleet

Each image contributes only its own additions; the entrypoint assembles them at
container start.

| Asset | Mechanism | Assembled into |
|---|---|---|
| `skills/`, `commands/`, `agents/` | additive `COPY` per image | `~/.claude/{skills,commands,agents}/` |
| `settings.json` | one JSON layer per image in `~/.claude-layers/`, deep-merged with `jq` | `~/.claude/settings.json` |
| `CLAUDE.md` | one Markdown layer per image in `~/.claude-memory-layers/`, concatenated in lexical order | `~/.claude/CLAUDE.md` |

Shared from the host at runtime: `~/.claude.json` (auth), plus `projects/`,
`memory/` and `.credentials.json` when the host has them. Everything else is
baked into the image.

## MAINTENANCE RULE — read this before adding a skill, command or tool

These images are built from source repos on the host
(`docker-dev-template`, `docker-dev-embedded-{base,arm,wch,telink}`,
`docker-dev-web`). When you add anything to one of them, do **all** of the
following in the same change, or the in-container Claude will not see it:

1. **Skills must be directories, not flat files.** Claude Code only indexes
   `~/.claude/skills/<name>/SKILL.md` carrying YAML frontmatter with `name` and
   `description`. A bare `skills/<name>.md` is never loaded — it is dead weight
   in the image. Write new skills as
   `claude-<image>/skills/<name>/SKILL.md`, and make the `description` name the
   concrete triggers (symptoms, APIs, error strings), because that text is the
   only thing deciding whether the skill gets picked up.
2. **Register it in this image's memory layer** —
   `claude-<image>/CLAUDE.layer.md` in that repo. Add the tool to the inventory
   table, or the skill to the skills list, with one line on when to reach for
   it. That is what removes the need to search.
3. **Add a `dev-doctor` check** in `dev-doctor-checks/` if it is a tool or a
   data store that can be missing or misconfigured.
4. **Assert it in `tests/smoke.sh`** so a broken `COPY` fails CI instead of
   surfacing as a mystery months later.

Legacy note: skills added before this rule still exist as flat
`skills/<name>.md` files. They are **not** indexed and will not trigger on their
own — the skills lists in the layers below are how you know they exist. Read one
directly from `~/.claude/skills/<name>.md` when its topic comes up, and convert
it to directory form if you are editing it anyway.
