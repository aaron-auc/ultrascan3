# CMakeLists.txt for us_mpi_analysis
#
# us_mpi_analysis is an MPI-only headless program. It unconditionally includes
# <mpi.h> and uses MPI_* calls throughout, so MPI is a hard requirement.
# This target is only built in HPC profile (US3_NO_DB=ON) or when ENABLE_MPI
# is explicitly set.

find_package(MPI REQUIRED CXX)

set(src_dir ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(us_mpi_analysis
    ${src_dir}/dmga_worker.cpp
    ${src_dir}/2dsa_worker.cpp
    ${src_dir}/pmasters_compjob.cpp
    ${src_dir}/us_mpi_parse.cpp
    ${src_dir}/ga_worker.cpp
    ${src_dir}/pcsa_master.cpp
    ${src_dir}/parallel_masters.cpp
    ${src_dir}/pcsa_worker.cpp
    ${src_dir}/2dsa_master.cpp
    ${src_dir}/dmga_master.cpp
    ${src_dir}/us_mpi_analysis.cpp
    ${src_dir}/ga_master.cpp
)

target_link_libraries(us_mpi_analysis
    PRIVATE
        us_program_common
        MPI::MPI_CXX
)

# Qt6 + LTO: qt_resourceFeatureZstd is referenced from the resource initialiser
# inside libus3_resources.a (pulled in via us_program_common WHOLE_ARCHIVE).
# With --as-needed the linker drops libzstd if it appears before the archive
# establishes the demand. Link it explicitly here, after us_program_common.
# The HPC Qt6 subset (Core/Network/Sql/Xml) does not pull in libzstd
# transitively, so we locate it by finding the actual .so next to Qt6::Core.
if(USE_QT6)
    get_target_property(_qt6core_loc Qt6::Core LOCATION)
    get_filename_component(_qt6_lib_dir "${_qt6core_loc}" DIRECTORY)
    find_library(_zstd_lib
        NAMES zstd
        HINTS "${_qt6_lib_dir}"
        NO_DEFAULT_PATH
    )
    if(_zstd_lib)
        target_link_libraries(us_mpi_analysis PRIVATE "${_zstd_lib}")
    else()
        message(FATAL_ERROR "[us_mpi_analysis] libzstd not found alongside Qt6::Core in ${_qt6_lib_dir}")
    endif()
endif()

target_include_directories(us_mpi_analysis
    PRIVATE
        ${src_dir}
        ${MPI_CXX_INCLUDE_DIRS}
)

# Suppress MPI deprecation warnings (MPICH/OpenMPI commonly trigger these)
if(MPI_CXX_COMPILE_OPTIONS)
    target_compile_options(us_mpi_analysis PRIVATE ${MPI_CXX_COMPILE_OPTIONS})
endif()

# us_revision.h is generated at build time by the us_version_headers target;
# declare the dependency explicitly so Ninja does not start compiling
# us_mpi_analysis before the header exists.
# In the APP path the header is always ready before programs compile (it's
# generated early via utils/gui deps), but in the lean HPC path there is
# nothing between configure and us_mpi_analysis compilation to ensure ordering.
add_dependencies(us_mpi_analysis us_version_headers)

message(STATUS "[us_mpi_analysis] MPI CXX compiler: ${MPI_CXX_COMPILER}")
message(STATUS "[us_mpi_analysis] MPI include dirs: ${MPI_CXX_INCLUDE_DIRS}")
message(STATUS "[us_mpi_analysis] MPI libraries: ${MPI_CXX_LIBRARIES}")
