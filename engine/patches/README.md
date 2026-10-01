# Windows 自定义 Flutter Engine 补丁栈

`engine.lock.json` 保留无 Kirakara 行为修改的 stock 基线，以及 v5 的有序补丁栈：

1. `0001-windows-dcomp-stage-visual-compositor.patch`：版本化 ABI、预乘 Alpha 的
   Flutter 上层 Visual、独立 Stage Visual、最新完成帧消费、原位 resize、首帧前黑色
   Stage 占位与计数诊断。不恢复 Stage 子 HWND 叠加方案。
2. `0002-windows-clipboard-contention.patch`：独立剪贴板轨道，保留标准 Clipboard API。
   仅短暂 `ERROR_ACCESS_DENIED` 使用临时 16 ms 消息定时器；16 次或 250 ms 总限额，
   最多 1 Mi UTF-16 code units，退出时取消挂起请求，不记录内容。

补丁路径、SHA-256 和应用后的精确 Git tree 都被锁定。应用前执行 `git apply --check`，
偏移或额外修改导致失败；不直接编辑系统 Flutter SDK 或编译后的 DLL。
`bootstrap` 只处理源码工具链适配，不混入剪贴板或合成器行为补丁。

`flutter-tools` 是开发包兼容轨道：只使 local-engine 的 PDB 可选，保留官方
Engine 的原检查。它应用于仓库内派生工具副本，不修改官方 SDK 源码，也不改变 Engine
ABI 或播放语义；补丁适用性、应用后的精确树和编译器由 `engine.lock.json` 单独锁定。

窗口生命周期和 VFR 门控位于 Runner。设备丢失和实体机兼容性仍以实际测试为准，
安装器测试不能替代图形硬件验收。
本目录基于 Flutter 上游形成的派生补丁适用上游 BSD-3-Clause，保留版权头及修改说明。
二进制、符号和完整源码不进入普通 Git 历史。
