# 目前APP尚未上线，上线之前将无法使用任何功能，请期待后续上线。

# Kirakara-App

Kirakara 是基于 Flutter 的 KTV 点歌与播放控制应用，Windows 预览通过定制 Flutter
Engine 和 DirectComposition 将 Show Stage 与 Flutter UI 分开呈现。

## 功能特性

- **近似KTV的操作体验** — 界面以国内KTV操作屏逻辑做优化，用户操作更方便
- **内置输入法** — 点歌页面右侧内置输入法，拼音、手写、罗马音输入不在话下
- **播放高清且流畅** — 曲库内歌词60帧走字，外链点歌登陆后支持最高4K画质
- **手机点歌** — 扫描手机点歌二维码，外链、点歌更方便
- **有线双屏** — 插入大屏显示器，大屏自动显示MV和歌词，小屏仍可以点歌
- **无线投屏** — 连接DLNA设备，即可投放画面到大屏，无线更方便
- **队列管理** — 支持点歌、顶歌、删除等操作，掌控全局更舒服

## 开发环境

Kirakara-App 当前主要面向 Windows x64 开发。

开始前请准备：

- Windows 10 或 Windows 11 x64
- PowerShell 7.2 或更新版本（`pwsh`）
- Visual Studio，并安装“使用 C++ 的桌面开发”工作负载
- Windows SDK 与 CMake
- 可正常访问项目依赖的网络环境和足够的磁盘空间

项目通过仓库内的 `flutterw` 启动和构建，通常不需要预先安装全局 Flutter SDK。
参与项目的基本流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。
如果需要修改 Flutter Engine，请参阅
[Flutter Engine 开发指南](docs/Flutter-Engine开发指南.md)。

## 使用方式

### 直接运行

在 Release 下载最新版本，解压后双击 kirakara_app.exe 即可使用。

### 从源码运行

Clone 本仓库后

```powershell
cd Kirakara-App
.\flutterw pub get
.\flutterw run -d windows
```

### 从源码构建

Clone 本仓库后

```powershell
cd Kirakara-App
.\flutterw pub get
.\flutterw build windows --release
```

### 从修改Flutter开始编译构建

见 [Flutter Engine 开发指南](docs/Flutter-Engine开发指南.md)。

## Todo

- [ ] 大屏显示报幕、二维码等Overlay
- [ ] 更美观的界面


## LICENSE

Kirakara-App 自有源代码采用 [MIT License](LICENSE)；
Flutter Engine 补丁、预编译 Engine 和第三方组件仍适用其各自上游许可证，见[第三方许可证说明](THIRD_PARTY_NOTICES.md)。
