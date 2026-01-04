# ==============================================================================
# Base stage: Minimal runtime for docker-compose (run/test)
# ==============================================================================
FROM ubuntu:22.04 AS base

# Install minimal base dependencies
# Note: Don't clean up apt lists yet - setup.sh needs them with --docker-optimize
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    sudo \
    git \
    ca-certificates \
    xz-utils

# Create non-root user
RUN useradd -m -s /bin/bash vscode && \
    echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Copy setup scripts
COPY scripts /tmp/scripts

# Install required dependencies only (bash, just, direnv, python, uv)
RUN cd /tmp/scripts && \
    chmod +x setup.sh && \
    ./setup.sh --docker-optimize && \
    rm -rf /tmp/scripts

USER vscode
WORKDIR /workspaces

# ==============================================================================
# Dev stage: Full development environment for DevContainers
# ==============================================================================
FROM base AS dev

USER root

# Copy setup scripts again for dev tools installation
COPY scripts /tmp/scripts

# Install development tools (docker, node/npx, gcloud, shellcheck, shfmt, claude)
# and template testing tools (bats-core), with starship prompt
RUN cd /tmp/scripts && \
    chmod +x setup.sh && \
    ./setup.sh --dev --template --starship --docker-optimize && \
    rm -rf /tmp/scripts

# Configure direnv to auto-allow workspace directory
RUN mkdir -p /home/vscode/.config/direnv && \
    echo '[whitelist]' > /home/vscode/.config/direnv/direnv.toml && \
    echo 'prefix = [ "/workspaces" ]' >> /home/vscode/.config/direnv/direnv.toml && \
    chown -R vscode:vscode /home/vscode/.config

# Add direnv hook to vscode user's bashrc
RUN echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc && \
    chown vscode:vscode /home/vscode/.bashrc

USER vscode
WORKDIR /workspaces
