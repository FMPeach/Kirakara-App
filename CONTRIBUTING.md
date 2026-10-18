# 参与 Kirakara-App

欢迎参与 Kirakara-App。无论是修复问题、改善界面、补充测试、完善文档，还是研究播放与
渲染，都可以从自己感兴趣的部分开始。

## 准备项目

先确认电脑具备[开发环境](docs/开发环境.md)，然后克隆仓库：

```powershell
git clone git@github.com:FMPeach/Kirakara-App.git
cd Kirakara-App
```

Windows 版需要由 Kirakara Show 提供播放和渲染能力。复制本机配置模板，并把
`windows.showHostDll` 改为本机编译出的 `libshow_host.dll` 绝对路径：

```powershell
Copy-Item .\config\kirakara.local.example.json `
  .\config\kirakara.local.json
```

这个配置只属于当前电脑，不会提交到 Git。

需要测试“纯K助手”入口时，先在 [ChunK-Helper](https://github.com/FMPeach/ChunK-Helper)
仓库发布工具，将 `windows.chunkHelperDirectory` 指向发布目录。构建时会复制到
`tools/ChunKHelper/`；
助手为独立开发，只参与其他功能开发时可省略这个配置。

准备依赖并运行应用：

```powershell
.\flutterw pub get
.\flutterw run -d windows
```

项目仍在开发中。如果某项运行资源尚未公开，可以先参与不依赖完整播放链路的部分，或在
Issue 中说明想要调试的功能。

使用 VS Code 时，从“终端 → 运行任务”选择
“Kirakara：运行 main.dart（flutterw）”；也可以直接按 `Ctrl+Shift+B`。仓库关闭了
`main.dart` 上方由 Dart 扩展提供的默认 Run/Debug 链接，避免它绕过 `flutterw` 调用全局
Flutter。仓库的 VS Code 设置也会固定 Windows 运行目标，并隐藏移动设备和模拟器入口；
当前版本不支持 Android 构建。

## 打包 Windows 版本

应用名称、版本和开发者在 [`config/package.json`](config/package.json) 中修改。
窗口标题、关于页和 EXE 文件属性会一起更新。`version` 可以直接写成 `v0.1 Beta`，
程序和 Windows 文件属性都会原样显示。构建时会自动提取开头的数字版本，
例如 `v0.1 Beta` 对应内部数字版本 `0.1.0.0`，无需另填一份配置。

```powershell
.\tool\package_windows.ps1
```

脚本通过 `flutterw` 构建 Release，随后生成 ZIP，默认放在 `build/releases`。
临时指定版本可加 `-Version 'v0.2 Beta'`，不会改配置文件。
Flutter 的 `--build-name` / `--build-number` 只覆盖内部数字版本，不改显示文字。
打包前先发布纯K助手，并在本机配置中填好它的产出目录；Show 仍单独构建。
版本包只收安装清单里的运行文件，不收本机设置、账号状态和日志。

## 开始改动

从一个独立分支开始会比较轻松。尽量让一次改动围绕同一个问题展开，这样更容易测试，
也方便其他人理解。如果修改了界面，附上一张前后对比图通常很有帮助；如果修复了问题，
也可以顺手补一个能覆盖它的测试。

普通 Flutter 和 Dart 改动直接使用 `flutterw`。需要修改定制 Flutter Engine 时，请先看
[Flutter Engine 开发指南](docs/Flutter-Engine开发指南.md)，避免把大型生成内容提交进仓库。

## 提交前看看结果

根据改动范围运行相应检查即可。常用命令包括：

```powershell
.\flutterw analyze
.\flutterw test
.\flutterw build windows --debug
```

涉及播放、投屏、双屏或输入法的改动，最好再实际操作一次相关流程。仓库现有提交以简洁的
中文说明为主，沿用这种风格即可。

## 提交 Pull Request

在 Pull Request 中简单说明改了什么、为什么要改，以及自己怎样验证过就足够了。如果它
对应已有 Issue，可以一并关联；尚未验证的部分也可以直接写出来，方便后续接着确认。

Kirakara-App 自有代码采用 [MIT License](LICENSE)。引入第三方代码、素材或数据时，请保留
来源和原有许可证；现有依赖说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
