// Kirakara 自有转换入口，采用根目录 MIT；调用的 Zinnia 库仍为 BSD。
#include "zinnia.h"

// 上游 CLI 在 libzinnia.cpp 实现，但不属于公共识别 API 头。
extern "C" int zinnia_convert(int argc, char** argv);

int main(int argc, char** argv) {
  return zinnia_convert(argc, argv);
}
