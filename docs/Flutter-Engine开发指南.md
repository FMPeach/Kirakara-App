# Flutter Engine 开发指南

Kirakara-App 在 Windows 上使用定制 Flutter Engine。普通界面和业务开发直接运行`flutterw` 即可，只有需要修改合成器、Windows Embedder 或剪贴板等 Engine 层能力时，才需要进入源码流程。

## 认识仓库中的 Engine 文件

- `engine/engine.lock.json` 记录 Flutter、Engine、Dart、工具链和补丁版本。
- `engine/patches/` 保存 Kirakara 对上游 Engine 的有序修改。
- `engine/MODIFICATIONS.md` 说明这些修改带来的行为变化。
- `engine/prebuilt.lock.json` 记录已经发布的预编译包。
- `.kfe/` 保存当前仓库使用的 SDK、源码和构建产物，不进入 Git。

源码、构建缓存和二进制产物都留在 `.kfe`，Git 中只保存能够审查和重现修改的补丁、脚本与版本记录。

## 准备源码环境

先安装[开发环境](开发环境.md)，并为 Flutter Engine 源码和构建输出预留足够空间。然后在仓库根目录运行：

```powershell
.\flutterw --version
.\flutterw engine doctor --from-source
.\flutterw engine prepare debug --from-source
```

第一条命令准备项目使用的 Flutter SDK，第二条检查源码构建环境，第三条取得锁定的上游源码、应用仓库中的补丁并构建 Debug Engine。需要 Profile 或 Release 时，将 `debug`换成对应模式即可。

定制源码位于 `.kfe/source/flutter`，Engine 主体位于其中的 `engine/src`；各模式的构建结果位于 `.kfe/out`。这些目录都可以重新生成，不需要提交。

## 修改 Engine

先在定制源码中完成修改和本地验证，再把改动整理成一个职责清楚的补丁，放入`engine/patches/`。行为不同的修改尽量使用不同补丁，后续升级 Flutter 时会更容易定位冲突。

补丁完成后，同步更新 `engine/engine.lock.json` 中的补丁顺序、SHA-256、应用后源码树和相关 ABI；如果外部可见行为发生变化，也要更新 `engine/MODIFICATIONS.md`。随后从锁定状态重新执行源码构建，确认补丁可以在干净上游源码上应用。

修改 Engine 后至少应重新构建受影响的模式，并运行与改动相关的测试。涉及合成器、窗口
缩放、双屏、剪贴板或显卡兼容性的修改，编译后务必在真实 Windows 设备上观察确认。

## 制作预编译包

确认源码构建和 App 联调正常后，可以从对应模式的输出制作候选包：

```powershell
.\engine\scripts\make_prebuilt_engine.ps1 `
  -Mode debug `
  -SourceOutput .\.kfe\out\host_debug_kirakara_v4 `
  -FlutterSdkRoot .\.kfe\sdk `
  -OutputDirectory .\build\packages\candidate
```

Profile 和 Release 使用各自的模式与输出目录。制包脚本会同时生成 ZIP 和候选锁；候选包不会自动替换正式下载配置，也不会进入 Git。

发布前可以运行：

```powershell
.\engine\scripts\test_prebuilt_security.ps1
.\engine\scripts\test_prebuilt_download.ps1
.\engine\scripts\test_prebuilt_concurrency.ps1
.\engine\scripts\test_flutter_sdk_tools.ps1
.\engine\scripts\test_prebuilt_flutter_app.ps1 `
  -PackagesDirectory .\build\packages\candidate
.\engine\scripts\test_prebuilt_clean_clone.ps1 `
  -PackagesDirectory .\build\packages\candidate
```

这些检查覆盖包完整性、安全解压、并发安装、三种构建模式以及独立克隆恢复。图形效果、输入法和实际播放仍要在完整 App 中单独确认。

## 发布新的 Engine

测试通过后，将三种模式的 ZIP 上传到仓库 Release，并把最终 URL、文件大小、ZIP SHA-256、manifest SHA-256 和构建身份写入 `engine/prebuilt.lock.json`。提交前再从没有本地候选状态的环境下载一次正式地址，确认 Debug、Profile 和 Release 都能被 `flutterw`正确选择。

发布包需要保留 Flutter、Dart、Skia、ICU 以及其他上游组件的许可证和 NOTICE。
Kirakara自己的补丁不会改变上游代码原有的许可证，具体清单见[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
