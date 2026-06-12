#!/bin/bash
# ============================================================
#  Smart Python 3.9 Installer
#  Target: Jetson Nano / Ubuntu 18.04 (aarch64)
#
#  Strategy:
#    1. Pre-flight checks (OS, arch, disk, existing install)
#    2. Try deadsnakes PPA (fast, ~2 min)
#    3. Fall back to build from source (~20-40 min on Nano)
#    4. Install/upgrade pip
#    5. Register with update-alternatives
#    6. Verify install
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  ${BOLD}$1${NC}"; }
log_ok()    { echo -e "${CYAN}[ OK ]${NC}  $1"; }

PYTHON_VERSION="3.9.18"   # Latest stable 3.9.x as of writing
MIN_DISK_MB=2048
INSTALL_METHOD=""

# ── Pre-flight checks ─────────────────────────────────────────

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root. This is allowed but using sudo internally is preferred."
    fi
}

check_os() {
    log_step "Checking OS..."

    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release not found — cannot determine OS."
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" == "ubuntu" && "$VERSION_CODENAME" == "bionic" ]]; then
        log_ok "Ubuntu 18.04 LTS (bionic) — compatible."
    else
        log_warn "Detected: ${PRETTY_NAME:-unknown}"
        log_warn "This script is tuned for Ubuntu 18.04 (bionic) on Jetson Nano."
        read -rp "Continue on unsupported OS? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || { log_info "Aborted."; exit 0; }
    fi
}

check_arch() {
    log_step "Checking CPU architecture..."
    ARCH=$(uname -m)

    case "$ARCH" in
        aarch64)
            log_ok "Architecture: aarch64 — Jetson Nano confirmed."
            ;;
        x86_64)
            log_warn "Architecture: x86_64 — not a Jetson Nano."
            log_warn "This script still works, but it targets Jetson Nano specifically."
            ;;
        *)
            log_warn "Unexpected architecture: $ARCH"
            ;;
    esac
}

check_disk_space() {
    log_step "Checking disk space..."
    AVAILABLE_MB=$(df / --output=avail -BM | tail -1 | tr -d 'M ')

    if [[ "$AVAILABLE_MB" -lt "$MIN_DISK_MB" ]]; then
        log_error "Only ${AVAILABLE_MB}MB free — need at least ${MIN_DISK_MB}MB."
        log_error "Free up space and re-run."
        exit 1
    fi
    log_ok "${AVAILABLE_MB}MB available (minimum required: ${MIN_DISK_MB}MB)."
}

check_internet() {
    log_step "Checking internet connectivity..."
    if ! curl -s --max-time 5 https://pypi.org > /dev/null 2>&1; then
        log_error "No internet access. Cannot continue."
        exit 1
    fi
    log_ok "Internet reachable."
}

check_existing_python39() {
    log_step "Checking for existing Python 3.9 installation..."

    if command -v python3.9 &>/dev/null; then
        EXISTING_VER=$(python3.9 --version 2>&1)
        log_warn "Already installed: $EXISTING_VER"
        read -rp "Reinstall/overwrite? [y/N]: " ans
        if [[ "${ans,,}" != "y" ]]; then
            log_info "Skipping installation. Running verification instead..."
            verify_install
            exit 0
        fi
    else
        log_ok "No existing Python 3.9 found — proceeding."
    fi
}

# ── Installation Method 1: deadsnakes PPA ─────────────────────

method_deadsnakes() {
    log_step "Method 1 — deadsnakes PPA (fast path)..."

    sudo apt-get update -qq
    sudo apt-get install -y software-properties-common curl > /dev/null 2>&1

    if ! sudo add-apt-repository ppa:deadsnakes/ppa -y 2>/dev/null; then
        log_warn "Could not add deadsnakes PPA."
        return 1
    fi

    sudo apt-get update -qq

    if sudo apt-get install -y \
        python3.9 \
        python3.9-dev \
        python3.9-distutils \
        python3.9-venv \
        python3.9-lib2to3; then
        log_ok "Python 3.9 installed via deadsnakes PPA."
        INSTALL_METHOD="deadsnakes-ppa"
        return 0
    else
        log_warn "deadsnakes package install failed."
        return 1
    fi
}

# ── Installation Method 2: Build from source ──────────────────

method_build_from_source() {
    log_step "Method 2 — Building Python ${PYTHON_VERSION} from source..."
    log_warn "This takes 20–40 minutes on Jetson Nano's Cortex-A57 CPU."
    log_warn "Do NOT close this terminal."

    # Install build dependencies
    log_step "Installing build dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y \
        build-essential \
        libssl-dev \
        libffi-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        libncurses5-dev \
        libncursesw5-dev \
        xz-utils \
        tk-dev \
        libxml2-dev \
        libxmlsec1-dev \
        libgdbm-dev \
        liblzma-dev \
        uuid-dev \
        wget \
        curl

    BUILD_DIR=$(mktemp -d /tmp/py39_build_XXXX)
    TARBALL="Python-${PYTHON_VERSION}.tgz"
    SOURCE_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/${TARBALL}"

    log_step "Downloading Python ${PYTHON_VERSION} source..."
    wget -q --show-progress -O "${BUILD_DIR}/${TARBALL}" "$SOURCE_URL"

    log_step "Extracting..."
    tar -xf "${BUILD_DIR}/${TARBALL}" -C "$BUILD_DIR"
    cd "${BUILD_DIR}/Python-${PYTHON_VERSION}"

    log_step "Configuring (--enable-optimizations)..."
    # --enable-optimizations runs PGO which improves runtime ~10%, worth it even on Nano
    ./configure \
        --enable-optimizations \
        --with-ensurepip=install \
        --prefix=/usr/local \
        --enable-loadable-sqlite-extensions \
        2>&1 | tail -5

    CORES=$(nproc)
    log_step "Building with ${CORES} core(s)... (grab a coffee)"
    make -j"$CORES" 2>&1 | grep -E "^(Making|gcc|error:)" | tail -20 || true

    log_step "Installing (altinstall — won't override system python3)..."
    sudo make altinstall

    # Cleanup
    cd /
    rm -rf "$BUILD_DIR"
    log_ok "Python ${PYTHON_VERSION} built and installed from source."
    INSTALL_METHOD="source-build"
    return 0
}

# ── Post-install setup ────────────────────────────────────────

install_pip() {
    log_step "Setting up pip for python3.9..."

    # distutils may not ship pip; bootstrap it
    if ! python3.9 -m pip --version &>/dev/null 2>&1; then
        log_info "pip not found — bootstrapping via get-pip.py..."
        curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        python3.9 /tmp/get-pip.py
        rm -f /tmp/get-pip.py
    fi

    python3.9 -m pip install --upgrade pip --quiet
    log_ok "pip version: $(python3.9 -m pip --version)"
}

setup_alternatives() {
    log_step "Registering python3.9 in update-alternatives..."

    PY39_PATH=$(command -v python3.9 2>/dev/null || echo "/usr/local/bin/python3.9")

    # Priority 39 — lower than system python3 (priority 1) so it won't hijack 'python3'
    sudo update-alternatives --install /usr/local/bin/python3.9 python3.9 "$PY39_PATH" 39 2>/dev/null || true

    log_ok "Registered: $PY39_PATH"
    log_info "To use: python3.9 | To create venv: python3.9 -m venv <name>"
}

# ── Verify ────────────────────────────────────────────────────

verify_install() {
    log_step "Verifying installation..."

    if ! python3.9 --version; then
        log_error "python3.9 not found after install. Something went wrong."
        exit 1
    fi

    python3.9 - <<'EOF'
import sys, ssl, sqlite3, venv
print(f"  Python    : {sys.version}")
print(f"  Executable: {sys.executable}")
print(f"  SSL       : {ssl.OPENSSL_VERSION}")
print(f"  SQLite    : {sqlite3.sqlite_version}")
print(f"  venv      : OK")
EOF

    log_ok "All core modules verified."
}

# ── Summary ───────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Python 3.9 Installation Complete       ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Method used : ${BOLD}${INSTALL_METHOD}${NC}"
    echo -e "  Run         : ${BOLD}python3.9 --version${NC}"
    echo -e "  Create venv : ${BOLD}python3.9 -m venv myenv && source myenv/bin/activate${NC}"
    echo -e "  Install pkg : ${BOLD}python3.9 -m pip install <package>${NC}"
    echo ""
    echo -e "${YELLOW}  NOTE: System python3 ($(python3 --version 2>/dev/null || echo 'unknown')) is unchanged.${NC}"
    echo -e "${YELLOW}  Always invoke 'python3.9' explicitly to use this version.${NC}"
    echo ""
}

# ── Entry point ───────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  Smart Python 3.9 Installer — Jetson Nano        ║${NC}"
    echo -e "${BOLD}║  Ubuntu 18.04 / aarch64                          ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_os
    check_arch
    check_disk_space
    check_internet
    check_existing_python39

    echo ""
    log_step "Starting installation..."
    echo ""

    if method_deadsnakes; then
        : # success
    else
        log_warn "PPA method failed — falling back to source build."
        echo ""
        read -rp "Source build takes 20-40 min on Jetson Nano. Proceed? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || { log_info "Aborted."; exit 0; }
        method_build_from_source
    fi

    install_pip
    setup_alternatives
    verify_install
    print_summary
}

main "$@"
