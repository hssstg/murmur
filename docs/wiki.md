# Murmur 使用文档

## 快速上手

1. 构建并运行：`cd src-swift && swift build && open .build/debug/murmur.app`
2. 点击菜单栏麦克风图标 → 设置，填写火山引擎 App ID 和 Access Token
3. 授予辅助功能权限（系统设置 → 隐私与安全 → 辅助功能）
4. 按住热键（默认 Right Option）说话，松键后文字自动输入到当前光标

## 设置字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| App ID | 是 | 火山引擎 BigASR 应用 ID |
| Access Token | 是 | 火山引擎 BigASR 访问令牌 |
| 热键 | 是 | 触发录音的按键（默认 Right Option） |
| 麦克风 | 否 | 默认使用系统输入设备 |
| LLM Base URL | 否 | OpenAI 兼容接口地址，用于识别后归整 |
| LLM 模型 | 否 | 模型名称，如 gpt-4o、glm-4-flash |
| 热词 AK/SK | 否 | 火山引擎热词管理凭证 |

## 热词管理

热词能提升 ASR 对专有名词的识别率（品牌名、产品名、技术缩写等）。

**手动添加**：菜单栏 → 热词库 → 输入框添加

**AI 提取**：菜单栏 → 热词库 → AI 提取热词。系统分析近 7 天识别记录和历史修正，自动建议新热词，可逐个添加或全部添加。

**同步到火山引擎**：点击「同步到火山引擎」将本地词表上传到自学习平台。

## 历史记录与修正

菜单栏 → 历史记录 可查看所有识别文本。

点击铅笔图标可编辑单条记录，原文与修正版本均会保留。修正记录会作为 AI 热词提取的参考依据。

## 权限说明

| 权限 | 用途 |
|---|---|
| 辅助功能 | CGEventTap 监听热键；CGEventPost 插入文字 |
| 麦克风 | AVAudioEngine 采集音频 |

## 常见问题

**按键无反应**：检查辅助功能权限是否已授予 Murmur（系统设置 → 隐私与安全 → 辅助功能）。

**识别结果乱码**：检查 App ID / Access Token 是否正确。

**LLM 归整失败**：检查 Base URL 末尾不要有多余斜杠，模型名是否在该接口可用。

**热词同步失败**：检查 AK/SK 是否正确，火山引擎控制台中该 App ID 是否开通了自学习平台。

**AI 提取热词无结果**：正常现象——当前识别记录中没有新的专有名词。积累一批专业词汇的修正记录后再试。

## 数据存储位置

| 文件 | 内容 |
|---|---|
| `~/Library/Application Support/com.locke.murmur/config.json` | 所有配置项 |
| `~/Library/Application Support/com.locke.murmur/history.json` | 识别历史（最多 1000 条）|
| `~/Library/Application Support/com.locke.murmur/hotwords.json` | 本地热词表 |
