# 原生依赖边界

只跟踪来源锁、Kirakara 桥接、补丁、构建和测试；上游源码与二进制留在 `.kfe`。
普通 Windows run/build 只消费经过清单校验的 IME 预编译包，不读取 `.kfe/source`，
也不会启动 librime、Mozc 或 Zinnia 的源码构建。Show 始终是独立外部输入。
原生包由 `native/prebuilt.lock.json` 选择；缺少可用包时会明确失败，不会隐式回退到源码
构建。

## 维护者：Rime 固定源码构建

PowerShell 7.2+、Git、Windows C++ 桌面工具已安装后：

```powershell
.\native\scripts\prepare_librime_sources.ps1
.\native\scripts\build_librime.ps1 -Jobs 8
.\native\scripts\probe_librime.ps1
```

build 也会调用准备入口，首条可单独用于检查/获取。离线时给准备或 build 加 `-Offline`，
缺输入直接失败。只获取 `native.lock.json` 的固定 librime 与四个构建依赖，禁用外部
插件和日志依赖；不默认初始化 glog/googletest 或引入旧 GPL 插件。

OpenCC 和 librime 共用固定 `deps/marisa-trie` 构建的库和头文件。OpenCC 上游
`USE_SYSTEM_MARISA` 选项虽为 ON，实际目标由本仓库 CMake 接线指定，只来自
`.kfe/native/librime-deps`，不搜索系统库。构建检查 OpenCC 安装没有覆盖 marisa，
并逐文件检查全部 30 份 OpenCC 数据；异常即停止，不重写数据锁来迎合输出。
构建后可执行 `test_librime_dependency_contract.ps1`，核实实际缓存、库和 12 份头文件，
以及错误目录/旧缓存/重复目标的拒绝行为。

Boost 只解压官方锁定源包的头文件和 BSL-1.0，不提取带 Windows 非法文件名的测试。
现有头文件逐内容与官方源包核验；已有源码 revision、内容或 generator 不符时停止，
不重置/清理用户修改。编译输出、依赖安装和临时环境均限定仓库 `.kfe`，退出恢复环境。

这条源码轨道只供维护者复现和升级，不决定普通运行包身份。普通 IME 包固定使用
librime 1.13.1 官方 Windows x64 Release 资产：压缩包 SHA-256
`05FCF8CC2D058A0186DD9F04D6E021AD41687DB50DC81E85CF655DFABFDF0009`，
其中 `rime.dll` SHA-256
`2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B`。
探测只验证 x64、Runner 所需导出、可加载和 API 表；不初始化用户会话，不算 App 拼音
输入验收。完整字典和对应许可来自独立 `third_party/data.lock.json`，不会由 DLL 替代。

准备上述独立数据包之后可以执行运行探测：

```powershell
.\native\scripts\probe_rime_runtime.ps1 -CandidateLock .\build\packages\rime-data\rime-data.candidate.lock.json
```

此测试先验证数据包和本地 DLL 的来源记录，再启动有总时限的隐藏子进程；使用独立
`.kfe/tmp/rime-runtime-test-*` 用户目录部署词典，不访问真实 AppData、用户输入或剪贴板。
检查七个方案可选择、固定拼音候选和 OpenCC 简化输出、正常释放及数据包部署后未被修改。
结果不记录候选文本，也不代替 App UI 测试。失败/超时保留该临时目录诊断，不计通过。
运行探测也要求 DLL 来源记录中的固定 marisa revision、库哈希和 CMake 接线哈希匹配；
旧来源记录缺字段时明确要求重建，不默默接受此前混用两份 marisa 的 DLL。

## 其余依赖

Zinnia 的小型官方库源码有独立恢复入口，供原生维护/构建使用；与下载 LGPL 手写模型
分别处理，不默认启动大型 Flutter Engine 构建：

```powershell
.\native\scripts\prepare_zinnia_sources.ps1
.\native\scripts\prepare_zinnia_sources.ps1 -Offline
.\native\scripts\test_zinnia_sources.ps1
```

只写入当前 `.kfe`，新目录先完整核验再原子安装；已有源码的错误 remote/HEAD、用户
修改、未跟踪文件或 Git 元数据联接明确拒绝，不 checkout/reset 或清理。22 份顶层
C++/头文件及原始 BSD 许可按固定 Git 内容核验，允许正常 CRLF/LF 文本转换，但不会
接受 `assume-unchanged` 隐藏的改动。模型复现脚本复用此入口，仍须实际转换并核对两个
模型的 SHA-256；来源准备通过本身不代表模型复现或 App 手写 UI 通过。

核验阶段使用 Git 的 `--no-lazy-fetch`，缺失的部分克隆对象不会隐式联网恢复；现有损坏
缓存立即报错，不下载或覆盖。按能力检查 Git 是否支持该参数，不锁死某个 Git 版本，
也不自动替换系统工具；参数含义见 [Git 官方说明](https://git-scm.com/docs/git#Documentation/git.txt---no-lazy-fetch)。
显式非离线准备只在来源目录尚不存在时获取源码，验证命令不刷新 Git 索引。

手写模型复现/包制作与安装见 [third_party](../third_party/README.md)。Zinnia 库与模型
许可证分别处理，不禁用手写。
Mozc 桥接和 Bazel 目标保留为维护者源码入口；普通流程只消费锁定哈希的现有桥接
可执行文件，不启动 Bazel。Rime 源码构建与普通 IME 预编译包是两条独立轨道。

Zinnia 预编译库只能由显式维护者命令重建：

```powershell
.\native\scripts\build_zinnia_prebuilt.ps1
```

它先以最小 `__FILE__` 样例验证 MSVC `/pathmap`，再从锁定 revision
`581faa8f6f15e4a7b21964be3a5ec36265c80e5b` 在两个不同真实目录构建。Debug 固定
v145 `/MDd`，Release 固定 v145 `/MD`，Profile 明确复用 Release；两次库必须逐字节
一致且完整 `.lib` 不含宿主机路径。产物仅留在 `.kfe`，不做二进制改写。

用现有且哈希匹配的三类产物生成 staging：

```powershell
.\native\scripts\install_verified_native_runtime.ps1 `
  -RimeReleaseArchive .\.kfe\downloads\rime-1c23358-Windows-msvc-x64.7z `
  -MozcBridge .\.kfe\native\runtime\ime\mozc\windows\runtime\kirakara_mozc_bridge.exe `
  -ZinniaPrebuiltRoot .\.kfe\native\zinnia-prebuilt-v1
```

该入口只校验并组合已有产物：Rime 做资产与 DLL 两级哈希，Mozc 做 x64 与固定日语
候选探针，Zinnia 做 x64 COFF、CRT、完整路径扫描与哈希；不编译任何上游项目。

为无源码的干净 clone 制作本地候选包：

```powershell
.\native\scripts\make_native_runtime_package.ps1 `
  -OutputDirectory .\build\packages\ime-runtime
.\flutterw native prepare `
  --package .\build\packages\ime-runtime\kirakara-ime-runtime-windows-x64-v2.zip `
  --lock .\build\packages\ime-runtime\ime-runtime.candidate.lock.json
```

包安装到 `.kfe/prebuilt/ime-runtime/<identity>`，Windows CMake 只通过当前
`flutterw` 子进程的 `KIRAKARA_NATIVE_RUNTIME_ROOT` 使用它，不写 PATH、注册表或
全局缓存。包只含 Rime/Mozc 运行二进制、Zinnia Debug/Release 静态库与头文件、
来源身份及对应许可证；不含 Show、模型、Rime 数据、源码、PDB、OBJ 或缓存。下载条目
未配置或不可用时，缺包直接失败，不会隐式重编三个上游项目。

Show 不属于这个包。Windows `run/build` 从 Git 忽略的仓库本机配置
`config/kirakara.local.json` 读取外部 DLL 绝对路径；显式参数和进程环境变量
`KIRAKARA_SHOW_HOST_DLL` 可覆盖配置。App 先验证外部 DLL 的 x64 PE、导出和 Stage
Visual ABI，再准备 Engine、IME 与数据，并只在本次构建中复制进 bundle。`pub get`
不检查 Show；App 不会自行写入配置、用户环境或系统环境，也不下载或构建 Show。

## 运行库声明

当前原生运行组件及其许可证见[许可证清单](许可证清单.md)。维护者从源码重建 librime
时，可用 `prepare_librime_notices.ps1` 在 `.kfe` 准备与该源码产物对应的原始声明；
手写模型和 Rime 数据包的许可证仍分别处理。
