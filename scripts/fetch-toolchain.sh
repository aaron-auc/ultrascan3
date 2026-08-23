#!/usr/bin/env bash
# =============================================================================
# fetch-toolchain.sh -- resolve the prebuilt dependency toolchain for this host
#
# PURPOSE
# -------
# Application builds do not compile dependencies. They consume a prebuilt vcpkg
# binary cache produced once by .github/workflows/toolchain-build.yml and
# pinned in buildsys/toolchain.lock.json.
#
# This script resolves the pin for the current platform, downloads and verifies
# the archive if needed, and prints the directory to use as the vcpkg binary
# cache. build.sh consumes that as US3_VCPKG_CACHE.
#
# On Linux the toolchain is baked into the container image, so there is nothing
# to download; this script just validates that it is present.
#
# USAGE
#   eval "$(scripts/fetch-toolchain.sh --export)"   # sets US3_VCPKG_CACHE
#   scripts/fetch-toolchain.sh                      # prints the path
#
# OPTIONS
#   --export        Emit shell assignments instead of a bare path.
#   --github-env    Append US3_VCPKG_CACHE to $GITHUB_ENV (CI convenience).
#   --dest PATH     Where to extract archives (default: a per-user cache dir).
#   --allow-missing Exit 0 with no output if the pin has no artifact yet.
#                   Used by the toolchain workflow itself, which builds the
#                   thing this script normally downloads.
#
# ENVIRONMENT
#   US3_TOOLCHAIN_DIR   Override the extraction destination.
#   GH_TOKEN            Used for the release download when set (private repos,
#                       and higher rate limits on public ones).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${SOURCE_DIR}/buildsys/toolchain.lock.json"

EXPORT_MODE=false
GITHUB_ENV_MODE=false
ALLOW_MISSING=false
DEST="${US3_TOOLCHAIN_DIR:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --export)        EXPORT_MODE=true; shift ;;
    --github-env)    GITHUB_ENV_MODE=true; shift ;;
    --allow-missing) ALLOW_MISSING=true; shift ;;
    --dest)          DEST="$2"; shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -f "$LOCK_FILE" ] || { echo "ERROR: missing $LOCK_FILE" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Identify this host's target key
# -----------------------------------------------------------------------------
_uname_s="$(uname -s)"
_uname_m="$(uname -m)"

case "$_uname_m" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) echo "ERROR: unsupported architecture: $_uname_m" >&2; exit 1 ;;
esac

case "$_uname_s" in
  Darwin) TARGET="macos-${ARCH}" ;;
  Linux)
    # Distinguish the two Linux targets by their glibc lineage: Oracle Linux 8
    # and Ubuntu 24.04 are not ABI-compatible, so they get separate toolchains.
    if [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      case "${ID:-}" in
        ol|rhel|rocky|almalinux) TARGET="oraclelinux8-${ARCH}" ;;
        ubuntu|debian)           TARGET="ubuntu2404-${ARCH}" ;;
        *) echo "ERROR: unrecognised Linux distribution: ${ID:-unknown}" >&2; exit 1 ;;
      esac
    else
      echo "ERROR: /etc/os-release not readable; cannot identify Linux target" >&2
      exit 1
    fi
    ;;
  *) echo "ERROR: unsupported platform: $_uname_s" >&2; exit 1 ;;
esac

# -----------------------------------------------------------------------------
# Read the pin
# -----------------------------------------------------------------------------
read -r KIND ASSET SHA256 IMAGE DIGEST TAG RELEASE_TAG < <(
  python3 - "$LOCK_FILE" "$TARGET" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
target = lock.get("targets", {}).get(sys.argv[2])
if target is None:
    sys.stderr.write(f"ERROR: no toolchain pin for target '{sys.argv[2]}'\n")
    sys.exit(1)
fields = [
    target.get("kind", ""),
    target.get("asset", "-"),
    target.get("sha256", "") or "-",
    target.get("image", "-"),
    target.get("digest", "") or "-",
    target.get("tag", "-"),
    lock.get("release_tag", "-"),
]
print(" ".join(str(f) if f else "-" for f in fields))
PY
)

# -----------------------------------------------------------------------------
# Container targets: the toolchain ships inside the image.
# -----------------------------------------------------------------------------
if [ "$KIND" = "container" ]; then
  BAKED="${US3_VCPKG_CACHE:-/opt/us3-toolchain/vcpkg-cache}"
  if [ ! -d "$BAKED" ]; then
    echo "ERROR: expected the toolchain baked into this image at $BAKED" >&2
    echo "       Target '$TARGET' is pinned to ${IMAGE}:${TAG}." >&2
    echo "       Are you running outside the toolchain container?" >&2
    exit 1
  fi
  CACHE_DIR="$BAKED"
else
  # ---------------------------------------------------------------------------
  # Archive targets: download, verify, extract.
  # ---------------------------------------------------------------------------
  if [ "$SHA256" = "-" ]; then
    if [ "$ALLOW_MISSING" = true ]; then exit 0; fi
    echo "ERROR: toolchain pin for '$TARGET' has no sha256 recorded." >&2
    echo "       Run the 'Toolchain' workflow to build and publish it, then" >&2
    echo "       merge the pin update it produces." >&2
    exit 1
  fi

  if [ -z "$DEST" ]; then
    case "$_uname_s" in
      Darwin) DEST="${HOME}/Library/Caches/ultrascan3/toolchain" ;;
      *)      DEST="${XDG_CACHE_HOME:-$HOME/.cache}/ultrascan3/toolchain" ;;
    esac
  fi

  CACHE_DIR="${DEST}/${TARGET}/${SHA256}"
  STAMP="${CACHE_DIR}/.complete"

  if [ ! -f "$STAMP" ]; then
    mkdir -p "$DEST"
    TMP_ARCHIVE="${DEST}/.${ASSET}.partial"
    # Repository is derived, never hardcoded: this file is identical upstream
    # and in every fork, and each publishes its toolchain to its own releases.
    REPO="${GITHUB_REPOSITORY:-}"
    if [ -z "$REPO" ]; then
      ORIGIN="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || echo "")"
      REPO="$(printf '%s' "$ORIGIN" \
        | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
    fi
    if [ -z "$REPO" ]; then
      echo "ERROR: cannot determine the GitHub repository to download from." >&2
      echo "       Set GITHUB_REPOSITORY=<owner>/<repo> and retry." >&2
      exit 1
    fi
    URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${ASSET}"

    echo "Fetching toolchain for ${TARGET}" >&2
    echo "  ${URL}" >&2

    CURL_AUTH=()
    [ -n "${GH_TOKEN:-}" ] && CURL_AUTH=(-H "Authorization: Bearer ${GH_TOKEN}")

    curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
         --connect-timeout 30 "${CURL_AUTH[@]}" \
         -o "$TMP_ARCHIVE" "$URL"

    # Verify BEFORE extracting. A corrupted or substituted archive must never
    # reach the build tree.
    if command -v sha256sum >/dev/null 2>&1; then
      ACTUAL="$(sha256sum "$TMP_ARCHIVE" | awk '{print $1}')"
    else
      ACTUAL="$(shasum -a 256 "$TMP_ARCHIVE" | awk '{print $1}')"
    fi
    if [ "$ACTUAL" != "$SHA256" ]; then
      rm -f "$TMP_ARCHIVE"
      echo "ERROR: checksum mismatch for ${ASSET}" >&2
      echo "  expected ${SHA256}" >&2
      echo "  actual   ${ACTUAL}" >&2
      exit 1
    fi

    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    tar --use-compress-program=unzstd -xf "$TMP_ARCHIVE" -C "$CACHE_DIR"
    rm -f "$TMP_ARCHIVE"
    touch "$STAMP"
    echo "Toolchain extracted to ${CACHE_DIR}" >&2
  else
    echo "Toolchain already present: ${CACHE_DIR}" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Emit
# -----------------------------------------------------------------------------
if [ "$GITHUB_ENV_MODE" = true ] && [ -n "${GITHUB_ENV:-}" ]; then
  echo "US3_VCPKG_CACHE=${CACHE_DIR}" >> "$GITHUB_ENV"
fi

if [ "$EXPORT_MODE" = true ]; then
  echo "export US3_VCPKG_CACHE='${CACHE_DIR}'"
else
  echo "$CACHE_DIR"
fi
