# The locked library uses /MD or /MDd, without /GL or /LTCG. Its exact producer
# compiler remains in native.lock.json; consumers may use newer servicing
# patches in the same compiler family, never an older toolchain.
if(NOT MSVC OR NOT CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "x64")
  message(FATAL_ERROR "Prebuilt Zinnia requires the Windows x64 MSVC toolchain.")
endif()
if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS "19.51.36243.0"
    OR NOT CMAKE_CXX_COMPILER_VERSION MATCHES "^19\\.51\\.")
  message(FATAL_ERROR
    "Prebuilt Zinnia requires MSVC v145 19.51.36243.0 or a newer 19.51 servicing patch; "
    "actual compiler is ${CMAKE_CXX_COMPILER_VERSION}.")
endif()
