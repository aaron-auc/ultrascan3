# =============================================================================
# UltraScan3 build toolchain -- Ubuntu 24.04 (x86_64)
#
# Ubuntu 24.04 ships glibc 2.39, so Qt's official binaries would technically
# run here. We build from source anyway, for one reason: the binaries this
# image produces must be built the same way on every Linux target. Two
# provisioning mechanisms for two Linux distributions is the kind of asymmetry
# that turns into a class of bugs only one platform can hit.
#
# The image carries:
#   - the OS toolchain (gcc, cmake, ninja, X/XCB headers)
#   - a populated vcpkg binary cache at /opt/us3-toolchain/vcpkg-cache
#
# Built and published by .github/workflows/toolchain-build.yml.
# Pinned by digest in buildsys/toolchain.lock.json.
# =============================================================================

FROM ubuntu:24.04

ENV US3_TOOLCHAIN_ROOT=/opt/us3-toolchain \
    US3_VCPKG_CACHE=/opt/us3-toolchain/vcpkg-cache \
    US3_VCPKG_ROOT=/opt/us3-toolchain/vcpkg \
    US3_VCPKG_DOWNLOADS=/opt/us3-toolchain/downloads \
    DEBIAN_FRONTEND=noninteractive \
    CI=true

# Minimum bootstrap needed to run the repo's own bootstrap script; that script
# owns the real package list.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        git python3 python3-venv sudo ca-certificates curl tar zstd \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Dependency-defining inputs only. Application source is deliberately excluded
# so that changing UltraScan3 code never invalidates this image.
COPY vcpkg.json vcpkg-configuration.json ./
COPY buildsys/toolchain.lock.json        ./buildsys/
COPY buildsys/vcpkg/overlay-ports        ./buildsys/vcpkg/overlay-ports
COPY qwtplot3d                           ./qwtplot3d
COPY admin/cmake/triplets                ./admin/cmake/triplets
COPY scripts/bootstrap-linux.sh          ./scripts/
COPY scripts/build-toolchain.sh          ./scripts/

RUN chmod +x scripts/*.sh && bash scripts/bootstrap-linux.sh

RUN bash scripts/build-toolchain.sh \
        --cache-dir "${US3_VCPKG_CACHE}" \
        --qt6 \
        --profiles "APP HPC" \
        --skip-bootstrap \
 && rm -rf "${US3_VCPKG_ROOT}/buildtrees" \
           "${US3_VCPKG_ROOT}/packages" \
           "${US3_VCPKG_ROOT}"/installed-toolchain-* \
           "${US3_VCPKG_DOWNLOADS}" \
 && du -sh "${US3_VCPKG_CACHE}"

WORKDIR /
RUN rm -rf /src

RUN test -d "${US3_VCPKG_CACHE}" \
 && test "$(find "${US3_VCPKG_CACHE}" -name '*.zip' | wc -l)" -gt 0 \
 && echo "toolchain cache OK: $(find "${US3_VCPKG_CACHE}" -name '*.zip' | wc -l) packages"

# Supplied by the toolchain workflow. GHCR uses this label to link the
# package to its repository, so it must name whichever fork published it.
ARG IMAGE_SOURCE=https://github.com/ehb54/ultrascan3

LABEL org.opencontainers.image.title="UltraScan3 build toolchain (Ubuntu 24.04)" \
      org.opencontainers.image.description="Prebuilt Qt6 and C dependencies for UltraScan3 Ubuntu builds" \
      org.opencontainers.image.source="${IMAGE_SOURCE}"
