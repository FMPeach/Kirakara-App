cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

if(NOT MSVC OR NOT CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "x64")
  message(FATAL_ERROR "Prebuilt Zinnia requires the Windows x64 MSVC toolchain.")
endif()
if(NOT CMAKE_CXX_COMPILER_VERSION VERSION_EQUAL "19.51.36243.0")
  message(FATAL_ERROR
    "Prebuilt Zinnia is locked to MSVC v145 19.51.36243.0; actual compiler is "
    "${CMAKE_CXX_COMPILER_VERSION}.")
endif()
add_library(kirakara_zinnia STATIC IMPORTED GLOBAL)
set_target_properties(kirakara_zinnia PROPERTIES
  IMPORTED_CONFIGURATIONS "Debug;Profile;Release"
  IMPORTED_LOCATION_DEBUG
    "${KIRAKARA_IME_RUNTIME_DIR}/zinnia/windows/lib/Debug/kirakara_zinnia.lib"
  IMPORTED_LOCATION_PROFILE
    "${KIRAKARA_IME_RUNTIME_DIR}/zinnia/windows/lib/Release/kirakara_zinnia.lib"
  IMPORTED_LOCATION_RELEASE
    "${KIRAKARA_IME_RUNTIME_DIR}/zinnia/windows/lib/Release/kirakara_zinnia.lib"
  INTERFACE_INCLUDE_DIRECTORIES
    "${KIRAKARA_IME_RUNTIME_DIR}/zinnia/windows/include"
  INTERFACE_COMPILE_DEFINITIONS "ZINNIA_STATIC_LIBRARY")

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "dcomp_compositor_bridge.cpp"
  "flutter_window.cpp"
  "ime_bridge.cpp"
  "main.cpp"
  "media_io_bridge.cpp"
  "stage_texture_bridge.cpp"
  "stage_texture_trace.cpp"
  "utils.cpp"
  "window_bridge.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib" "dxgi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "winhttp.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "wtsapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE kirakara_zinnia)
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../engine/include"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${KIRAKARA_SHOW_HOST_DLL}"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/libshow_host.dll"
  COMMENT "Copying Kirakara Show host DLL")
