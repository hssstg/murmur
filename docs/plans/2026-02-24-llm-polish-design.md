# LLM 归整功能设计文档

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**目标：** 在语音识别完成后，可选地通过本地部署的 LLM 对识别文本进行归整（修正标点、大小写、口语化表达），输出更干净的书面语再插入。

**架构：** 前端（`usePushToTalk.ts`）拿到 ASR finalResult 后，若 LLM 已启用则发起 OpenAI-compatible `/v1/chat/completions` 请求，成功则用归整文本替换原始文本，失败或超时则静默降级使用原始文本。

**Tech Stack：** Tauri 2 + React + TypeScript；LLM 调用使用原生 `fetch`，OpenAI-compatible API。

---

## 状态机

```
listening → processing → polishing → done → idle
                         (LLM 处理中，仅 llm_enabled=true 时经过)
```

| 状态         | UI 表现                         |
|--------------|---------------------------------|
| `processing` | 文字淡出 + 波形                 |
| `polishing`  | ASR 原始文本 + shimmer 动画     |
| `done`       | 归整后文本（或原始文本）        |

---

## 配置字段

Rust `Config` 及 TypeScript `Config` 接口同步新增：

| 字段            | 类型    | 默认值  | 说明                       |
|-----------------|---------|---------|----------------------------|
| `llm_enabled`   | bool    | false   | 是否启用 LLM 归整          |
| `llm_base_url`  | String  | ""      | OpenAI-compatible base URL |
| `llm_model`     | String  | ""      | 模型名称                   |
| `llm_api_key`   | String  | ""      | API Key（本地可为空）      |

---

## LLM 调用规格

- **Endpoint：** `{llm_base_url}/v1/chat/completions`
- **Method：** POST
- **超时：** 10 秒（AbortController）
- **失败行为：** 静默降级，使用原始 ASR 文本

**Request body：**
```json
{
  "model": "{llm_model}",
  "messages": [
    {
      "role": "system",
      "content": "你是一个文本归整助手。将用户输入的语音识别文本整理成流畅的书面语，修正标点、大小写和口语化表达，不改变原意，不添加任何解释，只输出归整后的文本。"
    },
    {
      "role": "user",
      "content": "{asr_text}"
    }
  ],
  "stream": false
}
```

**取值：** `response.choices[0].message.content.trim()`

---

## 文件改动清单

| 文件                                  | 改动内容                                      |
|---------------------------------------|-----------------------------------------------|
| `src-tauri/src/config.rs`             | 新增 4 个 LLM 字段                            |
| `src/asr/types.ts`                    | `ASRStatus` 新增 `'polishing'`                |
| `src/hooks/usePushToTalk.ts`          | ptt:stop 处理中增加 LLM 调用逻辑              |
| `src/settings/SettingsWindow.tsx`     | 新增"LLM 归整"设置区块                        |
| `src/components/FloatingWindow.tsx`   | `polishing` 状态渲染                          |
| `src/components/floating-window.css`  | 新增 shimmer 动画                             |

---

## 错误处理

- LLM 请求超时（>10s）→ 降级用原始文本
- HTTP 非 2xx → 降级
- JSON 解析失败 → 降级
- `llm_base_url` 为空时不发请求 → 直接降级
- 降级时不向用户显示错误（LLM 是可选增强，不影响主流程）
