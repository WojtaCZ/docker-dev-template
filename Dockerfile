# syntax=docker/dockerfile:1.7
FROM archlinux:latest

ARG USER_NAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Rolling-release full upgrade, then install the baseline toolchain.
# A single pacman call avoids partial-upgrade issues that bite on Arch-based distros.
# util-linux (setpriv) is pulled in by base, and is what entrypoint.sh uses to
# drop privileges after an optional UID/GID remap.
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        base-devel git openssh sudo \
        nodejs npm python uv \
        which less man-db unzip zip \
        curl wget jq github-cli \
        util-linux \
    && pacman -Scc --noconfirm

# Non-root user with passwordless sudo (container is already an isolation boundary)
RUN groupadd --gid ${USER_GID} ${USER_NAME} && \
    useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USER_NAME} && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} && \
    chmod 0440 /etc/sudoers.d/${USER_NAME}

# Workspace mount target, owned by dev
RUN mkdir -p /workspace && chown ${USER_UID}:${USER_GID} /workspace

# Scripts
COPY scripts/entrypoint.sh  /usr/local/bin/entrypoint.sh
COPY scripts/post-create.sh /usr/local/bin/post-create.sh
COPY scripts/dev-doctor.sh  /usr/local/bin/dev-doctor
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/post-create.sh \
             /usr/local/bin/dev-doctor

# Drop-in directory for descendant images to contribute dev-doctor checks.
RUN mkdir -p /opt/dev-doctor/checks.d

# Baked-in baseline Claude config: skills/, agents/, commands/.
# These stay per-image so specialised containers can ship their own toolsets
# while still sharing auth (~/.claude.json) via bind mount at runtime.
COPY --chown=${USER_UID}:${USER_GID} claude-baseline/skills/   /home/${USER_NAME}/.claude/skills/
COPY --chown=${USER_UID}:${USER_GID} claude-baseline/agents/   /home/${USER_NAME}/.claude/agents/
COPY --chown=${USER_UID}:${USER_GID} claude-baseline/commands/ /home/${USER_NAME}/.claude/commands/

# settings.json is NOT copied directly. Each image contributes one layer file to
# ~/.claude-layers/ and entrypoint.sh merges them (lexical order) into
# ~/.claude/settings.json at container start. A leaf therefore declares only its
# own additions instead of restating everything it inherits.
COPY --chown=${USER_UID}:${USER_GID} claude-baseline/settings.json \
     /home/${USER_NAME}/.claude-layers/00-baseline.json

# CLAUDE.md is layered the same way, but concatenated rather than deep-merged
# (it is prose, not JSON). entrypoint.sh assembles ~/.claude-memory-layers/*.md
# into ~/.claude/CLAUDE.md at container start. That inventory is what lets the
# in-container Claude know its toolchains without searching for them.
COPY --chown=${USER_UID}:${USER_GID} claude-baseline/CLAUDE.layer.md \
     /home/${USER_NAME}/.claude-memory-layers/00-baseline.md

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# Claude Code via official installer (lands in ~/.local/bin, supports `claude update`)
RUN curl -fsSL https://claude.ai/install.sh | bash

ENV PATH="/home/${USER_NAME}/.local/bin:${PATH}"

# Default user stays ${USER_NAME}; the entrypoint's root phase is inert here.
# To use the UID/GID remap, start the container as root and let the entrypoint
# drop privileges itself:
#     docker run --user 0:0 -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) ...
# dev-up.sh does this automatically when the host UID is not 1000.
USER ${USER_NAME}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
