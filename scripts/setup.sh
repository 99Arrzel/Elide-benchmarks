#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/bench-utils.sh"

log_info "=== Runtime Benchmark Suite Setup ==="

# System deps
log_info "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libssl-dev git curl wget zip unzip \
    postgresql-client lsof bc python3-full python3-venv

# wrk2
if ! command -v wrk2 &> /dev/null; then
    log_info "Installing wrk2..."
    cd /tmp
    git clone https://github.com/giltene/wrk2.git
    cd wrk2
    make -j$(nproc)
    sudo cp wrk /usr/local/bin/wrk2
    cd -
    log_ok "wrk2 installed"
else
    log_ok "wrk2 already installed"
fi

# Node.js (via nvm)
if ! command -v node &> /dev/null; then
    log_info "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
log_ok "Node.js: $(node --version)"

# tsx (for running TS with Node)
if ! command -v tsx &> /dev/null; then
    npm install -g tsx
fi

# Bun
if ! command -v bun &> /dev/null; then
    log_info "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
fi
log_ok "Bun: $(bun --version)"

# Deno
if ! command -v deno &> /dev/null; then
    log_info "Installing Deno..."
    curl -fsSL https://deno.land/install.sh | sh
fi
log_ok "Deno: $(deno --version | head -1)"

# Elide
if ! command -v elide &> /dev/null; then
    log_info "Installing Elide..."
    curl -sSL https://elide.sh | bash
fi
log_ok "Elide: $(elide --version 2>/dev/null || echo 'installed (version check may vary)')"

# Docker
if ! command -v docker &> /dev/null; then
    log_warn "Docker is not installed. Please install Docker manually."
    log_warn "See: https://docs.docker.com/engine/install/ubuntu/"
else
    log_ok "Docker: $(docker --version)"
fi

# Kotlin (SDKMAN init uses unbound vars, so relax -u temporarily)
# Ensure SDKMAN uses system java, not Elide's bundled one
if ! command -v kotlin &> /dev/null; then
    log_info "Installing Kotlin..."
    # Ensure a real JDK is installed (Elide bundles a broken java shim)
    sudo apt-get install -y -qq default-jdk
    # Make sure system java comes before Elide's shim on PATH
    export JAVA_HOME="/usr/lib/jvm/default-java"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    curl -s https://get.sdkman.io | bash
    set +u
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    sdk install kotlin
    set -u
fi
log_ok "Kotlin: $(kotlin -version 2>&1 | head -1)"

# Python deps (use a venv to avoid externally-managed-environment errors)
VENV_DIR="${PROJECT_ROOT}/.venv"
log_info "Setting up Python virtual environment..."
if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/pip" install psycopg2-binary uvicorn -q
log_ok "Python deps installed in ${VENV_DIR}"

# Install benchmark JS deps
log_info "Installing JS dependencies..."
(cd "${PROJECT_ROOT}/benchmarks/02-db-crud/node" && npm install --silent)
(cd "${PROJECT_ROOT}/benchmarks/02-db-crud/bun" && bun install --silent)

log_info ""
log_info "=== Version Summary ==="
runtime_versions_json
log_ok "Setup complete!"
