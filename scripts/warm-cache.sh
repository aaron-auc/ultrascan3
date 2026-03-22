#!/usr/bin/env bash
# =============================================================================
# warm-cache.sh -- Staged vcpkg dependency cache warmer for UltraScan3
#
# PURPOSE
# -------
# Installs vcpkg dependencies in discrete stages so that each completed stage
# is saved to the GitHub Actions binary cache before the next stage begins.
# This avoids the "nothing gets cached if the job runs out of disk" problem
# that occurs when building Qt + all UltraScan3 deps in a single job.
#
# vcpkg manifest mode does not accept individual port names on the command
# line, so stages are implemented using dedicated warm-only features in
# vcpkg.json (prefixed "warm-") that select port subsets via --x-feature.
# These features have no effect on real builds.
#
# STAGES (qt6)
# ------------
#   1  base        No feature. Installs top-level deps: openssl, zlib,
#                  libarchive, eigen3.  Fast (~5 min).
#   2  qtbase      --x-feature=warm-qt6-stage2  qtbase alone (~25-40 min)
#   3  qtmods      --x-feature=warm-qt6-stage3  Qt modules + DB libs (~15 min)
#   4  qwt         --x-feature=warm-qt6-stage4  Qwt + QwtPlot3D (~10 min)
#
# STAGES (qt5-qwt616)
# -------------------
#   1  base        No feature. Same top-level deps as qt6.  Fast (~5 min).
#   2  qt5mods     --x-feature=warm-qt5-stage2  qt5-base + modules + DB (~20 min)
#   3  qwt         --x-feature=warm-qt5-stage3  Qwt + QwtPlot3D (~10 min)
#
# vcpkg restores any port already in the binary cache instantly, so each
# stage only builds what is genuinely new.
#
# USAGE
# -----
#   ./scripts/warm-cache.sh --stage <N> [OPTIONS]
#
# OPTIONS
#   --stage N          Required. Stage number (1-4 for qt6; 1-3 for qt5-qwt616).
#   --qt6              Qt6 + Qwt 6.3.0 [default]
#   --qt5-qwt616       Qt5 + Qwt 6.1.6
#   --arch x64|arm64   Architecture [default: auto-detect]
#   --vcpkg-root PATH  vcpkg installation path
#   --help             Show this message and exit
#
# ENVIRONMENT VARIABLES (same as build.sh)
#   US3_VCPKG_ROOT      Override vcpkg location (default: ~/vcpkg)
#   US3_VCPKG_CACHE     Override binary cache path
#   US3_VCPKG_DOWNLOADS Override downloads cache path
#   US3_SCRATCH_ROOT    Override Linux CI scratch root
# =============================================================================

set -euo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
STAGE=""
QT_VARIANT="qt6"
ARCH=""
US3_VCPKG_ROOT="${US3_VCPKG_ROOT:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --stage)
      STAGE="$2"; shift 2
      ;;
    --qt6)         QT_VARIANT="qt6";        shift ;;
    --qt5-qwt616)  QT_VARIANT="qt5-qwt616"; shift ;;
    --arch)
      ARCH="$2"; shift 2
      if [[ "$ARCH" != "x64" && "$ARCH" != "arm64" ]]; then
        echo "ERROR: --arch must be x64 or arm64" >&2
        exit 1
      fi
      ;;
    --vcpkg-root)
      US3_VCPKG_ROOT="$2"; shift 2
      ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$STAGE" ]; then
  echo "ERROR: --stage <N> is required." >&2
  exit 1
fi

# =============================================================================
# MAP STAGE NUMBER TO FEATURE
# Validated after QT_VARIANT is known.
# =============================================================================
FEATURE=""
MAX_STAGE=0

case "$QT_VARIANT" in
  qt6)
    MAX_STAGE=4
    case "$STAGE" in
      1) FEATURE="" ;;          # base deps only, no feature flag
      2) FEATURE="warm-qt6-stage2" ;;
      3) FEATURE="warm-qt6-stage3" ;;
      4) FEATURE="warm-qt6-stage4" ;;
      *) echo "ERROR: qt6 supports stages 1-4, got: $STAGE" >&2; exit 1 ;;
    esac
    ;;
  qt5-qwt616)
    MAX_STAGE=3
    case "$STAGE" in
      1) FEATURE="" ;;
      2) FEATURE="warm-qt5-stage2" ;;
      3) FEATURE="warm-qt5-stage3" ;;
      *) echo "ERROR: qt5-qwt616 supports stages 1-3, got: $STAGE" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "ERROR: Unknown qt_variant: $QT_VARIANT" >&2
    exit 1
    ;;
esac

# =============================================================================
# PLATFORM / ARCH DETECTION
# =============================================================================
if [[ "$OSTYPE" == "darwin"* ]]; then
  PLATFORM="macOS"
elif [[ "$OSTYPE" == "linux-gnu"* || "$(uname -s)" == "Linux" ]]; then
  PLATFORM="Linux"
else
  echo "ERROR: Unsupported platform: OSTYPE=${OSTYPE:-unset}" >&2
  exit 1
fi

if [ -z "$ARCH" ]; then
  MACHINE=$(uname -m)
  if [ "$MACHINE" = "arm64" ] || [ "$MACHINE" = "aarch64" ]; then
    ARCH="arm64"
  else
    ARCH="x64"
  fi
fi

# =============================================================================
# TRIPLET DERIVATION — must match toolchain.cmake / build.sh
# =============================================================================
if [ "$PLATFORM" = "Linux" ]; then
  [ "$ARCH" = "arm64" ] && TRIPLET="arm64-linux" || TRIPLET="x64-linux-dynamic"
elif [ "$PLATFORM" = "macOS" ]; then
  [ "$ARCH" = "arm64" ] && TRIPLET="arm64-osx-dynamic" || TRIPLET="x64-osx-dynamic"
fi
STATIC_TRIPLET="${TRIPLET%-dynamic}"

echo "=========================================="
echo "UltraScan3 vcpkg Cache Warmer"
echo "=========================================="
echo "  Platform    : $PLATFORM ($ARCH)"
echo "  Qt variant  : $QT_VARIANT"
echo "  Triplet     : $TRIPLET"
echo "  Stage       : $STAGE / $MAX_STAGE"
echo "  Feature     : ${FEATURE:-<none> (base deps only)}"
echo ""

# =============================================================================
# LINUX CI SCRATCH / DISK MANAGEMENT (mirrors build.sh)
# =============================================================================
US3_SCRATCH_ROOT="${US3_SCRATCH_ROOT:-}"

if [ "$PLATFORM" = "Linux" ] && [ "${CI:-false}" = "true" ]; then
  echo "=========================================="
  echo "Linux disk preflight"
  echo "=========================================="
  df -h
  echo "Freeing large preinstalled tool stacks..."
  sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android /opt/hostedtoolcache/CodeQL || true
  echo "Disk after cleanup:"
  df -h

  if [ -z "$US3_SCRATCH_ROOT" ]; then
    if [ -d /mnt ] && [ "$(stat -c '%d' / 2>/dev/null)" != "$(stat -c '%d' /mnt 2>/dev/null)" ]; then
      US3_SCRATCH_ROOT="/mnt/us3"
    else
      US3_SCRATCH_ROOT="$HOME/us3-scratch"
    fi
  fi
  mkdir -p "$US3_SCRATCH_ROOT"/{vcpkg-cache,vcpkg-downloads,build}
  echo "Using Linux scratch root: $US3_SCRATCH_ROOT"
fi

# =============================================================================
# SCRIPT_DIR / SOURCE_DIR
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# =============================================================================
# BOOTSTRAP (OS-level tools only — idempotent)
# =============================================================================
if [ "$PLATFORM" = "macOS" ]; then
  bash "${SCRIPT_DIR}/bootstrap-macos.sh"
elif [ "$PLATFORM" = "Linux" ]; then
  bash "${SCRIPT_DIR}/bootstrap-linux.sh"
fi

# =============================================================================
# VCPKG SETUP (mirrors build.sh)
# =============================================================================
if [ -z "$US3_VCPKG_ROOT" ]; then
  if [ -f "${SOURCE_DIR}/vcpkg/bootstrap-vcpkg.sh" ]; then
    US3_VCPKG_ROOT="${SOURCE_DIR}/vcpkg"
  elif [ "$PLATFORM" = "Linux" ] && [ "${CI:-false}" = "true" ] && [ -n "${US3_SCRATCH_ROOT:-}" ]; then
    US3_VCPKG_ROOT="$US3_SCRATCH_ROOT/vcpkg"
  else
    US3_VCPKG_ROOT="$HOME/vcpkg"
  fi
fi

if [ ! -d "$US3_VCPKG_ROOT/.git" ]; then
  echo "Cloning vcpkg..."
  git clone https://github.com/microsoft/vcpkg.git "$US3_VCPKG_ROOT"
fi

if [ ! -x "$US3_VCPKG_ROOT/vcpkg" ]; then
  echo "Bootstrapping vcpkg..."
  "$US3_VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi

export VCPKG_ROOT="$US3_VCPKG_ROOT"
export VCPKG_INSTALLED_DIR="$US3_VCPKG_ROOT/installed"

# Binary cache
if [ -n "${US3_VCPKG_CACHE:-}" ]; then
  : # set via env
elif [ "$PLATFORM" = "Linux" ] && [ "${CI:-false}" = "true" ] && [ -n "${US3_SCRATCH_ROOT:-}" ]; then
  US3_VCPKG_CACHE="$US3_SCRATCH_ROOT/vcpkg-cache"
else
  US3_VCPKG_CACHE="$HOME/.vcpkg-cache"
fi
mkdir -p "$US3_VCPKG_CACHE"
export VCPKG_BINARY_SOURCES="clear;files,$US3_VCPKG_CACHE,readwrite"

# Downloads cache
if [ -n "${US3_VCPKG_DOWNLOADS:-}" ]; then
  : # set via env
elif [ "$PLATFORM" = "Linux" ] && [ "${CI:-false}" = "true" ] && [ -n "${US3_SCRATCH_ROOT:-}" ]; then
  US3_VCPKG_DOWNLOADS="$US3_SCRATCH_ROOT/vcpkg-downloads"
else
  US3_VCPKG_DOWNLOADS="$HOME/vcpkg-downloads"
fi
mkdir -p "$US3_VCPKG_DOWNLOADS"
export VCPKG_DOWNLOADS="$US3_VCPKG_DOWNLOADS"

export VCPKG_INSTALL_OPTIONS="--clean-after-build"

CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
export VCPKG_MAX_CONCURRENCY="$CORES"

OVERLAY_TRIPLETS="${SOURCE_DIR}/admin/cmake/triplets"
OVERLAY_PORTS="${SOURCE_DIR}/admin/cmake/ports"

VCPKG_ARGS=(
  "--triplet=${TRIPLET}"
  "--host-triplet=${STATIC_TRIPLET}"
  "--overlay-triplets=${OVERLAY_TRIPLETS}"
  "--x-no-default-features"
)
if [ -d "$OVERLAY_PORTS" ]; then
  VCPKG_ARGS+=("--overlay-ports=${OVERLAY_PORTS}")
fi
if [ -n "$FEATURE" ]; then
  VCPKG_ARGS+=("--x-feature=${FEATURE}")
fi

echo "  vcpkg root     : $US3_VCPKG_ROOT"
echo "  vcpkg cache    : $US3_VCPKG_CACHE"
echo "  vcpkg downloads: $US3_VCPKG_DOWNLOADS"
echo "  triplet        : $TRIPLET"
echo "  concurrency    : $CORES"
echo ""

# =============================================================================
# INSTALL
# =============================================================================
echo "=========================================="
echo "Stage ${STAGE}/${MAX_STAGE}: vcpkg install"
echo "=========================================="
df -h
echo ""

"$US3_VCPKG_ROOT/vcpkg" install "${VCPKG_ARGS[@]}"

echo ""
echo "Stage ${STAGE} complete."
df -h
du -sh "$US3_VCPKG_CACHE" "$US3_VCPKG_DOWNLOADS" 2>/dev/null || true
