# Murmur

macOS 本地语音输入工具。按住热键说话，松键后识别结果自动打到当前光标位置，全程无需切换应用，**完全离线，无需云服务**。

## 功能

- **Push-to-Talk**：按住热键录音，松键触发识别，结果直接插入当前光标
- **离线 ASR**：基于 SenseVoice（sherpa-onnx），中英日韩粤语混合识别，内置标点和 ITN
- **胶囊悬浮窗**：录音期间底部显示实时音频波形，不抢焦点
- **LLM 润色**（可选）：识别后调 LLM 去语气词、修正同音错字
- **历史记录**：所有识别结果持久化，支持搜索浏览
- **热词库**：本地热词管理，AI 可从历史中自动提取建议词
- **使用统计**：30 天用量折线图、时段分布等报表
- **鼠标键映射**：可将鼠标侧键映射为 Enter 键

## 热键

`Right/Left Option`、`Right/Left Control`、`CapsLock`、`F13–F15`、鼠标中键、鼠标侧键 M4/M5

## 技术栈

| 层 | 技术 |
|---|---|
| 语言/框架 | Swift 6 + AppKit（纯原生，无 Electron/Tauri） |
| 语音识别 | SenseVoice（sherpa-onnx 离线推理，~228MB 模型） |
| 文字插入 | CGEventPost |
| 音频采集 | AVAudioEngine 16kHz PCM |
| LLM | OpenAI 兼容 API（可选，可对接本地模型或云服务） |
| 构建 | Swift Package Manager |

## 前置要求

- macOS 14+
- Xcode Command Line Tools（`xcode-select --install`）
- **辅助功能权限**：系统设置 → 隐私与安全 → 辅助功能，添加 Murmur
- **麦克风权限**：首次运行时授权

## 模型下载

首次构建前需下载 SenseVoice 模型文件（~228MB，不包含在 Git 仓库中）：

```bash
cd models/sense-voice-zh-en
curl -LO https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx
```

同时需要下载 sherpa-onnx 预编译库（参见 `src-swift/LocalPackages/SherpaOnnx/`）。

## 构建与运行

```bash
cd src-swift
swift build
# 从仓库根目录启动（模型路径需要）
cd .. && src-swift/.build/debug/murmur
```

Release 构建 + DMG 打包：

```bash
bash scripts/build-dmg.sh
```

## 配置

首次运行后点击菜单栏图标 → 设置：

| 字段 | 说明 |
|---|---|
| 热键 | 触发录音的按键（默认 Right Option） |
| 麦克风 | 录音设备（默认系统输入） |
| LLM Base URL / 模型 | OpenAI 兼容接口（可选，用于文本润色） |

配置保存在 `~/Library/Application Support/com.murmurtype/config.json`。

## 目录结构

```
src-swift/
├── Sources/
│   ├── App/               # AppKit UI 层（AppDelegate、FloatingWindow、各功能窗口）
│   └── MurmurCore/        # 核心逻辑（ASR、音频、键盘、LLM、历史、热词）
├── LocalPackages/SherpaOnnx/  # sherpa-onnx C library SPM wrapper
├── Tests/                 # 单元测试
├── Package.swift
└── Makefile
models/                    # ASR 模型文件（需单独下载）
scripts/                   # 构建和辅助脚本
website/                   # 产品页面
```

## License

MIT — 详见 [LICENSE](LICENSE)
