#!/usr/bin/env bash
# =============================================================================
#  Jetson Nano — WireGuard Full Installation
#  Supports: L4T R32.7.6 / Ubuntu 18.04 / kernel 4.9.x-tegra / T210 (aarch64)
#
#  Run:     sudo bash jetson-wireguard.sh
#  Re-run:  safe — resumes from the last completed step
#
#  Handles every failure encountered during initial deployment:
#    • NVIDIA auth-gated download  (detects HTML, gives manual scp instructions)
#    • Missing kernel headers       (builds from L4T source instead of apt)
#    • DKMS not supported for L4T   (bypasses DKMS, builds directly)
#    • compat.h Tegra backport conflicts  (Python patch disables conflicting blocks)
#    • modules_prepare performance  (parallel -j build, ~5 min instead of ~60)
#    • Module persistence across reboots  (modules-load.d + systemd)
# =============================================================================
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
KERNEL_VERSION="$(uname -r)"
WORK_DIR="$HOME/wg-build"
KERNEL_SRC="$WORK_DIR/Linux_for_Tegra/source/public/kernel/kernel-4.9"
KERNEL_BUILD="/lib/modules/$KERNEL_VERSION/build"
WG_VERSION="1.0.20201112"
WG_SRC="/usr/src/wireguard-$WG_VERSION"
BUILD_LOG="/tmp/wg-build-$(date +%Y%m%d-%H%M%S).log"
L4T_URL="https://developer.nvidia.com/downloads/embedded/l4t/r32_release_v7.6/sources/t210/public_sources.tbz2"
NPROC="$(nproc)"
CURRENT_PHASE="init"

# ── Output helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[✔]${RESET} $*"; }
err()  { echo -e "${RED}[✘]${RESET} $*" >&2; }
info() { echo -e "${CYAN}[→]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
step() { echo -e "\n${BOLD}━━━ $1 ━━━${RESET}"; CURRENT_PHASE="$1"; }
die()  { err "$*"; exit 1; }
hr()   { echo "─────────────────────────────────────────────────────────────"; }

# ── Global error trap ──────────────────────────────────────────────────────────
# Fires on any unhandled non-zero exit. Prints targeted diagnosis per phase.
on_error() {
  local code=$1 line=$2 cmd=$3
  echo ""
  err "Failed in phase '${CURRENT_PHASE}' (line ${line}, exit ${code})"
  err "Command: ${cmd}"
  echo ""
  hr
  case "$CURRENT_PHASE" in
    "pre-flight")
      warn "Verify this is a Jetson Nano running L4T R32.7.x."
      warn "Expected: aarch64, kernel matching 4.9.x-tegra"
      warn "Actual:   $(uname -m)  $(uname -r)"
      ;;
    "dependencies")
      warn "Package install failed. Check:"
      warn "  • Internet: ping -c1 8.8.8.8"
      warn "  • Broken apt: apt-get -f install"
      ;;
    "download")
      warn "NVIDIA requires a developer account for this file."
      echo ""
      echo "  Manual steps:"
      echo "  1. Log in at:  https://developer.nvidia.com"
      echo "  2. Download:   $L4T_URL"
      echo "  3. Copy here:  scp public_sources.tbz2 root@<jetson-ip>:$WORK_DIR/"
      echo "  4. Re-run:     sudo bash $0"
      ;;
    "extract")
      warn "Possible causes:"
      warn "  • Incomplete/corrupt download — delete and re-download:"
      warn "    rm $WORK_DIR/public_sources.tbz2 && sudo bash $0"
      warn "  • Disk full — check: df -h $WORK_DIR"
      ;;
    "config")
      warn "Tried: /proc/config.gz → /boot/config-$KERNEL_VERSION → tegra_defconfig"
      warn "Manual: cd $KERNEL_SRC && zcat /proc/config.gz > .config && make olddefconfig ARCH=arm64"
      ;;
    "modules_prepare")
      warn "Possible causes:"
      warn "  • Missing tools: apt install build-essential bc libssl-dev libelf-dev"
      warn "  • Disk full: df -h $WORK_DIR"
      warn "  • Interrupted: re-run, the script will retry this step"
      ;;
    "patch")
      warn "compat.h patch failed."
      warn "  • Python 3 check: python3 --version"
      warn "  • Expected wireguard-dkms version: $WG_VERSION"
      warn "  • Inspect: $WG_SRC/compat/compat.h"
      ;;
    "build")
      warn "Build log: $BUILD_LOG"
      echo ""
      echo "Distinct errors:"
      hr
      grep "error:" "$BUILD_LOG" 2>/dev/null \
        | sed 's|.*/wireguard[^/]*/||; s|.*/compat/||' \
        | sort -u | head -20 || true
      hr
      echo ""
      if grep -q "redefinition" "$BUILD_LOG" 2>/dev/null; then
        warn "→ redefinition: compat.h patch missed a conflict"
        warn "  Re-run — compat.h is restored from backup each run"
        warn "  Check patches: grep -n 'TEGRA_PATCH' $WG_SRC/compat/compat.h"
      fi
      if grep -q "incomplete type" "$BUILD_LOG" 2>/dev/null; then
        warn "→ incomplete type: a struct used by compat.h is missing from Tegra headers"
        warn "  The block needs to be added to the Python patch in this script"
      fi
      if grep -q "implicit declaration" "$BUILD_LOG" 2>/dev/null; then
        warn "→ implicit declaration: function missing from Tegra kernel"
        warn "  The block calling it needs to be disabled in the Python patch"
      fi
      ;;
    "install-load")
      warn "Module built but failed to load. Kernel messages:"
      echo ""
      dmesg | tail -20
      echo ""
      warn "Likely cause: kernel ABI mismatch"
      warn "  Running kernel:  $(uname -r)"
      warn "  Sources used:    L4T R32.7.6 (kernel-4.9)"
      warn "  Verify these match exactly."
      ;;
  esac
  hr
  echo ""
  exit "$code"
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0 — PRE-FLIGHT
# ══════════════════════════════════════════════════════════════════════════════
step "pre-flight"

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0"

ARCH="$(uname -m)"
[[ "$ARCH" == "aarch64" ]] || \
  die "Wrong architecture: $ARCH. This script is for Jetson Nano (aarch64)."

echo "$KERNEL_VERSION" | grep -q "tegra" || \
  die "Kernel '$KERNEL_VERSION' is not an L4T kernel.
  Expected: 4.9.xxx-tegra   (e.g. 4.9.337-tegra)
  This script targets Jetson Nano with L4T R32.7.x only."

# Free disk space check — need ~3 GB total
AVAIL_GB="$(df -BG "$HOME" | awk 'NR==2 {gsub("G",""); print $4}')"
if [[ "$AVAIL_GB" -lt 3 ]]; then
  warn "Low disk space: ${AVAIL_GB}GB free. Minimum recommended: 3GB."
  warn "Build may fail. Free up space or continue at your own risk."
  read -r -p "Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0
fi

# ── Early exit: already installed ─────────────────────────────────────────────
if lsmod | grep -q "^wireguard"; then
  log "WireGuard already loaded — nothing to do."
  wg --version 2>/dev/null || true
  exit 0
fi

# Try loading a previously built module (handles re-boot case)
if modprobe wireguard 2>/dev/null && lsmod | grep -q "^wireguard"; then
  log "WireGuard loaded from existing install."
  exit 0
fi

log "Pre-flight passed — arch=${ARCH}, kernel=${KERNEL_VERSION}, free=${AVAIL_GB}GB"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — DEPENDENCIES
# ══════════════════════════════════════════════════════════════════════════════
step "dependencies"
info "Installing build dependencies..."

apt-get update -qq

# wireguard-dkms may not exist in default Ubuntu 18.04 repos — add PPA if needed
if ! apt-cache show wireguard-dkms &>/dev/null; then
  warn "wireguard-dkms not in default repos — adding wireguard PPA..."
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:wireguard/wireguard
  apt-get update -qq
fi

apt-get install -y \
  build-essential \
  bc \
  libssl-dev \
  libelf-dev \
  wireguard-dkms \
  wireguard-tools

[[ -d "$WG_SRC" ]] || \
  die "wireguard-dkms installed but source not found at $WG_SRC — unexpected."

log "Dependencies ready — wireguard source: $WG_SRC"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — DOWNLOAD KERNEL SOURCES
# ══════════════════════════════════════════════════════════════════════════════
step "download"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Validate any existing archive — a previous failed download may have left HTML
if [[ -f "public_sources.tbz2" ]]; then
  if ! file public_sources.tbz2 | grep -qiE "bzip2|tar|compressed"; then
    warn "Existing public_sources.tbz2 looks like an HTML redirect page. Deleting."
    rm -f public_sources.tbz2
  else
    log "Kernel source archive already present — skipping download"
  fi
fi

if [[ ! -f "public_sources.tbz2" ]]; then
  info "Downloading L4T R32.7.6 kernel sources (~200MB)..."
  warn "NVIDIA requires a free developer account. If wget returns an HTML page,"
  warn "the download will be detected and you will get manual instructions."

  set +e
  wget -c --show-progress --timeout=30 "$L4T_URL" -O public_sources.tbz2
  WGET_RC=$?
  set -e

  if [[ $WGET_RC -ne 0 ]] || ! file public_sources.tbz2 2>/dev/null | grep -qiE "bzip2|tar|compressed"; then
    rm -f public_sources.tbz2
    err "Download failed — received login redirect, not the archive."
    hr
    echo ""
    echo "  Manual download required:"
    echo ""
    echo "  On your local computer:"
    echo "    1. Open: https://developer.nvidia.com"
    echo "    2. Sign in (free account)"
    echo "    3. Download: $L4T_URL"
    echo ""
    echo "  Then SCP to this Jetson:"
    JETSON_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<jetson-ip>')"
    echo "    scp public_sources.tbz2 root@${JETSON_IP}:$WORK_DIR/"
    echo ""
    echo "  Then re-run — the script resumes from extraction:"
    echo "    sudo bash $0"
    echo ""
    hr
    exit 1
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — EXTRACT
# ══════════════════════════════════════════════════════════════════════════════
step "extract"

if [[ ! -d "Linux_for_Tegra" ]]; then
  info "Extracting L4T archive (1-2 minutes)..."
  tar -xjf public_sources.tbz2
  log "L4T archive extracted"
else
  log "Linux_for_Tegra already extracted — skipping"
fi

if [[ ! -d "Linux_for_Tegra/source/public/kernel/kernel-4.9" ]]; then
  info "Extracting kernel source..."
  cd Linux_for_Tegra/source/public
  tar -xjf kernel_src.tbz2
  cd "$WORK_DIR"
  log "Kernel source extracted"
else
  log "kernel-4.9 source directory already extracted — skipping"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — KERNEL CONFIGURE
# ══════════════════════════════════════════════════════════════════════════════
step "config"
cd "$KERNEL_SRC"

if [[ ! -f ".config" ]]; then
  info "Generating kernel build config..."

  # Preference order: running kernel config > /boot > defconfig fallback
  if zcat /proc/config.gz > .config 2>/dev/null; then
    log "Config from /proc/config.gz (running kernel — most accurate)"
  elif [[ -f "/boot/config-$KERNEL_VERSION" ]]; then
    cp "/boot/config-$KERNEL_VERSION" .config
    log "Config from /boot/config-$KERNEL_VERSION"
  else
    warn "No running kernel config found — using tegra_defconfig fallback"
    warn "Module should still work but may not exactly match the running kernel."
    make tegra_defconfig ARCH=arm64
    log "Config generated from tegra_defconfig"
  fi

  make olddefconfig ARCH=arm64
  log "Kernel config ready"
else
  log "Kernel .config already present — skipping"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — MODULES_PREPARE
# ══════════════════════════════════════════════════════════════════════════════
step "modules_prepare"

if [[ -f "$KERNEL_SRC/scripts/mod/modpost" ]]; then
  log "modules_prepare already completed — skipping"
else
  info "Running modules_prepare with $NPROC threads (3-8 min on Jetson Nano)..."
  info "Do not interrupt — re-running is safe and resumes this step."
  make -j"$NPROC" modules_prepare ARCH=arm64

  [[ -f "$KERNEL_SRC/scripts/mod/modpost" ]] || \
    die "modules_prepare finished but scripts/mod/modpost not found — unexpected failure."

  log "modules_prepare complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — KERNEL SYMLINKS
# ══════════════════════════════════════════════════════════════════════════════
step "symlinks"
ln -sfn "$KERNEL_SRC" "$KERNEL_BUILD"
ln -sfn "$KERNEL_SRC" "/lib/modules/$KERNEL_VERSION/source"

# Out-of-tree module builds require Module.symvers. An empty file is correct
# for custom kernels where the full kernel wasn't built.
if [[ ! -f "$KERNEL_SRC/Module.symvers" ]]; then
  warn "Module.symvers not found — creating empty (expected for custom kernels)"
  touch "$KERNEL_SRC/Module.symvers"
fi

log "Symlinks set: $KERNEL_BUILD → $KERNEL_SRC"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — PATCH COMPAT.H
# ══════════════════════════════════════════════════════════════════════════════
step "patch"
#
# ROOT CAUSE: wireguard-dkms compat.h uses version guards:
#   #if LINUX_VERSION_CODE < KERNEL_VERSION(X, Y, 0)
# to provide backport implementations of newer kernel functions.
#
# Tegra L4T 4.9 falls below those version thresholds, so compat.h activates
# those blocks — but NVIDIA already backported the same functions into L4T 4.9,
# causing conflicts:
#
#   • wait_for_random_bytes  — Tegra has it (non-static), but WITHOUT
#                              struct random_ready_callback infrastructure
#                              that compat.h's implementation requires
#   • get_random_bytes_wait  — Tegra has it (size_t); compat uses int → redefinition
#   • rng_is_initialized     — Tegra has it; compat redefines it
#   • le32_to_cpu_array      — Tegra has it; compat redefines it
#
# FIX: Replace the version guard of each conflicting block with #if 0.
# wireguard then uses the Tegra kernel's own versions directly.
#
# NOTE: CFLAGS_MODULE / EXTRA_CFLAGS do NOT work here because compat.h only
# checks LINUX_VERSION_CODE — not any HAVE_* macros. Direct source patching
# is the only reliable approach.
#
COMPAT_H="$WG_SRC/compat/compat.h"
COMPAT_ORIG="$WG_SRC/compat/compat.h.orig"

# Always restore from the pristine backup before patching (makes re-runs safe)
if [[ ! -f "$COMPAT_ORIG" ]]; then
  cp "$COMPAT_H" "$COMPAT_ORIG"
  info "Saved original compat.h → compat.h.orig"
else
  cp "$COMPAT_ORIG" "$COMPAT_H"
  info "Restored compat.h from backup"
fi

info "Applying Tegra backport compatibility patches..."

python3 - "$COMPAT_H" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

out = []
patched = {}

def disable_surrounding_if(out_lines, look_back=30):
    """
    Walk back through already-written lines to find and replace the nearest
    #if LINUX_VERSION_CODE guard (that hasn't already been patched) with #if 0.
    Returns True if a guard was found and patched.
    """
    for j in range(len(out_lines) - 1, max(len(out_lines) - look_back, -1), -1):
        l = out_lines[j]
        if '#if ' in l and 'LINUX_VERSION_CODE' in l and 'TEGRA_PATCH' not in l:
            original = l.rstrip()
            out_lines[j] = '#if 0 /* TEGRA_PATCH: {} */\n'.format(original[3:].strip())
            return True
    return False

for line in lines:

    # ── Disable: get_random_bytes_wait block ─────────────────────────────────
    # Tegra 4.9: static inline int get_random_bytes_wait(void *buf, size_t nbytes)
    # compat.h:  static inline int get_random_bytes_wait(void *buf, int nbytes)
    # Fixing int→size_t alone still causes redefinition. Must skip the whole block.
    if ('get_random_bytes_wait' in line and 'static' in line and 'inline' in line
            and 'grb_block' not in patched):
        if disable_surrounding_if(out):
            patched['grb_block'] = True

    # ── Disable: rng_is_initialized block ────────────────────────────────────
    # Tegra 4.9 already provides this function. compat.h redefines it.
    if ('rng_is_initialized' in line and 'static' in line and 'inline' in line
            and 'rng_is_init' not in patched):
        if disable_surrounding_if(out):
            patched['rng_is_init'] = True

    # ── Disable: rng_initializer / wait_for_random_bytes block ───────────────
    # Tegra 4.9 provides wait_for_random_bytes() but NOT the callback infra
    # (struct random_ready_callback, add_random_ready_callback, del_random_ready_callback)
    # that compat.h's implementation depends on.
    if 'struct rng_initializer {' in line and 'rng_block' not in patched:
        if disable_surrounding_if(out):
            patched['rng_block'] = True

    # ── Disable: le32_to_cpu_array / cpu_to_le32_array block ─────────────────
    # Tegra 4.9 already provides these. compat.h redefines them.
    if ('le32_to_cpu_array' in line and 'static' in line
            and 'le32_block' not in patched):
        if disable_surrounding_if(out):
            patched['le32_block'] = True

    out.append(line)

with open(path, 'w') as f:
    f.writelines(out)

print('Patches applied: {}'.format(sorted(patched.keys())))

# Verify the two most critical blocks were patched
required = ['rng_block', 'grb_block']
missing  = [k for k in required if k not in patched]
if missing:
    print('ERROR: Critical patches not applied: {}'.format(missing))
    print('compat.h may differ from expected wireguard-dkms version {}'.format('1.0.20201112'))
    sys.exit(1)

# Confirm TEGRA_PATCH markers are present in the written file
with open(path) as f:
    content = f.read()
if 'TEGRA_PATCH' not in content:
    print('ERROR: No TEGRA_PATCH markers found after patching — write may have failed')
    sys.exit(1)

print('Patch verification passed.')
PYEOF

log "compat.h patched"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — BUILD MODULE
# ══════════════════════════════════════════════════════════════════════════════
step "build"
cd "$KERNEL_SRC"
info "Building WireGuard kernel module ($NPROC threads)..."
info "Build log: $BUILD_LOG"

# Build directly — bypasses DKMS (which requires apt kernel headers that don't
# exist for L4T custom kernels and will fail with "kernel package not supported")
if ! make -j"$NPROC" -C "$KERNEL_BUILD" M="$WG_SRC" modules ARCH=arm64 \
     2>&1 | tee "$BUILD_LOG"; then
  echo ""
  err "Build failed. Analyzing errors..."
  echo ""
  echo "Distinct error types:"
  hr
  grep "error:" "$BUILD_LOG" 2>/dev/null \
    | sed 's|.*/wireguard[^/]*/||; s|.*/compat/||' \
    | sort -u | head -20 || true
  hr
  echo ""
  warn "Most common cause: a compat.h conflict wasn't covered by the patch."
  warn "Re-running will restore compat.h from backup and re-apply all patches."
  exit 1
fi

KO_FILE="$(find "$WG_SRC" -name "wireguard.ko" | head -1)"
[[ -n "$KO_FILE" ]] || die "Build appeared to succeed but wireguard.ko not found."

log "Module built: $KO_FILE"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — INSTALL AND LOAD
# ══════════════════════════════════════════════════════════════════════════════
step "install-load"

DEST="/lib/modules/$KERNEL_VERSION/kernel/net/wireguard"
mkdir -p "$DEST"
install -m 644 "$KO_FILE" "$DEST/wireguard.ko"
depmod -a

info "Loading WireGuard module..."
modprobe wireguard

if ! lsmod | grep -q "^wireguard"; then
  err "modprobe ran but wireguard not in lsmod."
  dmesg | tail -20
  exit 1
fi

log "WireGuard module loaded — kernel: $KERNEL_VERSION"

# Persist module load across reboots (independent of wg-quick)
echo "wireguard" > /etc/modules-load.d/wireguard.conf
log "Auto-load on boot configured (/etc/modules-load.d/wireguard.conf)"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 10 — POST-INSTALL
# ══════════════════════════════════════════════════════════════════════════════
step "post-install"

# If a config already exists on this device, start and enable the tunnel now
if [[ -f "/etc/wireguard/wg0.conf" ]]; then
  info "Found /etc/wireguard/wg0.conf — starting VPN tunnel..."
  systemctl enable wg-quick@wg0 2>/dev/null || true
  if wg-quick up wg0 2>/dev/null; then
    log "VPN tunnel wg0 is up"
    echo ""
    wg show
  else
    warn "wg-quick up failed — check your wg0.conf then run: sudo wg-quick up wg0"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  WireGuard successfully installed on Jetson Nano             │"
echo "  │  Kernel: ${KERNEL_VERSION}"
echo "  ├──────────────────────────────────────────────────────────────┤"
echo "  │  To configure the VPN:                                      │"
echo "  │                                                              │"
echo "  │  1. Create a peer in the dashboard → download .conf         │"
echo "  │  2. sudo mkdir -p /etc/wireguard                            │"
echo "  │     sudo nano /etc/wireguard/wg0.conf  ← paste config      │"
echo "  │  3. sudo wg-quick up wg0               ← start tunnel      │"
echo "  │  4. sudo wg show                       ← verify handshake  │"
echo "  │  5. ping -c 3 10.8.0.1                 ← ping VPN server   │"
echo "  │  6. sudo systemctl enable wg-quick@wg0 ← persist on boot   │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
