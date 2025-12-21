# ==============================================================================
# Base stage: Minimal runtime for docker-compose (run/test)
# ==============================================================================
FROM ubuntu:22.04 AS base

# Install minimal base dependencies
# NOTE: Package list cleanup happens after setup.sh (which may add more packages)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    sudo \
    git \
    ca-certificates \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev

# Create non-root user
RUN useradd -m -s /bin/bash vscode && \
    echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Copy setup scripts and project files needed for Python installation
COPY scripts /tmp/scripts
COPY .python-version /tmp/.python-version
COPY pyproject.toml /tmp/pyproject.toml

# Install system-level required dependencies as root (bash, just, direnv, python3.12)
RUN cd /tmp && \
    chmod +x scripts/setup.sh && \
    scripts/setup.sh --docker-optimize

# Switch to vscode user for user-level installations
USER vscode

# Install uv as vscode user and sync dependencies
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    export PATH="$HOME/.cargo/bin:$PATH" && \
    cd /tmp && \
    uv sync --all-extras

# Cleanup
USER root
RUN rm -rf /tmp/scripts /tmp/.python-version /tmp/pyproject.toml
USER vscode

WORKDIR /workspaces

# Add uv to PATH
ENV PATH="/home/vscode/.cargo/bin:${PATH}"

# Configure direnv to auto-allow .envrc files (dev container convenience)
RUN mkdir -p ~/.config/direnv && \
    echo '[whitelist]' > ~/.config/direnv/direnv.toml && \
    echo 'prefix = [ "/workspaces" ]' >> ~/.config/direnv/direnv.toml

# ==============================================================================
# Dev stage: Full development environment for DevContainers
# ==============================================================================
FROM base AS dev

USER root

# Copy setup scripts again for dev tools installation
COPY scripts /tmp/scripts

# Install development tools (docker, node/npx, gcloud, shellcheck, shfmt, claude)
# and template testing tools (bats-core) and starship prompt
RUN cd /tmp/scripts && \
    chmod +x setup.sh && \
    ./setup.sh --dev --template --starship --docker-optimize && \
    rm -rf /tmp/scripts

# Add direnv hook to vscode user's bashrc
RUN echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc && \
    chown vscode:vscode /home/vscode/.bashrc

# Add starship prompt initialization to bashrc
RUN echo 'eval "$(starship init bash)"' >> /home/vscode/.bashrc && \
    chown vscode:vscode /home/vscode/.bashrc

USER vscode
WORKDIR /workspaces
