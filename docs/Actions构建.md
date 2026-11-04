# GitHub 组合打包测试

工作流默认在 main 使用，`Actions-Test` 可用于测试。构建不会自动写回版本或构建请求；App 自己目前只生成便携包附件，不自动创建 Release。

```text
Show 仓库独立构建 DLL ──────────┐
                             ├─ App 下载并校验 → flutterw 构建 → ZIP
纯K助手 Actions 构件 / Release ─┘
```

## 先准备两份依赖

分别在 Show 和纯K助手的 main 修改 `config/actions-build.json` 中的 `request` 并推送，或在 Actions 中点击 **Run workflow**。纯K助手修改 `config/package.json` 后推送也会自动构建。普通代码提交不会自动构建；请求值不用改回，每次使用一个新值即可。

等两边成功，再修改 App 的同名请求文件并推送。App 自己不会拉取 Show/助手源码，不会代替它们编译。

App 默认消费两个仓库 main 分支的最新成功构建，不追随尚未构建的源码提交。要测试其他分支的组件，可修改下面的依赖配置。

## 选择哪次 Show 和助手构建

修改 `config/actions-dependencies.json`：

- `repository`、`branch`：产物所属仓库和分支。
- `workflow`、`artifact`：对应工作流文件名及附件名称。附件名支持 `*` 匹配任意字符，但必须且只能匹配到一份附件；助手默认使用 `*-windows-x64`，兼容带版本的下载文件名。
- `releaseFallback.asset`：只用于纯K助手。最新 Actions 构件缺失或过期时，从最新一份含有匹配资产的非草稿 Release 取包。
- `runId`：填成功的 Actions 构建编号可以固定版本；`null` 使用指定分支最近一次成功构建。

App 在分配 Windows runner 前一次性确定依赖。Show 始终严格使用选定的 Actions 构件；纯K助手优先使用最新 Actions 构件，仅当它不存在或已经过期时才退到 Helper 仓库的 Release。显式填写 `runId` 时不会退回 Release，失败构建、分支不符、PR 构建和身份或哈希不符也不会被兜底掩盖。

Actions 构件仍按工作流设置保留 7 天，便于查看单次构建；Helper Release 资产不会按这个期限自动过期。Release ZIP 的大小和 GitHub SHA-256 会在解压前核对，解压后仍执行原有组件清单、文件哈希、入口和 x64 检查。Show 的选择和下载方式没有改变。

跨仓库 Actions 构件和 Release 资产下载需要令牌。公开依赖先使用工作流自带 `GITHUB_TOKEN`；如受访问规则限制或依赖仍为私有仓库，在 App Actions secrets 中配置 `DEPENDENCY_ARTIFACTS_TOKEN`，仅授权两个依赖仓库的 Actions 与 Release 读取权限。不要把令牌或本机 SSH 密钥写进配置文件。

## 云端需要能下载运行包

本机 `.kfe` 不会上传或复制到 GitHub。正式云端构建要求以下锁文件已填写现有、已验证预编译包的 HTTPS 地址、哈希和大小：

- `native/prebuilt.lock.json` 的 `imeRuntime`。
- `third_party/data.lock.json` 的 `zinniaTomoe.binaryPackage` 和 `rime.dataPackage`。

仓库已配置这三份现成运行包，和 Flutter Engine 一起存放在已有的 `Flutter-engine-mod` 依赖 Release 中，不代表 App 正式发版。以后如缺少地址或校验值，干净云端构建会在 Linux 准备阶段给出缺项清单，不分配 Windows 构建任务，不临时从源码构建输入法。

App 使用带 VS 2026 的 Windows runner。现有非 LTCG Zinnia 静态库允许同一 MSVC 19.51 系列中不低于生产版本的补丁版；生产工具链的精确版本和产物哈希仍保留在锁文件中。不接受旧编译器、其他编译器系列、x86 或 ARM64。

## 测试产物与以后发版

App 只上传一份以实际版本命名的便携 ZIP，例如 `Kirakara-v0.1-Beta-windows-x64.zip`。附件上传关闭二次归档，下载后解压一次即可看到根目录的 `kirakara_app.exe`、DLL、`data/` 和 `tools/`，不再套 ZIP 或 `Kirakara-App/` 目录。校验值与依赖来源可在 Actions 日志和摘要查看，不额外打进下载附件。

本地 `tool/package_windows.ps1` 生成的也是同一种根目录结构。以后正式 Release 直接上传这份 ZIP 原文件，不使用「下载全部 Actions 附件」得到的汇总包。目前测试流程不创建标签、Release 或预发行版。

在 main 或 `Actions-Test` 修改 `config/package.json` 的 `version` 也会触发打包。只修改名称或开发者、版本和请求值都没变时，不启动 Windows 构建。正式 Release 的自动发布步骤尚未启用；启用后仍直接发布同一种便携 ZIP。

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
