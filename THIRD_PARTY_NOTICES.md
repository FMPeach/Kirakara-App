# Third-Party Notices

Kirakara-App 自有源代码采用仓库根目录的 [MIT License](LICENSE)。本文件列出的第三方
组件继续适用各自许可证，Kirakara-App 的 MIT License 不覆盖或替代这些许可证。

版本以 `pubspec.lock`、`engine/engine.lock.json`、`native/native.lock.json` 和
`third_party/data.lock.json` 为准。Windows Release 中的
`data/flutter_assets/NOTICES.Z` 保留 Flutter 和 Dart package 生成的完整声明。

## Flutter Engine 与工具链

| 组件 | 当前版本或来源 | 许可证 | 许可证与来源 |
| --- | --- | --- | --- |
| Flutter Framework / Engine | Flutter 3.44.4，Engine `a10d8ac38de835021c8d2f920dbf50a920ccc030` | BSD-3-Clause | [Flutter](https://github.com/flutter/flutter)，[许可证](engine/licenses/Flutter-BSD-3-Clause.txt) |
| Dart SDK | 3.12.2 | BSD-3-Clause | [Dart](https://github.com/dart-lang/sdk)，[许可证](engine/licenses/Dart-BSD-3-Clause.txt) |
| Skia | 由锁定 Flutter Engine 引入 | BSD-3-Clause | [Skia](https://skia.googlesource.com/skia/)，[许可证](engine/licenses/Skia-BSD-3-Clause.txt) |
| ICU | 由锁定 Flutter Engine 引入 | ICU License | [ICU](https://github.com/unicode-org/icu)，[许可证](engine/licenses/ICU.txt) |
| GN | 锁定 revision 见 `engine/engine.lock.json` | BSD-3-Clause | [GN](https://gn.googlesource.com/gn)，[许可证](engine/licenses/GN-BSD-3-Clause.txt) |
| Ninja | 锁定 revision 见 `engine/engine.lock.json` | Apache-2.0 | [Ninja](https://github.com/ninja-build/ninja)，[许可证](engine/licenses/Ninja-Apache-2.0.txt) |

定制 Engine 中仍包含 Flutter Engine 自身的其他传递依赖。预编译包保留上游
`LICENSE`、`NOTICES` 和本仓库的 [Engine 修改说明](engine/MODIFICATIONS.md)。Kirakara
补丁不改变上游文件原有的许可证。

## Dart 与 Flutter package

下表列出 App 直接使用的运行时 package。它们的传递依赖及完整版权文本由 Flutter 的
LicenseRegistry 收集，并随构建产物中的 `NOTICES.Z` 一起分发。

| Package | 锁定版本 | 许可证 | 上游来源 |
| --- | --- | --- | --- |
| `ffi` | 2.2.0 | BSD-3-Clause | [dart-lang/native](https://github.com/dart-lang/native/tree/main/pkgs/ffi) |
| `http` | 1.6.0 | BSD-3-Clause | [dart-lang/http](https://github.com/dart-lang/http/tree/master/pkgs/http) |
| `sqlite3` | 2.9.4 | MIT | [simolus3/sqlite3.dart](https://github.com/simolus3/sqlite3.dart/tree/main/sqlite3) |
| `sqlite3_flutter_libs` | 0.5.42 | MIT；所分发 SQLite 为 Public Domain | [simolus3/sqlite3.dart](https://github.com/simolus3/sqlite3.dart/tree/main/sqlite3_flutter_libs) |
| `path` | 1.9.1 | BSD-3-Clause | [dart-lang/core](https://github.com/dart-lang/core/tree/main/pkgs/path) |
| `path_provider` | 2.1.6 | BSD-3-Clause | [flutter/packages](https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider) |
| `qr_flutter` | 4.1.0 | BSD-3-Clause | [theyakka/qr.flutter](https://github.com/theyakka/qr.flutter) |
| `xml` | 7.0.1 | MIT | [renggli/dart-xml](https://github.com/renggli/dart-xml) |
| `file_picker` | 11.0.3 | MIT | [miguelpruivo/flutter_file_picker](https://github.com/miguelpruivo/flutter_file_picker) |

`flutter_test`、`integration_test`、`flutter_lints` 及其依赖只用于开发和测试，不作为
Kirakara-App 自有代码重新授权。

## 输入法运行库

| 组件 | 当前版本或来源 | 许可证 | 许可证与来源 |
| --- | --- | --- | --- |
| librime | 官方 Windows x64 1.13.1 运行库 | BSD-3-Clause | [rime/librime](https://github.com/rime/librime)，[许可证](third_party/licenses/librime-BSD-3-Clause.txt) |
| glog | librime 1.13.1 上游构建依赖 | BSD-3-Clause | [google/glog](https://github.com/google/glog)，详见[原生组件清单](native/许可证清单.md) |
| LevelDB | 由 librime 引入 | BSD-3-Clause | [google/leveldb](https://github.com/google/leveldb)，详见[原生组件清单](native/许可证清单.md) |
| yaml-cpp | 由 librime 引入 | MIT | [jbeder/yaml-cpp](https://github.com/jbeder/yaml-cpp)，详见[原生组件清单](native/许可证清单.md) |
| marisa-trie | 由 librime 引入，采用 BSD 许可选项 | BSD-2-Clause | [rime/marisa-trie](https://github.com/rime/marisa-trie)，详见[原生组件清单](native/许可证清单.md) |
| OpenCC | 由 librime 引入 | Apache-2.0 | [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC)，详见[原生组件清单](native/许可证清单.md) |
| Boost | 由 librime 引入 | BSL-1.0 | [Boost License](https://www.boost.org/LICENSE_1_0.txt)，详见[原生组件清单](native/许可证清单.md) |
| utf8cpp | 由 OpenCC 引入 | BSL-1.0 | [nemtrif/utfcpp](https://github.com/nemtrif/utfcpp)，详见[原生组件清单](native/许可证清单.md) |
| darts-clone | librime 与 OpenCC 内置副本 | BSD-3-Clause | 组件声明见 [原生组件清单](native/许可证清单.md) |
| RapidJSON / msinttypes | 由 OpenCC 引入 | MIT / BSD-3-Clause | 组件声明见 [原生组件清单](native/许可证清单.md) |
| X11 keysym headers | 仅使用键码定义 | The Open Group / Digital 原始许可 | 组件声明见 [原生组件清单](native/许可证清单.md) |
| Mozc | revision `7c1e06d39d6a8446e15a324700c48dcb00846039` | Google 自有代码为 BSD-3-Clause；所含第三方代码保留各自声明 | [google/mozc](https://github.com/google/mozc)，[许可证](third_party/licenses/Mozc-BSD-3-Clause.txt) |
| Zinnia | 0.06，revision `581faa8f6f15e4a7b21964be3a5ec36265c80e5b` | BSD-3-Clause | [taku910/zinnia](https://github.com/taku910/zinnia)，[许可证](third_party/licenses/Zinnia-BSD-3-Clause.txt) |

librime 官方二进制和仓库中的源码维护轨道不是同一份构建产物。上表按实际采用的 1.13.1
运行库及其上游构建依赖列出许可边界；维护者从其他 revision 重建时，必须按新产物重新
生成组件清单，不能直接沿用旧二进制的声明。

## 输入法数据与手写模型

| 内容 | 许可证 | 说明 |
| --- | --- | --- |
| Rime schema、词典与配置数据 | LGPL-3.0 | 固定来源和文件版本见 `third_party/data.lock.json`；[许可证](third_party/licenses/Rime-data-LGPL-3.0.txt) |
| Terra Pinyin 中引用的 CC-CEDICT 内容 | CC-BY-SA-3.0 | 保留原始署名和许可；具体来源见 `third_party/data.lock.json` |
| OpenCC 转换数据 | Apache-2.0 | 来源和数据归档见 `third_party/rime-opencc.lock.json` |
| Zinnia-Tomoe 中文、日文手写模型 | LGPL-2.1 | [许可证](third_party/licenses/Zinnia-Tomoe-LGPL-2.1.txt)；对应源模型见 `third_party/data.lock.json` |

许可证目录中的 GPL-3.0 文本用于补全 LGPL-3.0 所引用的条款；Kirakara-App 没有因此把
未使用的 GPL 仓颉词典或 schema 纳入运行包。

## 品牌素材与外部组件

`assets/branding` 中的应用图标和字标由项目所有者获授权用于 Kirakara-App，相关说明见
[品牌素材说明](assets/branding/素材说明.md)。这些美术资源不因仓库代码使用 MIT License
而自动成为 MIT 素材。

Kirakara Show 是单独构建和维护的项目，不属于本仓库的第三方源码。发布者如果将 Show
DLL 与 Kirakara-App 一起分发，应同时保留 Show 仓库及其依赖要求的许可证与声明。
