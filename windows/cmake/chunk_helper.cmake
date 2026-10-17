# Optional independent tool for developer builds; release packaging requires it.
# Read current process input rather than retaining a developer path in CACHE.
unset(KIRAKARA_CHUNK_HELPER_ROOT CACHE)
unset(KIRAKARA_CHUNK_HELPER_ROOT)
if(DEFINED ENV{KIRAKARA_CHUNK_HELPER_ROOT} AND
    NOT "$ENV{KIRAKARA_CHUNK_HELPER_ROOT}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{KIRAKARA_CHUNK_HELPER_ROOT}"
    KIRAKARA_CHUNK_HELPER_ROOT)
  if(NOT IS_ABSOLUTE "${KIRAKARA_CHUNK_HELPER_ROOT}")
    message(FATAL_ERROR "ChunK Helper publish directory must be absolute.")
  endif()
  if(NOT EXISTS "${KIRAKARA_CHUNK_HELPER_ROOT}/ChunK Helper.exe")
    message(FATAL_ERROR "ChunK Helper publish directory is incomplete.")
  endif()
  # Compare contents, not just timestamps: independent publishes can have equal
  # timestamps even when their DLLs differ. Keep every copied file in the normal
  # install manifest, including runtime dependencies and third-party licenses.
  set(_chunk_helper_install_code [=[
    set(_helper_source "@KIRAKARA_CHUNK_HELPER_ROOT@")
    set(_helper_destination "@CMAKE_INSTALL_PREFIX@/tools/ChunKHelper")
    file(GLOB_RECURSE _helper_files LIST_DIRECTORIES false
      RELATIVE "${_helper_source}" "${_helper_source}/*")
    foreach(_helper_file IN LISTS _helper_files)
      if(_helper_file MATCHES "(^|/)(logs|settings)(/|$)" OR
          _helper_file MATCHES "\\.(log|pdb|dmp|etl)$")
        continue()
      endif()
      configure_file("${_helper_source}/${_helper_file}"
        "${_helper_destination}/${_helper_file}" COPYONLY)
      list(APPEND CMAKE_INSTALL_MANIFEST_FILES
        "${_helper_destination}/${_helper_file}")
    endforeach()
  ]=])
  string(CONFIGURE "${_chunk_helper_install_code}"
    _chunk_helper_install_code @ONLY)
  install(CODE "${_chunk_helper_install_code}" COMPONENT Runtime)
endif()
