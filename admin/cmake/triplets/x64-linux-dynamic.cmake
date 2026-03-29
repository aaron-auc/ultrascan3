set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)

set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_BUILD_TYPE release)

# Prevent vcpkg's qt_install_submodule.cmake from injecting
# -DCMAKE_OSX_DEPLOYMENT_TARGET=14 into the inner qtbase configure.
# Qt interprets any non-empty CMAKE_OSX_DEPLOYMENT_TARGET on a non-Darwin
# host as an Android cross-compile indicator, breaking the xcb feature probe.
set(VCPKG_OSX_DEPLOYMENT_TARGET "")

# Pass Qt feature overrides directly into every port's cmake configure.
# - FEATURE_xcb_syslibs=ON: bootstrap-linux.sh installs all required xcb-util-*
#   packages; this tells Qt the syslibs condition is satisfied.
# Note: the x86intrin/rdseed GCC 8 issue is fixed via the qtbase overlay port
#   patch (buildsys/vcpkg/overlay-ports/qtbase/fix-x86intrin-rdseed.patch).
set(VCPKG_CMAKE_CONFIGURE_OPTIONS
    -DFEATURE_xcb_syslibs=ON
)
