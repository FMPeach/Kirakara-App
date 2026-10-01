# Flutter Engine 修改声明

Kirakara 自有脚本采用根 MIT；Flutter/Engine 及其派生文件保留 Flutter BSD-3-Clause。
这份说明不将 Dart、Skia、ICU 或其他上游组件改标为 MIT。

基线由 `engine.lock.json` 锁定：Flutter Framework 3.44.4，Engine revision
`a10d8ac38de835021c8d2f920dbf50a920ccc030`，合成器 ABI 2、补丁版本 5。
`host_*_kirakara_v4` 是保留的 output 目录标签，不是当前补丁版本声明。

## 行为补丁

1. `0001-windows-dcomp-stage-visual-compositor.patch`：Windows DirectComposition
   双 Visual，Flutter 为带 Alpha 的上层；独立 Stage 更新、共享资源同步、geometry/fit/clip、
   生命周期和版本化 ABI。保留 stock Engine 的普通路径与 external texture 对照。
2. `0002-windows-clipboard-contention.patch`：独立的 Windows 标准 Clipboard API
   异步、有总时限的争用重试。不是 compositor 的一部分，不记录剪贴板内容。

## 仓库内构建补丁

`bootstrap/0001` 与 `0003` 处理 vpython/virtualenv Windows codepage 与 Unicode 路径；
`0002` 允许 output 独立于源码；`0004`/`0005` 处理 GN/Ninja 的 Unicode 路径；
`0006` 处理 shader archive 路径；`0007` 为 Dart gen_snapshot Windows Unicode 参数。
这些补丁只应用到当前仓库 `.kfe/source` 的锁定来源，官方/系统 SDK 不被修改。
GN 保留 BSD，Ninja 保留 Apache-2.0，其他派生上下文保留各自上游许可。

## 构建与分发方式

预编译优先；源码构建仍保留为显式 `--from-source` 路径。
安装器和锁文件改变获取方式，不新增 compositor 行为修改或改变播放业务语义。
每个模式的包提供 DLL、EXP、import library、公共头、wrapper、ICU、Dart SDK、patched SDK、
shader/字体工具和许可证；PDB 独立，不默认下载。字体裁剪使用同 revision 的 stock SDK
辅助工具并单独记录哈希，不能将其它版本的 snapshot 混入包。

包格式 v2 补齐 Flutter Windows 解包阶段需要的 EXP。独立的 `flutter-tools/0001`
仅允许 local-engine 缺少可选 PDB；stock Engine 维持原检查，local-engine 显式拒绝
PDB 链接/目录，其它必需文件不能缺失。
工具补丁在 `.kfe/source/sdk-tools` 的官方源码派生副本应用，保留 BSD 许可，并锁定完整
补丁树和 Dart 编译器。新工具 snapshot 由源码编译生成，仅安装到仓库 SDK 的生成缓存，
不是二进制 Patch；官方 SDK 已跟踪源码和系统 SDK 不被改写。这个轻量工具编译不是
Flutter Engine 全量源码构建，也不触发 GN/Ninja。

`prebuilt.lock.json` 已锁定 Windows x64 三种模式的 v5 GitHub Release 地址、大小、
ZIP/manifest 哈希与构建身份。本地候选包测试不自动取得正式发布身份；后续替换资产时
仍须更新全部可信字段。派生 Engine 二进制随包携带本说明、锁定来源/补丁和完整上游
许可证声明。
