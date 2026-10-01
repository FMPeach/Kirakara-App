cmake_minimum_required(VERSION 3.20)
project(kirakara_zinnia LANGUAGES CXX)

if(NOT IS_DIRECTORY "${ZINNIA_SOURCE_DIR}")
  message(FATAL_ERROR "Provide the locked official ZINNIA_SOURCE_DIR")
endif()

add_library(kirakara_zinnia STATIC
  "${ZINNIA_SOURCE_DIR}/character.cpp"
  "${ZINNIA_SOURCE_DIR}/feature.cpp"
  "${ZINNIA_SOURCE_DIR}/libzinnia.cpp"
  "${ZINNIA_SOURCE_DIR}/param.cpp"
  "${ZINNIA_SOURCE_DIR}/recognizer.cpp"
  "${ZINNIA_SOURCE_DIR}/sexp.cpp"
  "${ZINNIA_SOURCE_DIR}/svm.cpp"
  "${ZINNIA_SOURCE_DIR}/trainer.cpp"
)
target_compile_features(kirakara_zinnia PUBLIC cxx_std_14)
target_compile_definitions(kirakara_zinnia PUBLIC
  ZINNIA_STATIC_LIBRARY HAVE_WINDOWS_H HAVE_SYS_TYPES_H HAVE_SYS_STAT_H
  HAVE_STRING_H HAVE_FCNTL_H HAVE_CTYPE_H HAVE_STDLIB_H HAVE_STDINT_H
  NOMINMAX WORDS_LITENDIAN "VERSION=\"0.06\"" "PACKAGE=\"zinnia\""
)
target_include_directories(kirakara_zinnia PUBLIC "${ZINNIA_SOURCE_DIR}")
if(MSVC)
  # 外部旧库的警告不改变自有 Runner 的 /W4 /WX 策略。
  target_compile_options(kirakara_zinnia PRIVATE /W0 /utf-8)
endif()

if(CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
  add_executable(kirakara_zinnia_convert convert_main.cpp)
  target_link_libraries(kirakara_zinnia_convert PRIVATE kirakara_zinnia)
  if(MSVC)
    target_compile_options(kirakara_zinnia_convert PRIVATE /utf-8)
  endif()
  install(TARGETS kirakara_zinnia kirakara_zinnia_convert
    ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)
endif()
