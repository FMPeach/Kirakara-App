# 第三方数据与许可证

本目录保存输入法数据和手写模型的来源锁、许可证文本、必要补丁及维护脚本。生成的 DLL、
静态库、模型、词库和完整上游源码不会提交到 Git；它们由仓库内脚本下载、校验并安装到
当前项目的 `.kfe`。

Kirakara-App 自有代码使用 MIT License，第三方组件仍按各自许可证分发。面向发布者的
完整清单见根目录的 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

## 目录内容

- `data.lock.json` 锁定 Rime 数据与 Zinnia-Tomoe 手写模型的来源、版本和哈希。
- `rime-opencc.lock.json` 锁定 OpenCC 转换数据及其来源归档。
- `licenses/` 保存随运行包分发的许可证与声明文本。
- `scripts/` 提供来源准备、数据制包和包校验入口。

## 主要组件

| 组件或数据 | 用途 | 许可证 |
| --- | --- | --- |
| Rime schema、词典与配置 | 中文输入方案 | LGPL-3.0 |
| CC-CEDICT 引用内容 | Terra Pinyin 词典数据 | CC-BY-SA-3.0 |
| OpenCC 数据 | 简繁转换 | Apache-2.0 |
| Zinnia-Tomoe 模型 | 中文、日文手写识别 | LGPL-2.1 |
| Zinnia | 手写识别运行库 | BSD-3-Clause |
| librime 及其依赖 | Rime 输入法运行库 | 组件各自许可证，详见 `native/许可证清单.md` |
| Mozc | 日文输入 | Google 自有代码为 BSD-3-Clause，所含第三方代码保留各自声明 |

许可证目录中随 LGPL-3.0 一并保留的 GPL-3.0 条款文本，不代表运行包包含未使用的 GPL
仓颉词典或 schema。当前运行配置排除了 `cangjie5` 和 `cangjie5_express`，其他启用方案
仍保留原始来源及许可边界。

## 维护来源

普通 App 开发不需要运行本节命令。更新输入法数据或准备发布包时，应从仓库根目录使用
锁定来源：

```powershell
.\third_party\scripts\prepare_rime_data_sources.ps1
.\third_party\scripts\test_rime_data_sources.ps1
.\native\scripts\reproduce_handwriting_models.ps1
.\native\scripts\test_input_method_sources.ps1
```

这些脚本只在当前仓库的 `.kfe` 中工作。发现来源 revision、哈希、许可证或工作树状态不
匹配时会停止，不会替维护者重置上游源码。

## 制作数据包

准备并校验来源后，可以制作候选包：

```powershell
.\third_party\scripts\make_handwriting_package.ps1 `
  -OutputDirectory .\build\packages\handwriting

.\third_party\scripts\make_rime_data_package.ps1 `
  -OutputDirectory .\build\packages\rime-data `
  -Offline
```

候选 ZIP 和候选锁应当成对测试。它们是构建产物，不应直接提交进仓库。原生 DLL、Mozc
桥接和其他运行库的维护方式见 [原生依赖说明](../native/README.md)。

更新任何第三方版本或来源时，还应同步更新对应锁文件、许可证文本和根目录的
`THIRD_PARTY_NOTICES.md`，并确认最终 Windows Release 仍包含 Flutter 生成的
`data/flutter_assets/NOTICES.Z`。
