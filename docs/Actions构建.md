# GitHub 组合打包测试

目前所有工作都在三个仓库的 `Actions-Test` 分支中。它们不修改 main、不创建 Release，也不自动写回版本或构建请求。

```text
Show 仓库独立构建 DLL ─────┐
                         ├─ App 下载两份成功的附件 → 校验 → flutterw 构建 → ZIP
纯K助手仓库独立发布程序 ────┘
```

## 先准备两份依赖

分别修改 Show 和纯K助手的 `config/actions-build.json` 中的 `request`，推送到各自的 `Actions-Test` 分支。普通代码提交不会自动构建；请求值不用改回，每次使用一个新值即可。

等两边成功，再修改 App 的同名请求文件并推送。App 自己不会拉取 Show/助手源码，不会代替它们编译。

如果这几个分支尚未推送，GitHub 上不会运行任何构建。新增工作流还没进入默认分支时，GitHub 不提供其手动运行按钮，因此第一轮用请求文件的 push 触发，不为此改动 main。

## 选择哪次 Show 和助手构建

修改 `config/actions-dependencies.json`：

- `repository`、`branch`：产物所属仓库和分支。
- `workflow`、`artifact`：对应工作流文件名及附件名称。
- `runId`：填成功的 Actions 构建编号可以固定版本；`null` 使用指定分支最近一次成功构建。

App 在分配 Windows runner 前一次性确定两个构建编号、提交和附件 ID。随后只消费选定的附件，不在构建途中重新寻找「最新版」。缺失、失败、过期、分支不符、PR 构建、文件哈希不符都会明确停止，不换用旧附件或本地路径。每份附件保留 7 天。

跨仓库附件下载需要令牌。公开依赖先使用工作流自带 `GITHUB_TOKEN`；如受访问规则限制或依赖仍为私有仓库，在 App Actions secrets 中配置 `DEPENDENCY_ARTIFACTS_TOKEN`，仅授权两个依赖仓库的 Actions 读取权限。不要把令牌或本机 SSH 密钥写进配置文件。

## 云端需要能下载运行包

本机 `.kfe` 不会上传或复制到 GitHub。正式云端构建要求以下锁文件已填写现有、已验证预编译包的 HTTPS 地址、哈希和大小：

- `native/prebuilt.lock.json` 的 `imeRuntime`。
- `third_party/data.lock.json` 的 `zinniaTomoe.binaryPackage` 和 `rime.dataPackage`。

测试分支已配置这三份现成运行包，和 Flutter Engine 一起存放在已有的 `Flutter-engine-mod` 依赖 Release 中，不代表 App 正式发版。以后如缺少地址或校验值，干净云端构建会在 Linux 准备阶段给出缺项清单，不分配 Windows 构建任务，不临时从源码构建输入法。

App 使用带 VS 2026 的 Windows runner。现有非 LTCG Zinnia 静态库允许同一 MSVC 19.51 系列中不低于生产版本的补丁版；生产工具链的精确版本和产物哈希仍保留在锁文件中。不接受旧编译器、其他编译器系列、x86 或 ARM64。

## 测试产物与以后发版

App 的附件 `kirakara-app-windows-x64-test` 包含 ZIP、SHA-256 以及依赖来源记录。目前只验证构建和组合打包，不创建标签、Release 或预发行版。

测试分支中，修改 `config/package.json` 的 `version` 也会触发打包。只修改名称或开发者、版本和请求值都没变时，不启动 Windows 构建。正式上线后再将触发分支改为 main，并接上 Release 发布步骤；本轮不启用。

本地逻辑回归：

```powershell
node --test tool/ci/actions.test.mjs
```

也可以消费两边已生成的附件目录，在本机完整组合打包：

```powershell
.\tool\ci\package-local-artifacts.ps1 -ShowDirectory <Show附件目录> -HelperDirectory <助手附件目录>
```

这个入口不编译两份依赖，只校验和打包。本机已有 `.kfe` 可以继续复用，因此它不能替代云端干净环境的验收。

正常本地开发仍使用 `flutterw` 和 `config/kirakara.local.json`，本方案不改变 Show 的独立开发或现有 App FFI。
