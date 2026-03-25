set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)

set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_BUILD_TYPE release)

# Prevent vcpkg's qt_install_submodule.cmake from injecting
# -DCMAKE_OSX_DEPLOYMENT_TARGET=14 into the inner qtbase configure.
# Qt interprets any non-empty CMAKE_OSX_DEPLOYMENT_TARGET on a non-Darwin
# host as an Android cross-compile indicator, breaking the xcb feature probe.
set(VCPKG_OSX_DEPLOYMENT_TARGET "")

# Ensure pkg-config can find xcb/x11 syslib .pc files for Qt's TEST_xcb_syslibs
# probe. The preset environment block does not propagate into vcpkg's inner
# port configure subprocesses, so we must set it here in the triplet.
set(ENV{PKG_CONFIG_PATH} "/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig:$ENV{PKG_CONFIG_PATH}")
