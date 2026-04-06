# Murmur

macOS 桌面语音输入工具。按住热键说话，松键后识别结果自动打到当前光标位置，全程无需切换应用。

## 功能

- **Push-to-Talk**：按住热键录音，松键触发识别，结果直接插入当前光标
- **Siri 风格波形**：录音期间浮窗显示平滑波形动画，不抢焦点
- **LLM 归整**（可选）：识别后调 LLM 去语气词、修正同音错字
- **历史记录**：所有识别结果持久化，支持手动修正，记录原文与修正版本
- **热词库**：支持火山引擎自学习平台热词，AI 可从历史修正中自动提取建议词
- **使用统计**：30 天用量折线图、时段分布、修正率等报表
- **鼠标键映射**：可将鼠标侧键映射为 Enter 键

## 热键

`Right/Left Option`、`Right/Left Control`、`CapsLock`、`F13–F15`、鼠标中键、鼠标侧键 M4/M5

## 技术栈

| 层 | 技术 |
|---|---|
| 语言/框架 | Swift 5.9 + AppKit（纯原生，无 Electron/Tauri） |
| 语音识别 | 火山引擎 BigASR（实时 WebSocket 流式 ASR） |
| 文字插入 | CGEventPost |
| 音频采集 | AVAudioEngine 16kHz PCM |
| LLM | OpenAI 兼容 API（可对接本地模型或云服务） |
| 构建 | Swift Package Manager |

## 前置要求

- macOS 14+
- Xcode Command Line Tools（`xcode-select --install`）
- 火山引擎 BigASR 账号（App ID + Access Token）
- **辅助功能权限**：系统设置 → 隐私与安全 → 辅助功能，添加 Murmur

## 构建与运行

```bash
cd src-swift
swift build
open .build/debug/murmur.app
```

Release 包：

```bash
cd src-swift
swift build -c release
```

## 配置

首次运行后点击菜单栏图标 → 设置，填写：

| 字段 | 说明 |
|---|---|
| App ID / Access Token | 火山引擎 BigASR 凭证 |
| 热键 | 触发录音的按键（默认 Right Option） |
| 麦克风 | 录音设备（默认系统输入） |
| LLM Base URL / 模型 | OpenAI 兼容接口，可选 |
| 热词 AK/SK | 火山引擎热词管理凭证，可选 |

配置保存在 `~/Library/Application Support/com.murmurtype/config.json`。

## 热词管理

在菜单栏 → 热词库 中可以：

- 手动添加 / 删除热词
- 从火山引擎拉取最新词表
- 同步本地词表到火山引擎
- **AI 提取热词**：根据近 7 天识别记录和历史修正，自动建议应加入热词库的专有名词

## CI/CD

Push 到 `main` 分支自动触发：

1. `test` — 运行单元测试
2. `build-release` — 编译 release 包，产物保留 30 天

需要一台注册了 `macos` tag 的 GitLab Runner。

## 目录结构

```
src-swift/
├── Sources/
│   ├── App/               # AppKit UI 层（AppDelegate、FloatingWindow、各功能窗口）
│   └── MurmurCore/        # 核心逻辑（ASR、音频、键盘、LLM、历史、热词）
├── Tests/                 # 单元测试
├── Package.swift
└── Makefile
scripts/                   # 辅助脚本
docs/                      # 设计文档与实现计划
```

## License

MIT — 详见 [LICENSE](LICENSE)
