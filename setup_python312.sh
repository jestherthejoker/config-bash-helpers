#!/usr/bin/env bash
# ==============================================================================
# setup_python312.sh — Python 3.12 Installation & Configuration for Ubuntu
# ==============================================================================
#
# Fully installs, configures, and verifies Python 3.12 on Ubuntu 20.04/22.04.
# On 22.04 (Jammy): installs via deadsnakes PPA packages.
# On 20.04 (Focal): tries deadsnakes PPA, falls back to building from source.
# Designed for fresh machines — handles everything from system prerequisites,
# deadsnakes PPA, package installation, pip bootstrap, symlink/alternatives
# setup, and comprehensive verification.
#
# Usage:
#   sudo bash setup_python312.sh [OPTIONS]
#
# Options:
#   --set-default    Set python3.12 as the system default 'python3'
#   --dry-run        Preview all actions without making changes
#   --skip-verify    Skip the verification phase
#   --help           Show this help message
#
# Idempotent: safe to run multiple times on the same machine.
#
# ==============================================================================

set -Euo pipefail

# === Constants ================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly PYTHON_VERSION="3.12"
readonly PYTHON_BIN="python${PYTHON_VERSION}"
readonly LOG_FILE="/tmp/setup_python312_$(date +%Y%m%d_%H%M%S).log"
readonly PYTHON_SRC_VERSION="3.12.10"

# Detected at runtime in preflight()
UBUNTU_VERSION_ID=""
UBUNTU_CODENAME=""

# Packages needed before we can add the PPA
readonly PREREQ_PACKAGES=(
    software-properties-common
    curl
    gnupg
    ca-certificates
)

# Python 3.12 packages from deadsnakes
readonly PYTHON_PACKAGES=(
    "python${PYTHON_VERSION}"
    "python${PYTHON_VERSION}-venv"
    "python${PYTHON_VERSION}-dev"
    "python${PYTHON_VERSION}-distutils"
    "python${PYTHON_VERSION}-tk"
    "python${PYTHON_VERSION}-gdbm"
    "libpython${PYTHON_VERSION}-dev"
)

# Build dependencies for compiling C extensions (numpy, pillow, etc.)
readonly BUILD_PACKAGES=(
    build-essential
    libssl-dev
    libffi-dev
    zlib1g-dev
    libbz2-dev
    libreadline-dev
    libsqlite3-dev
    liblzma-dev
    libncurses5-dev
    libncursesw5-dev
    libgdbm-dev
    libexpat1-dev
)

# Modules to verify after installation
readonly VERIFY_MODULES=(
    ssl ctypes sqlite3 lzma bz2 curses readline
    _decimal xml.parsers.expat venv ensurepip
)

readonly OPTIONAL_MODULES=(
    distutils tkinter
)

# === Color Output =============================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

# === Logging ==================================================================

log()     { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}[  OK]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
fail()    { echo -e "${RED}[FAIL]${RESET}  $*" | tee -a "$LOG_FILE"; }
step()    { echo -e "\n${BOLD}${BLUE}── $* ──${RESET}" | tee -a "$LOG_FILE"; }
detail()  { echo -e "         ${DIM}$*${RESET}" | tee -a "$LOG_FILE"; }
die()     { fail "$*"; echo ""; fail "See full log: ${LOG_FILE}"; exit 1; }

# === Cleanup Trap =============================================================

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        fail "Script exited with code ${exit_code}."
        fail "Review the log for details: ${LOG_FILE}"
    fi
}
trap cleanup EXIT

# === Flags ====================================================================

SET_DEFAULT=false
DRY_RUN=false
SKIP_VERIFY=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set-default)  SET_DEFAULT=true ;;
            --dry-run)      DRY_RUN=true ;;
            --skip-verify)  SKIP_VERIFY=true ;;
            --help|-h)      usage; exit 0 ;;
            *)              die "Unknown option: $1. Use --help for usage." ;;
        esac
        shift
    done
}

usage() {
    sed -n '2,/^# =====/{ /^# =====/d; s/^# \{0,1\}//; p }' "$0"
}

# === Helpers ==================================================================

# Run apt-get install, suppressing stdout but showing errors on failure
apt_install() {
    if $DRY_RUN; then
        log "[DRY RUN] Would install: $*"
        return 0
    fi
    if ! apt-get install -y "$@" >>"$LOG_FILE" 2>&1; then
        fail "apt-get install failed for: $*"
        detail "Check ${LOG_FILE} for apt output."
        return 1
    fi
    return 0
}

# Check if a package is installed
pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

# Collect packages that are not yet installed
missing_packages() {
    local -n _result=$1
    shift
    _result=()
    for pkg in "$@"; do
        if ! pkg_installed "$pkg"; then
            _result+=("$pkg")
        fi
    done
}

# ==============================================================================
# PHASE 1: Preflight — verify we can run at all
# ==============================================================================

preflight() {
    step "Phase 1: Preflight Checks"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo bash $SCRIPT_NAME"
    fi
    ok "Running as root"

    # Verify Ubuntu version
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        UBUNTU_VERSION_ID="${VERSION_ID:-}"
        UBUNTU_CODENAME="${VERSION_CODENAME:-}"

        case "$UBUNTU_VERSION_ID" in
            22.04)
                ok "OS: ${PRETTY_NAME}"
                ;;
            20.04)
                ok "OS: ${PRETTY_NAME}"
                log "Ubuntu 20.04 — will build from source if PPA packages fail."
                ;;
            *)
                if [[ "${ID:-}" == "ubuntu" ]]; then
                    warn "Detected ${PRETTY_NAME:-Ubuntu unknown}. Script targets 20.04/22.04."
                    warn "Proceeding — some packages may differ."
                    UBUNTU_VERSION_ID="${VERSION_ID:-unknown}"
                else
                    die "Unsupported OS: ${PRETTY_NAME:-unknown}. This script requires Ubuntu."
                fi
                ;;
        esac
    else
        die "/etc/os-release not found — cannot verify distribution."
    fi

    # Architecture
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
    ok "Architecture: ${arch}"

    # Check internet — try multiple methods since curl may not exist on a bare system
    local connected=false
    if command -v curl &>/dev/null; then
        curl -sf --connect-timeout 5 https://ppa.launchpadcontent.net >/dev/null 2>&1 && connected=true
    fi
    if ! $connected && command -v wget &>/dev/null; then
        wget -q --spider --timeout=5 https://ppa.launchpadcontent.net 2>/dev/null && connected=true
    fi
    if ! $connected; then
        # Last resort: use bash built-in /dev/tcp (test apt endpoint)
        if (echo >/dev/tcp/archive.ubuntu.com/80) 2>/dev/null; then
            connected=true
        fi
    fi
    if ! $connected; then
        die "No internet connectivity. Cannot reach package repositories."
    fi
    ok "Internet: reachable"
}

# ==============================================================================
# PHASE 2: System prerequisites — install tools needed for PPA and builds
# ==============================================================================

install_prerequisites() {
    step "Phase 2: System Prerequisites"

    # Always refresh the package index first
    log "Updating apt package index..."
    if ! $DRY_RUN; then
        apt-get update -qq >>"$LOG_FILE" 2>&1
        ok "Package index updated"
    else
        log "[DRY RUN] Would run: apt-get update"
    fi

    # Install prerequisite packages
    local missing=()
    missing_packages missing "${PREREQ_PACKAGES[@]}"

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All prerequisites already installed"
    else
        log "Installing prerequisites: ${missing[*]}"
        apt_install "${missing[@]}" || die "Failed to install prerequisites."
        ok "Prerequisites installed: ${missing[*]}"
    fi

    # Install build dependencies for C extension compilation
    local build_missing=()
    missing_packages build_missing "${BUILD_PACKAGES[@]}"

    if [[ ${#build_missing[@]} -eq 0 ]]; then
        ok "Build dependencies already installed"
    else
        log "Installing build dependencies: ${build_missing[*]}"
        if ! apt_install "${build_missing[@]}"; then
            warn "Some build deps failed — C extensions may not compile."
            # Try individually for partial success
            if ! $DRY_RUN; then
                for pkg in "${build_missing[@]}"; do
                    apt_install "$pkg" 2>/dev/null && ok "  ${pkg}" || warn "  ${pkg} — skipped"
                done
            fi
        else
            ok "Build dependencies installed"
        fi
    fi
}

# ==============================================================================
# PHASE 3: Deadsnakes PPA — add the repository that provides Python 3.12
# ==============================================================================

setup_ppa() {
    step "Phase 3: Deadsnakes PPA"

    if grep -rqs "deadsnakes" /etc/apt/sources.list.d/ 2>/dev/null; then
        ok "Deadsnakes PPA already configured"
    else
        log "Adding deadsnakes/ppa..."
        if $DRY_RUN; then
            log "[DRY RUN] Would run: add-apt-repository -y ppa:deadsnakes/ppa"
        else
            if ! add-apt-repository -y ppa:deadsnakes/ppa >>"$LOG_FILE" 2>&1; then
                die "Failed to add deadsnakes PPA. Check network and apt keys."
            fi
            ok "Deadsnakes PPA added"
        fi
    fi

    # Refresh index after adding PPA
    log "Refreshing package index..."
    if ! $DRY_RUN; then
        apt-get update -qq >>"$LOG_FILE" 2>&1
        ok "Package index refreshed"
    fi

    # Verify the PPA actually has python3.12
    if ! $DRY_RUN; then
        if ! apt-cache show "python${PYTHON_VERSION}" &>/dev/null; then
            die "python${PYTHON_VERSION} not found in repositories. PPA may have failed."
        fi
        local candidate
        candidate="$(apt-cache policy "python${PYTHON_VERSION}" 2>/dev/null | grep 'Candidate:' | awk '{print $2}')"
        ok "Available: python${PYTHON_VERSION} (${candidate:-unknown})"
    fi
}

# ==============================================================================
# PHASE 4 (source fallback): Build Python 3.12 from source for Ubuntu 20.04
# ==============================================================================

build_from_source() {
    step "Phase 4b: Building Python ${PYTHON_VERSION} from source"

    log "PPA packages unavailable — building Python ${PYTHON_SRC_VERSION} from source."
    log "This will take 5-15 minutes depending on your machine."

    # Remove any broken PPA package before source build
    apt-get remove -y "python${PYTHON_VERSION}" >>"$LOG_FILE" 2>&1 || true

    local build_dir
    build_dir="$(mktemp -d /tmp/python-build.XXXXXX)"
    local src_url="https://www.python.org/ftp/python/${PYTHON_SRC_VERSION}/Python-${PYTHON_SRC_VERSION}.tgz"

    log "Downloading Python ${PYTHON_SRC_VERSION}..."
    if ! curl -sSL --retry 3 "$src_url" -o "${build_dir}/Python-${PYTHON_SRC_VERSION}.tgz" 2>>"$LOG_FILE"; then
        rm -rf "$build_dir"
        die "Failed to download Python source from ${src_url}"
    fi
    ok "Source downloaded"

    log "Extracting..."
    if ! tar -xzf "${build_dir}/Python-${PYTHON_SRC_VERSION}.tgz" -C "$build_dir" >>"$LOG_FILE" 2>&1; then
        rm -rf "$build_dir"
        die "Failed to extract source archive"
    fi

    log "Configuring..."
    if ! (cd "${build_dir}/Python-${PYTHON_SRC_VERSION}" && \
          ./configure \
              --enable-optimizations \
              --with-ensurepip=install \
              --enable-shared \
              --prefix=/usr/local \
              LDFLAGS="-Wl,-rpath,/usr/local/lib" \
              >>"$LOG_FILE" 2>&1); then
        rm -rf "$build_dir"
        die "Configure failed. Check build dependencies in ${LOG_FILE}"
    fi
    ok "Configure complete"

    local nproc
    nproc="$(nproc 2>/dev/null || echo 2)"
    log "Building with ${nproc} cores..."
    if ! make -C "${build_dir}/Python-${PYTHON_SRC_VERSION}" -j"$nproc" >>"$LOG_FILE" 2>&1; then
        rm -rf "$build_dir"
        die "Build failed. Check ${LOG_FILE}"
    fi
    ok "Build complete"

    log "Installing to /usr/local (altinstall)..."
    if ! make -C "${build_dir}/Python-${PYTHON_SRC_VERSION}" altinstall >>"$LOG_FILE" 2>&1; then
        rm -rf "$build_dir"
        die "altinstall failed. Check ${LOG_FILE}"
    fi
    ok "Installed: /usr/local/bin/${PYTHON_BIN}"

    ldconfig 2>/dev/null || true

    if [[ ! -x "/usr/bin/${PYTHON_BIN}" ]] && [[ -x "/usr/local/bin/${PYTHON_BIN}" ]]; then
        ln -sf "/usr/local/bin/${PYTHON_BIN}" "/usr/bin/${PYTHON_BIN}"
        ok "Symlinked → /usr/bin/${PYTHON_BIN}"
    fi

    rm -rf "$build_dir"
    ok "Build artifacts cleaned up"
}

# ==============================================================================
# PHASE 4: Install Python 3.12 and all companion packages
# ==============================================================================

install_python() {
    step "Phase 4: Installing Python ${PYTHON_VERSION}"

    # On 20.04, trim packages that don't exist in the deadsnakes PPA for focal
    local packages=("${PYTHON_PACKAGES[@]}")
    if [[ "$UBUNTU_VERSION_ID" == "20.04" ]]; then
        packages=(
            "python${PYTHON_VERSION}"
            "python${PYTHON_VERSION}-venv"
            "python${PYTHON_VERSION}-dev"
            "libpython${PYTHON_VERSION}-dev"
        )
    fi

    local missing=()
    missing_packages missing "${packages[@]}"

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All Python ${PYTHON_VERSION} packages already installed"
    else
        log "Packages to install: ${missing[*]}"
        if $DRY_RUN; then
            log "[DRY RUN] Would install: ${missing[*]}"
        else
            # Try batch install first
            if apt_install "${missing[@]}"; then
                ok "Installed all packages"
            else
                # Fallback: install one by one (some may not exist in older PPA builds)
                warn "Batch install failed. Installing packages individually..."
                local critical_fail=false
                for pkg in "${missing[@]}"; do
                    if apt_install "$pkg"; then
                        ok "  ${pkg}"
                    else
                        # python3.12 itself is critical; others are recoverable
                        if [[ "$pkg" == "python${PYTHON_VERSION}" ]]; then
                            critical_fail=true
                            fail "  ${pkg} — CRITICAL"
                        else
                            warn "  ${pkg} — skipped (non-critical)"
                        fi
                    fi
                done
                if $critical_fail; then
                    if [[ "$UBUNTU_VERSION_ID" == "20.04" ]]; then
                        warn "PPA install failed on 20.04 — will try source build."
                    else
                        die "Failed to install python${PYTHON_VERSION}. Cannot continue."
                    fi
                fi
            fi
        fi
    fi

    # Verify the binary exists — fall back to source build on 20.04
    if ! $DRY_RUN; then
        if ! command -v "$PYTHON_BIN" &>/dev/null && \
           [[ ! -x "/usr/bin/${PYTHON_BIN}" ]] && \
           [[ ! -x "/usr/local/bin/${PYTHON_BIN}" ]]; then
            if [[ "$UBUNTU_VERSION_ID" == "20.04" ]]; then
                warn "${PYTHON_BIN} not found from PPA packages."
                build_from_source
            else
                die "${PYTHON_BIN} binary not found after installation. Something went wrong."
            fi
        fi

        if command -v "$PYTHON_BIN" &>/dev/null; then
            : # found in PATH
        elif [[ -x "/usr/bin/${PYTHON_BIN}" ]]; then
            ok "Binary found at /usr/bin/${PYTHON_BIN} (not in PATH — will fix)"
        elif [[ -x "/usr/local/bin/${PYTHON_BIN}" ]]; then
            ok "Binary found at /usr/local/bin/${PYTHON_BIN} (source build)"
        else
            die "${PYTHON_BIN} binary not found after all installation attempts."
        fi

        local installed_ver
        installed_ver="$("$PYTHON_BIN" --version 2>&1)"
        ok "Installed: ${installed_ver} at $(command -v "$PYTHON_BIN" || echo "/usr/local/bin/${PYTHON_BIN}")"
    fi
}

# ==============================================================================
# PHASE 5: Fix pip — bootstrap, install, and upgrade pip + setuptools
# ==============================================================================

fix_pip() {
    step "Phase 5: Configuring pip"

    if $DRY_RUN; then
        log "[DRY RUN] Would bootstrap pip via ensurepip and upgrade."
        return 0
    fi

    local pip_works=false

    # Test if pip already works
    if "$PYTHON_BIN" -m pip --version &>/dev/null; then
        pip_works=true
        ok "pip already functional"
    fi

    # Strategy 1: Bootstrap via ensurepip
    if ! $pip_works; then
        log "Bootstrapping pip via ensurepip..."
        if "$PYTHON_BIN" -m ensurepip --default-pip >>"$LOG_FILE" 2>&1; then
            if "$PYTHON_BIN" -m pip --version &>/dev/null; then
                pip_works=true
                ok "pip bootstrapped via ensurepip"
            fi
        else
            warn "ensurepip failed (may be missing or broken)"
        fi
    fi

    # Strategy 2: Download get-pip.py
    if ! $pip_works; then
        log "Downloading get-pip.py as fallback..."
        local tmp_pip
        tmp_pip="$(mktemp /tmp/get-pip.XXXXXX.py)"

        local downloaded=false
        if curl -sSL --retry 3 https://bootstrap.pypa.io/get-pip.py -o "$tmp_pip" 2>>"$LOG_FILE"; then
            downloaded=true
        elif wget -q https://bootstrap.pypa.io/get-pip.py -O "$tmp_pip" 2>>"$LOG_FILE"; then
            downloaded=true
        fi

        if $downloaded && [[ -s "$tmp_pip" ]]; then
            if "$PYTHON_BIN" "$tmp_pip" >>"$LOG_FILE" 2>&1; then
                pip_works=true
                ok "pip installed via get-pip.py"
            else
                fail "get-pip.py execution failed"
            fi
        else
            fail "Could not download get-pip.py"
        fi
        rm -f "$tmp_pip"
    fi

    # Strategy 3: Install python3-pip system package and symlink
    if ! $pip_works; then
        log "Attempting system python3-pip package..."
        if apt_install python3-pip; then
            if "$PYTHON_BIN" -m pip --version &>/dev/null; then
                pip_works=true
                ok "pip available via python3-pip package"
            fi
        fi
    fi

    if ! $pip_works; then
        die "All pip installation methods failed. Check ${LOG_FILE} for details."
    fi

    # Upgrade pip to latest
    log "Upgrading pip..."
    "$PYTHON_BIN" -m pip install --upgrade pip >>"$LOG_FILE" 2>&1 || warn "pip upgrade failed (non-critical)"
    ok "pip: $("$PYTHON_BIN" -m pip --version 2>&1)"

    # Install essential packaging tools
    log "Installing setuptools and wheel..."
    "$PYTHON_BIN" -m pip install --upgrade setuptools wheel >>"$LOG_FILE" 2>&1 || warn "setuptools/wheel upgrade failed"
    ok "setuptools + wheel: installed"
}

# ==============================================================================
# PHASE 6: update-alternatives — register python versions
# ==============================================================================

configure_alternatives() {
    step "Phase 6: update-alternatives"

    if $DRY_RUN; then
        log "[DRY RUN] Would register system python and python${PYTHON_VERSION}"
        if $SET_DEFAULT; then
            log "[DRY RUN] Would set python${PYTHON_VERSION} as default python3"
        fi
        return 0
    fi

    # Detect existing system python (3.8 on Focal, 3.10 on Jammy)
    local system_python=""
    for candidate in /usr/bin/python3.10 /usr/bin/python3.11 /usr/bin/python3.8; do
        if [[ -x "$candidate" ]]; then
            system_python="$candidate"
            break
        fi
    done

    # Register system python with lower priority
    if [[ -n "$system_python" ]]; then
        update-alternatives --install /usr/bin/python3 python3 "$system_python" 10 >>"$LOG_FILE" 2>&1 || true
        ok "Registered: $(basename "$system_python") (priority 10)"
    fi

    # Register python3.12 — priority depends on --set-default flag
    # Source builds install to /usr/local/bin; PPA installs to /usr/bin
    local py312_path="/usr/bin/${PYTHON_BIN}"
    [[ ! -x "$py312_path" ]] && [[ -x "/usr/local/bin/${PYTHON_BIN}" ]] && py312_path="/usr/local/bin/${PYTHON_BIN}"
    if [[ -x "$py312_path" ]]; then
        local priority=5
        if $SET_DEFAULT; then
            priority=20
        fi
        update-alternatives --install /usr/bin/python3 python3 "$py312_path" "$priority" >>"$LOG_FILE" 2>&1 || true
        ok "Registered: ${PYTHON_BIN} (priority ${priority}) [${py312_path}]"
    fi

    if $SET_DEFAULT; then
        update-alternatives --set python3 "$py312_path" >>"$LOG_FILE" 2>&1 || true
        ok "Default python3 → ${PYTHON_BIN}"
        echo ""
        warn "System python3 now points to ${PYTHON_VERSION}."
        warn "Some system tools (apt, lsb_release) may need python3.10."
        warn "To revert:  sudo update-alternatives --set python3 ${system_python:-/usr/bin/python3.10}"

        # Fix apt/lsb_release if we changed the default
        # These tools hardcode #!/usr/bin/python3 and need the system python
        for tool in /usr/bin/lsb_release /usr/bin/add-apt-repository; do
            if [[ -f "$tool" ]] && head -1 "$tool" | grep -q 'python3$'; then
                if [[ -n "$system_python" ]]; then
                    sed -i "1s|.*|#!${system_python}|" "$tool" >>"$LOG_FILE" 2>&1 || true
                    detail "Pinned ${tool} shebang → ${system_python}"
                fi
            fi
        done
    else
        ok "Default python3 unchanged (system python keeps priority)"
        log "To switch later: sudo update-alternatives --config python3"
    fi
}

# ==============================================================================
# PHASE 7: Verification — prove everything works
# ==============================================================================

verify() {
    step "Phase 7: Verification"

    if $DRY_RUN; then
        log "[DRY RUN] Skipping verification."
        return 0
    fi

    local pass=0 total=0 failures=0

    # --- Binary check ---
    if ! command -v "$PYTHON_BIN" &>/dev/null; then
        fail "${PYTHON_BIN} binary not found!"
        return 1
    fi
    ok "Binary: $("$PYTHON_BIN" --version 2>&1) at $(command -v "$PYTHON_BIN")"

    # --- Core module imports ---
    for mod in "${VERIFY_MODULES[@]}"; do
        ((total++))
        if "$PYTHON_BIN" -c "import ${mod}" &>/dev/null; then
            ok "Module: ${mod}"
            ((pass++))
        else
            fail "Module: ${mod} — import failed"
            ((failures++))
        fi
    done

    # --- Optional modules (warn only) ---
    for mod in "${OPTIONAL_MODULES[@]}"; do
        if "$PYTHON_BIN" -c "import ${mod}" &>/dev/null; then
            ok "Module: ${mod} (optional)"
        else
            warn "Module: ${mod} — not available (optional)"
        fi
    done

    # --- pip functional test ---
    ((total++))
    if "$PYTHON_BIN" -m pip --version &>/dev/null; then
        ok "pip: $("$PYTHON_BIN" -m pip --version 2>&1)"
        ((pass++))
    else
        fail "pip: not functional"
        ((failures++))
    fi

    # --- venv creation test ---
    ((total++))
    local test_venv
    test_venv="$(mktemp -d /tmp/py312_venv_test.XXXXXX)"
    if "$PYTHON_BIN" -m venv "$test_venv" &>/dev/null; then
        # Verify the venv is usable
        if [[ -x "${test_venv}/bin/python" ]] && \
           "${test_venv}/bin/python" -c "import sys; assert sys.version_info[:2] == (3,12)" &>/dev/null; then
            ok "venv: create + activate works"
            ((pass++))
        else
            fail "venv: created but python inside is broken"
            ((failures++))
        fi
    else
        fail "venv: creation failed"
        ((failures++))
    fi
    rm -rf "$test_venv"

    # --- pip install test (install a lightweight package into a temp venv) ---
    ((total++))
    local test_venv2
    test_venv2="$(mktemp -d /tmp/py312_pip_test.XXXXXX)"
    if "$PYTHON_BIN" -m venv "$test_venv2" &>/dev/null && \
       "${test_venv2}/bin/pip" install --quiet six &>/dev/null && \
       "${test_venv2}/bin/python" -c "import six" &>/dev/null; then
        ok "pip install: works inside venv"
        ((pass++))
    else
        fail "pip install: failed inside venv"
        ((failures++))
    fi
    rm -rf "$test_venv2"

    # --- SSL/TLS connectivity test ---
    ((total++))
    if "$PYTHON_BIN" -c "
import urllib.request
urllib.request.urlopen('https://pypi.org', timeout=10)
" &>/dev/null; then
        ok "SSL/TLS: can reach pypi.org"
        ((pass++))
    else
        warn "SSL/TLS: cannot reach pypi.org (may be network issue)"
        ((failures++))
    fi

    # --- Summary ---
    echo ""
    echo -e "  ${BOLD}Results: ${pass}/${total} checks passed${RESET}"
    echo ""

    if [[ $failures -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}  ╔═══════════════════════════════════════════════════╗${RESET}"
        echo -e "${GREEN}${BOLD}  ║  Python ${PYTHON_VERSION} is fully installed and working!   ║${RESET}"
        echo -e "${GREEN}${BOLD}  ╚═══════════════════════════════════════════════════╝${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  ╔═══════════════════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}${BOLD}  ║  Python ${PYTHON_VERSION} installed with ${failures} warning(s).       ║${RESET}"
        echo -e "${YELLOW}${BOLD}  ║  Review log: ${LOG_FILE}  ║${RESET}"
        echo -e "${YELLOW}${BOLD}  ╚═══════════════════════════════════════════════════╝${RESET}"
    fi

    echo ""
    echo -e "  ${CYAN}Quick Reference:${RESET}"
    echo "    ${PYTHON_BIN} --version            # Check version"
    echo "    ${PYTHON_BIN} -m pip install PKG    # Install a package"
    echo "    ${PYTHON_BIN} -m venv ./myenv       # Create virtual environment"
    echo "    source ./myenv/bin/activate         # Activate venv"
    echo ""

    return $failures
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║  Python ${PYTHON_VERSION} — Full Setup & Configuration                  ║${RESET}"
    echo -e "${BOLD}║  Target: Ubuntu 20.04 / 22.04 LTS                            ║${RESET}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if $DRY_RUN; then
        warn "DRY RUN — no changes will be made."
        echo ""
    fi

    log "Log file: ${LOG_FILE}"
    log "Started: $(date)"

    preflight              # Phase 1: Can we run?
    install_prerequisites  # Phase 2: System deps (curl, build-essential, etc.)
    setup_ppa              # Phase 3: Add deadsnakes PPA
    install_python         # Phase 4: Install python3.12 + companion packages
    fix_pip                # Phase 5: Bootstrap and configure pip
    configure_alternatives # Phase 6: Register in update-alternatives

    if ! $SKIP_VERIFY; then
        verify             # Phase 7: Prove it all works
    fi

    echo ""
    log "Finished: $(date)"
    log "Full log: ${LOG_FILE}"
}

main "$@"
