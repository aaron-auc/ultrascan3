set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)

# Release-only, matching the macOS and Linux triplets.
#
# Without this file vcpkg falls back to its built-in x64-windows triplet, which
# builds every dependency twice -- debug and release. UltraScan3 ships neither
# the debug libraries nor their PDBs, so that work is pure waste: it doubled
# both the dependency build time and the size of the cached binaries.
#
# This does not affect debug builds of UltraScan3 itself. CMAKE_BUILD_TYPE=Debug
# still produces unoptimized code with full symbols; it simply links against
# release dependencies, which is what macOS and Linux have always done.
set(VCPKG_BUILD_TYPE release)
