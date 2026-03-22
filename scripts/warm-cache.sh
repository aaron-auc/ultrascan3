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
# Each stage calls "vcpkg install" for a targeted subset of ports.  vcpkg is
# additive: ports already present in the binary cache are restored instantly
# without rebuilding, so later stages automatically benefit from earlier ones.
#
# STAGES (qt6-app, the primary target)
# -------------------------------------
#   1  base      openssl, zlib, libarchive, eigen3
#   2  qtbase    qtbase  (largest port -- ~20-30 min, main disk pressure)
#   3  qtmods    qtsvg, qttools, qtdatavis3d, qtmultimedia, libmariadb, sqlite3
#   4  qwt       qwt-6-3-0-qt6, qwtplot3d-qwt-6-3-0-qt6
#
# STAGES (qt5-qwt616-app)
# ------------------------
#   1  base      openssl, zlib, libarchive, eigen3
#   2  qtbase    qt5-base
#   3  qtmods    qt5-svg, qt5-tools, qt5-datavis3d, qt5-multimedia, libmariadb, sqlite3
#   4  qwt       qwt-6-1-6, qwtplot3d-qwt-6-1-6-qt5
#
# USAGE
# -----
#   ./scripts/warm-cache.sh --stage <1|2|3|4> [OPTIONS]
#
# OPTIONS
#   --stage N          Required. Which stage to install (1-4).
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
      if [[ "$STAGE" != "1" && "$STAGE" != "2" && "$STAGE" != "3" && "$STAGE" != "4" ]]; then
        echo "ERROR: --stage must be 1, 2, 3, or 4" >&2
        exit 1
      fi
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
      sed -n '/^# PURPOSE/,/^# ===*/p' "$0" | head -n -1
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [ -z "$STAGE" ]; then
  echo "ERROR: --stage <1|2|3|4> is required." >&2
  exit 1
fi

# =============================================================================
# PLATFORM / ARCH DETECTION
# =============================================================================
if [[ "$OSTYPE" == "darwin"* ]]; then
  PLATFORM="macOS"
  PLATFORM_PREFIX="macos"
elif [[ "$OSTYPE" == "linux-gnu"* || "$(uname -s)" == "Linux" ]]; then
  PLATFORM="Linux"
  PLATFORM_PREFIX="linux"
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
# TRIPLET DERIVATION
# Must match toolchain.cmake / build.sh _derive_triplet().
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
echo "  Stage       : $STAGE / 4"
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

echo "Using vcpkg: $US3_VCPKG_ROOT"

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
  : # already set
elif [ "$PLATFORM" = "Linux" ] && [ "${CI:-false}" = "true" ] && [ -n "${US3_SCRATCH_ROOT:-}" ]; then
  US3_VCPKG_CACHE="$US3_SCRATCH_ROOT/vcpkg-cache"
else
  US3_VCPKG_CACHE="$HOME/.vcpkg-cache"
fi
mkdir -p "$US3_VCPKG_CACHE"
export VCPKG_BINARY_SOURCES="clear;files,$US3_VCPKG_CACHE,readwrite"

# Downloads cache
if [ -n "${US3_VCPKG_DOWNLOADS:-}" ]; then
  : # already set
elif [ "$PLATFORM" = "Linux" ] && [ "${CI:-false}" = "true" ] && [ -n "${US3_SCRATCH_ROOT:-}" ]; then
  US3_VCPKG_DOWNLOADS="$US3_SCRATCH_ROOT/vcpkg-downloads"
else
  US3_VCPKG_DOWNLOADS="$HOME/vcpkg-downloads"
fi
mkdir -p "$US3_VCPKG_DOWNLOADS"
export VCPKG_DOWNLOADS="$US3_VCPKG_DOWNLOADS"

# Clean up buildtrees after each port to reduce peak disk usage
export VCPKG_INSTALL_OPTIONS="--clean-after-build"

CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
export VCPKG_MAX_CONCURRENCY="$CORES"

# Overlay triplets and ports
OVERLAY_TRIPLETS="${SOURCE_DIR}/admin/cmake/triplets"
OVERLAY_PORTS="${SOURCE_DIR}/admin/cmake/ports"

VCPKG_COMMON_ARGS=(
  "--triplet=${TRIPLET}"
  "--overlay-triplets=${OVERLAY_TRIPLETS}"
  "--host-triplet=${STATIC_TRIPLET}"
)

if [ -d "$OVERLAY_PORTS" ]; then
  VCPKG_COMMON_ARGS+=("--overlay-ports=${OVERLAY_PORTS}")
fi

echo ""
echo "  vcpkg root     : $US3_VCPKG_ROOT"
echo "  vcpkg cache    : $US3_VCPKG_CACHE"
echo "  vcpkg downloads: $US3_VCPKG_DOWNLOADS"
echo "  triplet        : $TRIPLET"
echo "  concurrency    : $CORES"
echo ""

# =============================================================================
# STAGE PORT LISTS
# =============================================================================
# Stage 1: Small base libs — fast, always finishes, establishes cache entry.
STAGE1_PORTS=("openssl" "zlib" "libarchive" "eigen3")

# Stage 2: qtbase alone — the single most disk/time-intensive port.
# Split from modules so if it finishes, its cache entry is saved before
# attempting anything else.
if [ "$QT_VARIANT" = "qt6" ]; then
  STAGE2_PORTS=("qtbase")
else
  STAGE2_PORTS=("qt5-base")
fi

# Stage 3: Remaining Qt modules + DB libs.
if [ "$QT_VARIANT" = "qt6" ]; then
  STAGE3_PORTS=("qtsvg" "qttools" "qtdatavis3d" "qtmultimedia" "libmariadb" "sqlite3")
else
  STAGE3_PORTS=("qt5-svg" "qt5-tools" "qt5-datavis3d" "qt5-multimedia" "libmariadb" "sqlite3")
fi

# Stage 4: Qwt + QwtPlot3D — depend on Qt modules from stage 3.
if [ "$QT_VARIANT" = "qt6" ]; then
  STAGE4_PORTS=("qwt-6-3-0-qt6" "qwtplot3d-qwt-6-3-0-qt6")
else
  STAGE4_PORTS=("qwt-6-1-6" "qwtplot3d-qwt-6-1-6-qt5")
fi

# =============================================================================
# SELECT AND INSTALL THIS STAGE
# =============================================================================
case "$STAGE" in
  1) PORTS=("${STAGE1_PORTS[@]}") ;;
  2) PORTS=("${STAGE2_PORTS[@]}") ;;
  3) PORTS=("${STAGE3_PORTS[@]}") ;;
  4) PORTS=("${STAGE4_PORTS[@]}") ;;
esac

echo "=========================================="
echo "Stage ${STAGE}: installing ${#PORTS[@]} port(s)"
echo "  ${PORTS[*]}"
echo "=========================================="
echo ""

df -h

"$US3_VCPKG_ROOT/vcpkg" install \
  "${VCPKG_COMMON_ARGS[@]}" \
  "${PORTS[@]}"

echo ""
echo "Stage ${STAGE} complete."
df -h
du -sh "$US3_VCPKG_CACHE" "$US3_VCPKG_DOWNLOADS" 2>/dev/null || true
