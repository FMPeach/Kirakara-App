# Kirakara Flutter Engine 管理

这里保存锁文件、可审查补丁、构建和校验脚本，不保存上游源码、DLL、LIB、PDB 或构建缓存。
官方 Flutter 是只读上游；准备出的 SDK、源码、产物均位于当前仓库 `.kfe`。

## 来源与许可

Framework、Engine、Dart、GN/Ninja 及必要 MSVC/Windows SDK 构建输入由
`engine.lock.json` 记录。行为补丁在 `patches`，源码工具适配在 `bootstrap`。
`licenses` 保存对应上游声明；`include/LICENSE` 适用于 Flutter 派生 ABI 头文件。
Kirakara 自有管理脚本采用根 MIT；不能因此把 Flutter 派生内容改标 MIT。

## 两条准备路径

- 普通协作者：`flutterw` 按需安装经过校验的预编译包，不运行 GN/Ninja。
- Engine 开发者：显式 `flutterw engine prepare debug --from-source` 才进入源码构建。

预编译 URL 只来自 `prebuilt.lock.json`。Windows x64 的 Debug、Profile、Release v5
已配置为 GitHub Release 资产；下载后会校验大小、ZIP SHA-256、manifest、构建身份与
ABI。下载或校验失败时明确退出，不会自动改走几十 GB 的源码构建。维护者仍可使用
候选锁和本地 ZIP 验证尚未发布的新包。

本地解包目录只使用完整身份 SHA-256 的前 8 位作为路径别名，以控制 Windows 深层
Flutter/Dart 资源的完整路径长度。正式锁、包 manifest、选择状态、`ready.json`、下载
哈希和安装并发锁始终保存并校验完整 64 位身份；短目录名不参与信任判断。

`fetch_engine.ps1`、`apply_patches.ps1`、`build_windows_engine.ps1` 和验证脚本用于显式
源码开发。写操作只进入当前仓库 `.kfe`；stock 构建与 external texture 对照路径继续
保留，图形修改仍需实际运行验证。

完整流程见 [Flutter Engine 开发指南](../docs/Flutter-Engine开发指南.md)。
