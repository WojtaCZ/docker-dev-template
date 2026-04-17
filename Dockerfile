# syntax=docker/dockerfile:1.7
FROM archlinux:latest

ARG USER_NAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Rolling-release full upgrade, then install the baseline toolchain.
# A single pacman call avoids partial-upgrade issues that bite on Arch-based distros.
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        base-devel git openssh sudo \
        nodejs npm python uv \
        which less man-db unzip zip \
        curl wget jq github-cli \
    && pacman -Scc --noconfirm

# Non-root user with passwordless sudo (container is already an isolation boundary)
RUN groupadd --gid ${USER_GID} ${USER_NAME} && \
    useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USER_NAME} && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} && \
    chmod 0440 /etc/sudoers.d/${USER_NAME}

# Workspace mount target, owned by dev
RUN mkdir -p /workspace && chown ${USER_UID}:${USER_GID} /workspace

# Scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/post-create.sh /usr/local/bin/post-create.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/post-create.sh

# Baked-in baseline Claude config: skills/, agents/, commands/, settings.json.
# These stay per-image so specialised containers can ship their own toolsets
# while still sharing auth (~/.claude.json) via bind mount at runtime.
COPY --chown=${USER_UID}:${USER_GID} claude-baseline/ /home/${USER_NAME}/.claude/

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# Claude Code via official installer (lands in ~/.local/bin, supports `claude update`)
RUN curl -fsSL https://claude.ai/install.sh | bash

ENV PATH="/home/${USER_NAME}/.local/bin:${PATH}"

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
