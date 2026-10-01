# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(kirakara_app LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "kirakara_app")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

if(NOT DEFINED ENV{KIRAKARA_NATIVE_RUNTIME_ROOT}
    OR "$ENV{KIRAKARA_NATIVE_RUNTIME_ROOT}" STREQUAL "")
  message(FATAL_ERROR
    "KIRAKARA_NATIVE_RUNTIME_ROOT must name a verified prebuilt IME runtime. "
    "The Windows build never compiles Rime, Mozc, or Zinnia sources.")
endif()
file(TO_CMAKE_PATH "$ENV{KIRAKARA_NATIVE_RUNTIME_ROOT}"
  _KIRAKARA_NATIVE_RUNTIME_DIR)
get_filename_component(_KIRAKARA_NATIVE_RUNTIME_DIR
  "${_KIRAKARA_NATIVE_RUNTIME_DIR}" ABSOLUTE
  BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

unset(KIRAKARA_SHOW_HOST_DLL CACHE)
unset(KIRAKARA_SHOW_HOST_DLL)
if(NOT DEFINED ENV{KIRAKARA_SHOW_HOST_DLL}
    OR "$ENV{KIRAKARA_SHOW_HOST_DLL}" STREQUAL "")
  message(FATAL_ERROR
    "KIRAKARA_SHOW_HOST_DLL must explicitly name a verified external Show DLL. "
    "The App does not search, download, or build Show.")
endif()
file(TO_CMAKE_PATH "$ENV{KIRAKARA_SHOW_HOST_DLL}"
  KIRAKARA_SHOW_HOST_DLL)
if(NOT IS_ABSOLUTE "${KIRAKARA_SHOW_HOST_DLL}")
  message(FATAL_ERROR "KIRAKARA_SHOW_HOST_DLL must be an absolute path.")
endif()
get_filename_component(KIRAKARA_SHOW_HOST_DLL
  "${KIRAKARA_SHOW_HOST_DLL}" ABSOLUTE)
if(NOT EXISTS "${KIRAKARA_SHOW_HOST_DLL}")
  message(FATAL_ERROR
    "KIRAKARA_SHOW_HOST_DLL does not exist: ${KIRAKARA_SHOW_HOST_DLL}")
endif()
message(STATUS "Kirakara Show host DLL: ${KIRAKARA_SHOW_HOST_DLL}")

set(KIRAKARA_IME_RUNTIME_DIR "${_KIRAKARA_NATIVE_RUNTIME_DIR}/ime")
foreach(_KIRAKARA_REQUIRED_IME_FILE
    "../ime-runtime-provenance.json"
    "rime/windows/rime.dll"
    "mozc/windows/runtime/kirakara_mozc_bridge.exe"
    "zinnia/windows/include/zinnia.h"
    "zinnia/windows/lib/Debug/kirakara_zinnia.lib"
    "zinnia/windows/lib/Release/kirakara_zinnia.lib"
    "zinnia/windows/provenance.json")
  if(NOT EXISTS "${KIRAKARA_IME_RUNTIME_DIR}/${_KIRAKARA_REQUIRED_IME_FILE}")
    message(FATAL_ERROR
      "Verified prebuilt IME runtime is incomplete: ${_KIRAKARA_REQUIRED_IME_FILE}. "
      "Prepare the repository-local package; IME will not be disabled or rebuilt.")
  endif()
endforeach()

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

install(FILES "${KIRAKARA_SHOW_HOST_DLL}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

if(NOT DEFINED ENV{KIRAKARA_RIME_DATA_PACKAGE_ROOT})
  message(FATAL_ERROR "Verified Rime data package is missing; use flutterw to prepare it.")
endif()
file(TO_CMAKE_PATH "$ENV{KIRAKARA_RIME_DATA_PACKAGE_ROOT}"
  KIRAKARA_RIME_DATA_PACKAGE_ROOT)
foreach(_KIRAKARA_RIME_DATA_FILE "luna_pinyin_simp.schema.yaml" "opencc/t2s.json")
  if(NOT EXISTS "${KIRAKARA_RIME_DATA_PACKAGE_ROOT}/data/${_KIRAKARA_RIME_DATA_FILE}")
    message(FATAL_ERROR "Verified Rime data package is incomplete: ${_KIRAKARA_RIME_DATA_FILE}")
  endif()
endforeach()
if(NOT DEFINED ENV{KIRAKARA_HANDWRITING_PACKAGE_ROOT})
  message(FATAL_ERROR "Verified handwriting package is missing; use flutterw to prepare it.")
endif()
file(TO_CMAKE_PATH "$ENV{KIRAKARA_HANDWRITING_PACKAGE_ROOT}"
  KIRAKARA_HANDWRITING_PACKAGE_ROOT)
foreach(_KIRAKARA_MODEL "handwriting-ja.model" "handwriting-zh_CN.model")
  if(NOT EXISTS "${KIRAKARA_HANDWRITING_PACKAGE_ROOT}/models/${_KIRAKARA_MODEL}")
    message(FATAL_ERROR "Verified handwriting package is incomplete: ${_KIRAKARA_MODEL}")
  endif()
endforeach()
install(CODE "
  file(REMOVE_RECURSE \"${CMAKE_INSTALL_PREFIX}/ime\")
  " COMPONENT Runtime)
install(FILES "${KIRAKARA_IME_RUNTIME_DIR}/rime/windows/rime.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/ime/rime/windows"
  COMPONENT Runtime)
install(PROGRAMS
  "${KIRAKARA_IME_RUNTIME_DIR}/mozc/windows/runtime/kirakara_mozc_bridge.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/ime/mozc/windows/runtime"
  COMPONENT Runtime)

install(DIRECTORY "${KIRAKARA_HANDWRITING_PACKAGE_ROOT}/models/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/ime/zinnia/windows/models"
  COMPONENT Runtime)
install(DIRECTORY "${KIRAKARA_HANDWRITING_PACKAGE_ROOT}/sources"
  "${KIRAKARA_HANDWRITING_PACKAGE_ROOT}/licenses"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/third_party/handwriting"
  COMPONENT Runtime)
install(FILES "${KIRAKARA_HANDWRITING_PACKAGE_ROOT}/SOURCES.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/third_party/handwriting"
  COMPONENT Runtime)

install(DIRECTORY "${KIRAKARA_RIME_DATA_PACKAGE_ROOT}/data/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/ime/rime/windows/data"
  COMPONENT Runtime)
install(DIRECTORY "${KIRAKARA_RIME_DATA_PACKAGE_ROOT}/sources"
  "${KIRAKARA_RIME_DATA_PACKAGE_ROOT}/licenses"
  "${KIRAKARA_RIME_DATA_PACKAGE_ROOT}/modifications"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/third_party/rime-data"
  COMPONENT Runtime)
install(FILES "${KIRAKARA_RIME_DATA_PACKAGE_ROOT}/SOURCES.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/third_party/rime-data"
  COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
