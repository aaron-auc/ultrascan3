# =============================================================================
# UltraScan3 build toolchain -- Oracle Linux 8 / RHEL 8 (x86_64)
#
# Oracle Linux 8 ships glibc 2.28. Qt's official Linux binaries are linked
# against glibc 2.34, so this is the one platform where Qt genuinely must be
# compiled from source. That compilation happens HERE, once, when this image is
# built -- never on the commit path.
#
# The image carries:
#   - the OS toolchain (gcc-toolset-13, cmake, ninja, X/XCB headers)
#   - a populated vcpkg binary cache at /opt/us3-toolchain/vcpkg-cache
#
# Application builds run inside this image and restore every dependency from
# that cache in seconds.
#
# Built and published by .github/workflows/toolchain-build.yml.
# Pinned by digest in buildsys/toolchain.lock.json.
# =============================================================================

FROM oraclelinux:8

ENV US3_TOOLCHAIN_ROOT=/opt/us3-toolchain \
    US3_VCPKG_CACHE=/opt/us3-toolchain/vcpkg-cache \
    US3_VCPKG_ROOT=/opt/us3-toolchain/vcpkg \
    US3_VCPKG_DOWNLOADS=/opt/us3-toolchain/downloads \
    CI=true

# -----------------------------------------------------------------------------
# Minimum bootstrap needed to run the repo's own bootstrap script.
# Everything else is installed by scripts/bootstrap-linux.sh so there is exactly
# one place that knows this platform's package list.
# -----------------------------------------------------------------------------
RUN dnf -y install git python3.9 sudo which findutils tar zstd \
    && dnf clean all \
    && alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 100

WORKDIR /src

# -----------------------------------------------------------------------------
# Only the dependency-defining inputs are copied. Application source is
# deliberately excluded: changing UltraScan3 code must never invalidate this
# image, which is the entire point of separating the two pipelines.
# -----------------------------------------------------------------------------
COPY vcpkg.json vcpkg-configuration.json ./
COPY buildsys/toolchain.lock.json        ./buildsys/
COPY buildsys/vcpkg/overlay-ports        ./buildsys/vcpkg/overlay-ports
COPY admin/cmake/triplets                ./admin/cmake/triplets
COPY scripts/bootstrap-linux.sh          ./scripts/
COPY scripts/build-toolchain.sh          ./scripts/

RUN chmod +x scripts/*.sh && bash scripts/bootstrap-linux.sh

# -----------------------------------------------------------------------------
# Compile the dependency graph for both profiles this platform ships.
#
# The buildtrees and downloads are discarded afterwards: they are build scratch,
# not toolchain, and keeping them would roughly triple the image size.
# -----------------------------------------------------------------------------
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

# Sanity check: fail the image build, not a downstream application build.
RUN test -d "${US3_VCPKG_CACHE}" \
 && test "$(find "${US3_VCPKG_CACHE}" -name '*.zip' | wc -l)" -gt 0 \
 && echo "toolchain cache OK: $(find "${US3_VCPKG_CACHE}" -name '*.zip' | wc -l) packages"

LABEL org.opencontainers.image.title="UltraScan3 build toolchain (Oracle Linux 8)" \
      org.opencontainers.image.description="Prebuilt Qt6 and C dependencies for UltraScan3 RHEL8 builds" \
      org.opencontainers.image.source="https://github.com/aaron-auc/ultrascan3"
