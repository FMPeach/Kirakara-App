# 随包工具

纯K助手安装在发行目录的 `tools/ChunKHelper/`，入口为 `ChunK Helper.exe`。该目录可包含单文件或多文件发布产物，不能在多文件发布时只复制 EXE。

助手在 [ChunK-Helper](https://github.com/FMPeach/ChunK-Helper) 独立开发。先在助手仓库运行 `tools/publish-windows.ps1`，再把 App 本机配置 `windows.chunkHelperDirectory` 指向它的发布目录；也可用进程环境变量 `KIRAKARA_CHUNK_HELPER_ROOT` 临时指定。

`flutterw run/build windows` 会将已配置的工具复制到构建输出目录，不下载或编译助手，也不修改助手仓库。没有配置工具时开发构建仍可运行，点击“纯K助手”会提示缺少文件；完整发行包需要带上工具。

EXE、DLL 和生成的运行时文件不提交到 Git。工具中的许可证和第三方声明与它一起分发。
