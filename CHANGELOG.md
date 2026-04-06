# Changelog

## [Unreleased]

### Added
- AI 热词提取：根据近 7 天识别记录 + 历史修正，调 LLM 自动建议新热词
- 使用统计窗口：30 天用量折线图、24 小时时段分布、修正率等报表（Swift Charts）
- 历史记录手动修正：支持编辑单条记录，保留原文与修正版本对比
- 热词库 Tag Cloud：替换列表布局，FlowLayout 标签云，支持批量添加 AI 建议词
- 从火山引擎拉取热词：打开热词窗口自动同步最新词表
- Siri 风格波形动画：60fps 平滑单线波形，指数平滑音量，蓝白色调
- ESC 关闭所有辅助窗口
- 空识别快速隐藏：无内容时跳过 done 状态直接回 idle
- GitLab CI/CD：macOS Runner 自动测试 + release 构建

---

## [0.2.0] — 2026-03-03

Swift 原生重写，替换 Tauri/React/Rust 技术栈。

### Added
- 纯 Swift + AppKit 实现，移除 Electron/Tauri 依赖
- 浮窗不抢焦点，文字通过 CGEventPost 插入当前光标
- AVAudioEngine 16kHz PCM 音频采集
- CGEventTap 热键监听（支持 Option、Control、CapsLock、F-Key、鼠标键）
- 鼠标侧键映射为 Enter
- LLM 归整（OpenAI 兼容 API）
- 热词库管理 + 火山引擎自学习平台同步
- 历史记录持久化（JSON，最多 1000 条）
- 托盘菜单：历史记录、热词库、使用统计、设置

---

## [0.1.0] — 2026-02-24

Tauri + React + Rust 初版（已废弃）。
