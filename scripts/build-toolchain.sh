#!/usr/bin/env bash
# =============================================================================
# build-toolchain.sh -- compile the dependency toolchain (macOS / Linux)
#
# This is the ONLY place Qt is compiled. It runs in the toolchain pipeline,
# not on the commit path, so it is allowed to be slow and to be retried.
#
# It produces a vcpkg binary cache directory containing every dependency for
# every profile this platform builds. That directory is what gets published --
# as a release archive on macOS, or baked into the container image on Linux --
# and what application builds consume via scripts/fetch-toolchain.sh.
#
# WHY THERE ARE NO "WARM" STAGES HERE
# -----------------------------------
# The previous design split this work into five synthetic vcpkg features so a
# failing job could save progress before it died. That existed to survive a
# 10 GB cache quota and a six-hour job limit on the commit path. A dedicated
# pipeline needs none of it: the real feature sets are installed directly, and
# the caller saves the cache whether or not the build succeeded, so a retry
# resumes from whatever completed.
#
# USAGE
#   scripts/build-toolchain.sh --cache-dir DIR [--qt6] [--profiles "APP HPC"]
#
# OPTIONS
#   --cache-dir DIR   Required. vcpkg binary cache to populate.
#   --qt6             Qt6 toolchain [default].
#   --qt5-qwt630      Qt5 + Qwt 6.3.0 toolchain.
#   --profiles LIST   Space-separated profiles [default: platform-dependent].
#   --arch x64|arm64  Target architecture [default: auto-detect].
#   --skip-bootstrap  Do not run the OS bootstrap script (image already has it).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CACHE_DIR=""
QT_VARIANT="qt6"
PROFILES=""
ARCH=""
SKIP_BOOTSTRAP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --cache-dir)      CACHE_DIR="$2"; shift 2 ;;
    --qt6)            QT_VARIANT="qt6"; shift ;;
    --qt5-qwt630)     QT_VARIANT="qt5-qwt630"; shift ;;
    --profiles)       PROFILES="$2"; shift 2 ;;
    --arch)           ARCH="$2"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    --help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -n "$CACHE_DIR" ] || { echo "ERROR: --cache-dir is required" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Platform / arch
# -----------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) PLATFORM="macOS" ;;
  Linux)  PLATFORM="Linux" ;;
  *) echo "ERROR: unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    *)             ARCH="x64" ;;
  esac
fi

# macOS ships only the desktop application; Linux ships desktop and HPC.
if [ -z "$PROFILES" ]; then
  if [ "$PLATFORM" = "Linux" ]; then PROFILES="APP HPC"; else PROFILES="APP"; fi
fi

# Triplet must match admin/cmake/toolchain.cmake exactly, including the host
# triplet rule -- host equals target, so the dependency graph is built once.
if [ "$PLATFORM" = "macOS" ]; then
  [ "$ARCH" = "arm64" ] && TRIPLET="arm64-osx-dynamic" || TRIPLET="x64-osx-dynamic"
else
  [ "$ARCH" = "arm64" ] && TRIPLET="arm64-linux" || TRIPLET="x64-linux-dynamic"
fi
HOST_TRIPLET="$TRIPLET"

echo "=============================================="
echo "UltraScan3 toolchain build"
echo "=============================================="
echo "  platform     : $PLATFORM ($ARCH)"
echo "  qt variant   : $QT_VARIANT"
echo "  profiles     : $PROFILES"
echo "  triplet      : $TRIPLET (host = target)"
echo "  cache dir    : $CACHE_DIR"
echo ""

# -----------------------------------------------------------------------------
# OS-level bootstrap
# -----------------------------------------------------------------------------
if [ "$SKIP_BOOTSTRAP" = false ]; then
  if [ "$PLATFORM" = "macOS" ]; then
    bash "${SCRIPT_DIR}/bootstrap-macos.sh"
  else
    bash "${SCRIPT_DIR}/bootstrap-linux.sh"
  fi
fi

# Rocky/RHEL 8 installs GCC 13 as a software collection; profile.d is not
# sourced in non-login shells, so activate it explicitly for vcpkg's children.
if [ "$PLATFORM" = "Linux" ] && [ -f /opt/rh/gcc-toolset-13/enable ]; then
  # shellcheck disable=SC1091
  source /opt/rh/gcc-toolset-13/enable
  GCC13_BIN=/opt/rh/gcc-toolset-13/root/usr/bin
  export CC="${GCC13_BIN}/gcc" CXX="${GCC13_BIN}/g++" AR="${GCC13_BIN}/ar"
  export NM="${GCC13_BIN}/nm" RANLIB="${GCC13_BIN}/ranlib" STRIP="${GCC13_BIN}/strip"
  echo "GCC toolset 13 active: $($CXX --version | head -1)"
fi

# -----------------------------------------------------------------------------
# vcpkg at the pinned commit
#
# The commit is vcpkg.json's builtin-baseline -- one SHA in the repository, so
# the ports baseline and the checked-out tool cannot drift apart.
# It pins both: bootstrap-vcpkg resolves the tool version from
# scripts/vcpkg-tool-metadata.txt at whatever is checked out. An
# unpinned clone lets a vcpkg release silently change ABI hashes and invalidate
# every cached package with no change in this repository.
# -----------------------------------------------------------------------------
VCPKG_COMMIT="$(python3 -c \
  "import json,sys;print(json.load(open(sys.argv[1]))['builtin-baseline'])" \
  "${SOURCE_DIR}/vcpkg.json")"
US3_VCPKG_ROOT="${US3_VCPKG_ROOT:-${HOME}/vcpkg}"

if [ ! -d "$US3_VCPKG_ROOT/.git" ]; then
  echo "Cloning vcpkg into $US3_VCPKG_ROOT..."
  git clone https://github.com/microsoft/vcpkg.git "$US3_VCPKG_ROOT"
fi

echo "Pinning vcpkg to ${VCPKG_COMMIT}"
git -C "$US3_VCPKG_ROOT" fetch --quiet origin "$VCPKG_COMMIT" 2>/dev/null || git -C "$US3_VCPKG_ROOT" fetch --quiet origin
git -C "$US3_VCPKG_ROOT" checkout --quiet --detach "$VCPKG_COMMIT"

# The bootstrapped tool must match the checkout it was built for.
rm -f "$US3_VCPKG_ROOT/vcpkg"
"$US3_VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
export VCPKG_ROOT="$US3_VCPKG_ROOT"
"$US3_VCPKG_ROOT/vcpkg" version

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"
export VCPKG_BINARY_SOURCES="clear;files,${CACHE_DIR},readwrite"

US3_VCPKG_DOWNLOADS="${US3_VCPKG_DOWNLOADS:-${HOME}/vcpkg-downloads}"
mkdir -p "$US3_VCPKG_DOWNLOADS"
export VCPKG_DOWNLOADS="$US3_VCPKG_DOWNLOADS"

# --clean-after-build is what keeps this within the runner's disk budget: each
# port's buildtree is discarded as soon as its binary is cached.
export VCPKG_INSTALL_OPTIONS="--clean-after-build"
export VCPKG_MAX_CONCURRENCY="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [ "$PLATFORM" = "Linux" ]; then
  export PATH="/usr/bin:/usr/sbin:${PATH}"
fi

OVERLAY_TRIPLETS="${SOURCE_DIR}/admin/cmake/triplets"
OVERLAY_PORTS="${SOURCE_DIR}/buildsys/vcpkg/overlay-ports"

# -----------------------------------------------------------------------------
# Install each profile's real feature set
# -----------------------------------------------------------------------------
for PROFILE in $PROFILES; do
  case "${QT_VARIANT}-${PROFILE}" in
    qt6-APP)        FEATURE="qt6-app" ;;
    qt6-HPC)        FEATURE="qt6-hpc" ;;
    qt5-qwt630-APP) FEATURE="qt5-app" ;;
    qt5-qwt630-HPC) FEATURE="qt5-hpc" ;;
    *) echo "ERROR: no feature for ${QT_VARIANT}/${PROFILE}" >&2; exit 1 ;;
  esac

  echo ""
  echo "=============================================="
  echo "Installing ${FEATURE} (${PROFILE})"
  echo "=============================================="
  df -h "$CACHE_DIR" 2>/dev/null || true

  ARGS=(
    "--triplet=${TRIPLET}"
    "--host-triplet=${HOST_TRIPLET}"
    "--overlay-triplets=${OVERLAY_TRIPLETS}"
    "--x-no-default-features"
    "--x-feature=${FEATURE}"
    # Each profile resolves a different feature set, and manifest mode makes an
    # install tree match the current one exactly. Separate trees keep one
    # profile's install from uninstalling the other's packages; the binaries
    # they share come from the binary cache either way.
    "--x-install-root=${US3_VCPKG_ROOT}/installed-toolchain-${PROFILE}"
  )
  [ -d "$OVERLAY_PORTS" ] && ARGS+=("--overlay-ports=${OVERLAY_PORTS}")

  "$US3_VCPKG_ROOT/vcpkg" install "${ARGS[@]}"
done

echo ""
echo "=============================================="
echo "Toolchain build complete"
echo "=============================================="
du -sh "$CACHE_DIR" 2>/dev/null || true
find "$CACHE_DIR" -name '*.zip' | wc -l | xargs echo "cached packages:"
