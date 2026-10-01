# Kirakara 自有构建接线，采用仓库根 MIT 许可。
# USE_SYSTEM_MARISA 是 OpenCC 的选项名；实际只使用本仓库固定源码构建的库，
# 不从系统目录寻找 marisa，也不修改上游源码。
if(NOT PROJECT_NAME STREQUAL "opencc")
  message(FATAL_ERROR "Kirakara marisa 接线只适用于 OpenCC 项目")
endif()
get_filename_component(_kirakara_repository "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_kirakara_marisa_prefix "${_kirakara_repository}/.kfe/native/librime-deps")
if(NOT KIRAKARA_REPOSITORY_MARISA_PREFIX STREQUAL _kirakara_marisa_prefix)
  message(FATAL_ERROR "marisa 必须来自当前仓库的固定构建目录")
endif()
set(_kirakara_marisa_library "${_kirakara_marisa_prefix}/lib/marisa.lib")
if(NOT EXISTS "${_kirakara_marisa_library}" OR
   NOT EXISTS "${_kirakara_marisa_prefix}/include/marisa.h")
  message(FATAL_ERROR "先构建并安装固定源码的 marisa")
endif()
if(DEFINED LIBMARISA AND NOT LIBMARISA STREQUAL _kirakara_marisa_library)
  message(FATAL_ERROR "已有 OpenCC marisa 缓存不匹配；不替换未知依赖")
endif()
if(TARGET marisa)
  message(FATAL_ERROR "OpenCC 已存在其他 marisa 目标；不混用两份库")
endif()
add_library(marisa STATIC IMPORTED)
set_target_properties(marisa PROPERTIES
  IMPORTED_LOCATION "${_kirakara_marisa_library}"
  INTERFACE_INCLUDE_DIRECTORIES "${_kirakara_marisa_prefix}/include")
set(LIBMARISA "${_kirakara_marisa_library}" CACHE FILEPATH
  "当前仓库固定源码的 marisa，非系统自动探测")
