# Murmur 使用文档

## 快速上手

1. 下载 SenseVoice 模型：`cd models/sense-voice-zh-en && curl -LO https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx`
2. 构建并运行：`cd src-swift && swift build && cd .. && src-swift/.build/debug/murmur`
3. 授予辅助功能权限（系统设置 → 隐私与安全 → 辅助功能）
4. 按住热键（默认 Right Option）说话，松键后文字自动输入到当前光标

## 设置字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| 热键 | 是 | 触发录音的按键（默认 Right Option） |
| 麦克风 | 否 | 默认使用系统输入设备 |
| LLM Base URL | 否 | OpenAI 兼容接口地址，用于识别后润色 |
| LLM 模型 | 否 | 模型名称，如 gpt-4o、glm-4-flash |

## 热词管理

热词用于 LLM 润色时纠正专有名词（品牌名、产品名、技术缩写等）。

**手动添加**：菜单栏 → 热词库 → 输入框添加

**AI 提取**：菜单栏 → 热词库 → AI 提取热词。系统分析近 7 天识别记录和历史修正，自动建议新热词，可逐个添加或全部添加。

## 历史记录

菜单栏 → 历史记录 可查看所有识别文本。

## 权限说明

| 权限 | 用途 |
|---|---|
| 辅助功能 | CGEventTap 监听热键；CGEventPost 插入文字 |
| 麦克风 | AVAudioEngine 采集音频 |

## 常见问题

**按键无反应**：检查辅助功能权限是否已授予 Murmur（系统设置 → 隐私与安全 → 辅助功能）。

**模型加载失败**：确认 `models/sense-voice-zh-en/model.int8.onnx` 已下载（~228MB）。

**LLM 润色失败**：检查 Base URL 末尾不要有多余斜杠，模型名是否在该接口可用。

**AI 提取热词无结果**：正常现象——当前识别记录中没有新的专有名词。积累一批专业词汇的修正记录后再试。

## 数据存储位置

| 文件 | 内容 |
|---|---|
| `~/Library/Application Support/com.murmurtype/config.json` | 所有配置项 |
| `~/Library/Application Support/com.murmurtype/history.json` | 识别历史（最多 1000 条）|
| `~/Library/Application Support/com.murmurtype/hotwords.json` | 本地热词表 |
