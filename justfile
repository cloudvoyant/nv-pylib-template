# justfile - Command runner for project automation
# Requires: just (https://github.com/casey/just)

set shell   := ["bash", "-c"]

# Dependencies
bash        := require("bash")
direnv      := require("direnv")

# Environment variables available for all scripts
export PROJECT                  := `source .envrc && echo $PROJECT`
export VERSION                  := `source .envrc && echo $VERSION`
export GCP_REGISTRY_PROJECT_ID  := `source .envrc && echo $GCP_REGISTRY_PROJECT_ID`
export GCP_REGISTRY_REGION      := `source .envrc && echo $GCP_REGISTRY_REGION`
export GCP_REGISTRY_NAME        := `source .envrc && echo $GCP_REGISTRY_NAME`

# Color codes for output
INFO        := '\033[0;34m'
SUCCESS     := '\033[0;32m'
WARN        := '\033[1;33m'
ERROR       := '\033[0;31m'
NORMAL      := '\033[0m'

# ==============================================================================
# CORE DEVELOPMENT
# ==============================================================================

# Default recipe (show help)
_default:
    @just --list --unsorted

# Install dependencies
[group('dev')]
install:
    uv sync --all-extras

# Build the project
[group('dev')]
build:
    uv build

# Run project locally
[group('dev')]
run:
    uv run python -m nv_pylib_template

# Run tests
[group('dev')]
test:
    uv run pytest test/ --cov=src --cov-report=term-missing:skip-covered --cov-report=html -q

# Clean build artifacts
[group('dev')]
clean:
    @rm -rf .nv
    @rm -rf dist/ build/ *.egg-info/
    @rm -rf .pytest_cache/ .mypy_cache/ .ruff_cache/
    @find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    @echo -e "{{SUCCESS}}Cleaned build artifacts{{NORMAL}}"

# ==============================================================================
# DOCKER
# ==============================================================================

[group('docker')]
docker-build:
    @COMPOSE_BAKE=true docker compose build

[group('docker')]
docker-run:
    @docker compose run --rm runner

[group('docker')]
docker-test:
    @docker compose run --rm tester

# ==============================================================================
# UTILITIES
# ==============================================================================

# Setup development environment
[group('utils')]
setup *ARGS:
    @bash scripts/setup.sh {{ARGS}}

# Format code
[group('utils')]
format *PATHS:
    uv run ruff format src/ test/

# Check code formatting (CI mode)
[group('utils')]
format-check *PATHS:
    uv run ruff format --check src/ test/

# Lint code
[group('utils')]
lint *PATHS:
    uv run ruff check src/ test/

# Lint and auto-fix issues
[group('utils')]
lint-fix *PATHS:
    uv run ruff check --fix src/ test/

# Type check code
[group('utils')]
type-check:
    uv run mypy src/

# Upgrade to newer template version (requires Claude Code)
[group('utils')]
upgrade:
    #!/usr/bin/env bash
    if command -v claude >/dev/null 2>&1; then
        if grep -q "NV_TEMPLATE=" .envrc 2>/dev/null; then
            claude /upgrade;
        else
            echo -e "{{ERROR}}This project is not based on a template{{NORMAL}}";
            echo "";
            echo "To adopt a template, use the nv CLI:";
            echo "  nv scaffold <template>";
            exit 1;
        fi;
    else
        echo -e "{{ERROR}}Claude Code CLI not found{{NORMAL}}";
        echo "Install Claude Code or run: /upgrade";
        exit 1;
    fi

# Authenticate with GCP (local: gcloud login, CI: service account)
[group('utils')]
registry-login *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ " {{ARGS}} " =~ " --ci " ]]; then
        echo -e "{{INFO}}CI mode - authenticating with service account{{NORMAL}}"
        KEY_FILE=$(mktemp)
        echo "$GCP_SA_KEY" > "$KEY_FILE"
        gcloud auth activate-service-account --key-file="$KEY_FILE"
        rm -f "$KEY_FILE"
        gcloud config set project "$GCP_REGISTRY_PROJECT_ID"
    else
        echo -e "{{INFO}}Local mode - interactive GCP login{{NORMAL}}"
        gcloud auth login
        gcloud config set project "$GCP_REGISTRY_PROJECT_ID"
    fi

# ==============================================================================
# CI/CD
# ==============================================================================

# Build for production
[group('ci')]
build-prod:
    @mkdir -p dist
    @echo "$PROJECT $VERSION - Replace with your build artifact" > dist/artifact.txt
    @echo -e "{{SUCCESS}}Production artifact created: dist/artifact.txt{{NORMAL}}"
    # Cross-platform build examples (uncomment and adapt as needed):
    # For Go: GOOS=linux GOARCH=amd64 go build -o dist/$PROJECT-linux-amd64
    # For Rust: cross build --target x86_64-unknown-linux-gnu --release
    # For Zig: zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe

# Get current version
[group('ci')]
version:
    @echo "$VERSION"

# Get next version (from semantic-release)
[group('ci')]
version-next:
    @bash -c 'source scripts/utils.sh && get_next_version'

# Create new version based on commits (semantic-release)
[group('ci')]
upversion *ARGS:
    @bash -c scripts/upversion.sh {{ARGS}}

# Publish the project
[group('ci')]
publish: test build
    #!/usr/bin/env bash
    set -euo pipefail

    # Load environment variables
    if [ -f .envrc ]; then
        source .envrc
    fi

    echo -e "{{INFO}}Publishing package $PROJECT@$VERSION{{NORMAL}}"

    # Publish to PyPI if token is available
    if [ -n "${PYPI_TOKEN:-}" ]; then
        echo -e "{{INFO}}Publishing to PyPI...{{NORMAL}}"
        uv publish --token "$PYPI_TOKEN"
        echo -e "{{SUCCESS}}Published to PyPI{{NORMAL}}"
    else
        echo -e "{{WARN}}PYPI_TOKEN not set, skipping PyPI publish{{NORMAL}}"
    fi

    # Publish to GCP Artifact Registry if credentials are available
    if [ -n "${GCP_REGISTRY_PROJECT_ID:-}" ] && [ -n "${GCP_REGISTRY_REGION:-}" ] && [ -n "${GCP_REGISTRY_NAME:-}" ]; then
        echo -e "{{INFO}}Publishing to GCP Artifact Registry...{{NORMAL}}"

        # GCP Artifact Registry requires twine for Python packages
        if ! command -v twine &> /dev/null; then
            echo -e "{{ERROR}}twine not installed. Install with: uv tool install twine{{NORMAL}}"
            exit 1
        fi

        # Configure twine for GCP Artifact Registry
        export TWINE_REPOSITORY_URL="https://${GCP_REGISTRY_REGION}-python.pkg.dev/${GCP_REGISTRY_PROJECT_ID}/${GCP_REGISTRY_NAME}/"

        # Use service account key in CI, ADC locally
        if [ -n "${GCP_SA_KEY:-}" ]; then
            # CI: Use service account JSON key
            export TWINE_USERNAME=_json_key_base64
            export TWINE_PASSWORD=$(echo "${GCP_SA_KEY}" | base64)
        else
            # Local: Use gcloud ADC token
            export TWINE_USERNAME=oauth2accesstoken
            export TWINE_PASSWORD=$(gcloud auth print-access-token)
        fi

        twine upload dist/*
        echo -e "{{SUCCESS}}Published to GCP Artifact Registry{{NORMAL}}"
    else
        echo -e "{{WARN}}GCP variables not set, skipping GCP publish{{NORMAL}}"
    fi

# ==============================================================================
# VS CODE
# ==============================================================================

# Hide non-essential files in VS Code
[group('vscode')]
hide:
    @bash scripts/toggle-files.sh hide

# Show all files in VS Code
[group('vscode')]
show:
    @bash scripts/toggle-files.sh show

# ==============================================================================
# TEMPLATE
# ==============================================================================

# Scaffold a new project
[group('template')]
scaffold:
    @bash scripts/scaffold.sh

# Run template tests
[group('template')]
test-template:
    #!/usr/bin/env bash
    if command -v bats >/dev/null 2>&1; then
        echo -e "{{INFO}}Running template tests{{NORMAL}}";
        # Use parallel execution if GNU parallel is available
        if command -v parallel >/dev/null 2>&1; then
            find test/ -name "*.bats" -print0 | parallel -0 -j+0 bats {};
        else
            bats test/;
        fi
    else
        echo -e "{{ERROR}}bats not installed. Run: just setup --template{{NORMAL}}";
        exit 1;
    fi
