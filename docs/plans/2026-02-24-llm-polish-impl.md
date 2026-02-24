# LLM 归整功能实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 ASR 识别完成后，可选地调用本地 OpenAI-compatible LLM 归整文本，新增 `polishing` 过渡状态供用户看到进度。

**Architecture:** 前端 `usePushToTalk.ts` 拿到 ASR finalResult 后，若 LLM 已启用则调 `fetch` 请求 `/v1/chat/completions`，成功替换文本，失败静默降级用原始文本。新增 `polishing` 状态驱动 FloatingWindow 显示 shimmer 动画。

**Tech Stack:** Tauri 2, React, TypeScript, Rust (serde), 原生 `fetch`（无额外依赖）

---

### Task 1: 扩展 Config — Rust 结构体 + TypeScript 接口

**Files:**
- Modify: `src-tauri/src/config.rs`
- Modify: `src/settings/SettingsWindow.tsx`（仅 Config 接口和 DEFAULT_CONFIG）

**Step 1: 编辑 `src-tauri/src/config.rs`，在 `asr_vocabulary` 字段后追加 4 个 LLM 字段**

在 `Config` struct 的 `pub asr_vocabulary: String,` 之后添加：

```rust
    #[serde(default)]
    pub llm_enabled: bool,
    #[serde(default)]
    pub llm_base_url: String,
    #[serde(default)]
    pub llm_model: String,
    #[serde(default)]
    pub llm_api_key: String,
```

在 `impl Default for Config` 的 `asr_vocabulary: String::new(),` 之后添加：

```rust
            llm_enabled: false,
            llm_base_url: String::new(),
            llm_model: String::new(),
            llm_api_key: String::new(),
```

**Step 2: 编辑 `src/settings/SettingsWindow.tsx`，在 `Config` interface 的 `asr_vocabulary: string;` 之后添加：**

```typescript
  llm_enabled: boolean;
  llm_base_url: string;
  llm_model: string;
  llm_api_key: string;
```

在 `DEFAULT_CONFIG` 的 `asr_vocabulary: '',` 之后添加：

```typescript
  llm_enabled: false,
  llm_base_url: '',
  llm_model: '',
  llm_api_key: '',
```

**Step 3: 验证 Rust 编译通过**

```bash
cd /Users/locke/workspace/murmur/src-tauri && cargo check 2>&1
```

期望：无 error（只允许 warning）

**Step 4: Commit**

```bash
git add src-tauri/src/config.rs src/settings/SettingsWindow.tsx
git commit -m "feat(config): add LLM polish fields to Config struct and TS interface"
```

---

### Task 2: LLM 调用逻辑 — types.ts + usePushToTalk.ts

**Files:**
- Modify: `src/asr/types.ts`
- Modify: `src/hooks/usePushToTalk.ts`

**Step 1: 在 `src/asr/types.ts` 的 `ASRStatus` 中新增 `'polishing'`**

将：
```typescript
export type ASRStatus =
  | 'idle'
  | 'connecting'
  | 'listening'
  | 'processing'
  | 'done'
  | 'error';
```

改为：
```typescript
export type ASRStatus =
  | 'idle'
  | 'connecting'
  | 'listening'
  | 'processing'
  | 'polishing'
  | 'done'
  | 'error';
```

**Step 2: 在 `src/hooks/usePushToTalk.ts` 添加 `llmConfigRef` 和 `polishWithLLM` 函数**

在文件顶部 import 之后、`export function usePushToTalk()` 之前，添加常量和辅助函数：

```typescript
const LLM_SYSTEM_PROMPT =
  '你是一个文本归整助手。将用户输入的语音识别文本整理成流畅的书面语，' +
  '修正标点、大小写和口语化表达，不改变原意，不添加任何解释，只输出归整后的文本。';

const LLM_TIMEOUT_MS = 10_000;

interface LLMConfig {
  llm_enabled: boolean;
  llm_base_url: string;
  llm_model: string;
  llm_api_key: string;
}

async function polishWithLLM(text: string, cfg: LLMConfig): Promise<string> {
  if (!cfg.llm_enabled || !cfg.llm_base_url) return text;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), LLM_TIMEOUT_MS);
  try {
    const res = await fetch(`${cfg.llm_base_url}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(cfg.llm_api_key ? { Authorization: `Bearer ${cfg.llm_api_key}` } : {}),
      },
      body: JSON.stringify({
        model: cfg.llm_model,
        messages: [
          { role: 'system', content: LLM_SYSTEM_PROMPT },
          { role: 'user', content: text },
        ],
        stream: false,
      }),
      signal: controller.signal,
    });
    if (!res.ok) return text;
    const data = await res.json() as { choices?: Array<{ message?: { content?: string } }> };
    return data?.choices?.[0]?.message?.content?.trim() || text;
  } catch {
    return text;
  } finally {
    clearTimeout(timer);
  }
}
```

**Step 3: 在 `usePushToTalk()` 函数体中添加 `llmConfigRef`**

在 `const peakRmsRef = useRef(0);` 这行之后添加：

```typescript
  const llmConfigRef = useRef<LLMConfig | null>(null);
```

**Step 4: 在 `ptt:start` 的 `invoke<{...}>('get_config')` 类型参数中新增 4 个 LLM 字段**

将 invoke 的类型参数（`await invoke<{ ... }>('get_config')`）中，在 `asr_vocabulary: string;` 之后追加：

```typescript
          llm_enabled: boolean;
          llm_base_url: string;
          llm_model: string;
          llm_api_key: string;
```

在 `rawConfig` 获取成功后（`const client = new VolcengineClient(...)` 之前），添加：

```typescript
        llmConfigRef.current = {
          llm_enabled: rawConfig.llm_enabled,
          llm_base_url: rawConfig.llm_base_url,
          llm_model: rawConfig.llm_model,
          llm_api_key: rawConfig.llm_api_key,
        };
```

**Step 5: 在 `ptt:stop` 中，将 `insert_text` 调用替换为 LLM-aware 版本**

找到现有的这段代码（大约在 `client.disconnect()` 之后）：

```typescript
      if (finalResult?.text) {
        flog(`ptt:stop insert_text: len=${finalResult.text.length}`);
        try {
          await invoke('insert_text', { text: finalResult.text });
        } catch (err) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }
```

替换为：

```typescript
      if (finalResult?.text) {
        let textToInsert = finalResult.text;
        const llmCfg = llmConfigRef.current;
        if (llmCfg?.llm_enabled && llmCfg.llm_base_url) {
          setStatus('polishing');
          textToInsert = await polishWithLLM(finalResult.text, llmCfg);
        }
        flog(`ptt:stop insert_text: len=${textToInsert.length} polished=${textToInsert !== finalResult.text}`);
        try {
          await invoke('insert_text', { text: textToInsert });
        } catch (err) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }
```

**Step 6: TypeScript 类型检查**

```bash
cd /Users/locke/workspace/murmur && pnpm exec tsc --noEmit 2>&1
```

期望：0 errors

**Step 7: Commit**

```bash
git add src/asr/types.ts src/hooks/usePushToTalk.ts
git commit -m "feat(llm): add polishWithLLM and polishing status to usePushToTalk"
```

---

### Task 3: Settings 页面新增 LLM 归整区块

**Files:**
- Modify: `src/settings/SettingsWindow.tsx`（仅 JSX 部分）

**Step 1: 在 SettingsWindow.tsx 的 Recognition section 之后（`</section>` 闭合标签后）添加 LLM 区块**

紧接在最后一个 `</section>` 与 `</div>` (`settings-content` 的闭合) 之间插入：

```tsx
        {/* ── LLM 归整 ── */}
        <section className="settings-section">
          <div className="settings-section__heading">LLM 归整</div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">启用</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.llm_enabled}
                onChange={(e) => setField('llm_enabled', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          {config.llm_enabled && (
            <>
              <div className="settings-field">
                <label className="settings-field__label">Base URL</label>
                <input
                  className="settings-field__input settings-field__input--mono"
                  type="text"
                  placeholder="http://localhost:11434"
                  value={config.llm_base_url}
                  onChange={(e) => setField('llm_base_url', e.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>

              <div className="settings-field">
                <label className="settings-field__label">Model</label>
                <input
                  className="settings-field__input settings-field__input--mono"
                  type="text"
                  placeholder="qwen2.5:7b"
                  value={config.llm_model}
                  onChange={(e) => setField('llm_model', e.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>

              <div className="settings-field">
                <label className="settings-field__label">API Key</label>
                <input
                  className="settings-field__input settings-field__input--mono"
                  type="password"
                  placeholder="sk-... （本地模型可留空）"
                  value={config.llm_api_key}
                  onChange={(e) => setField('llm_api_key', e.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
                <span className="settings-field__hint">本地模型可留空</span>
              </div>
            </>
          )}
        </section>
```

**Step 2: TypeScript 类型检查**

```bash
cd /Users/locke/workspace/murmur && pnpm exec tsc --noEmit 2>&1
```

期望：0 errors

**Step 3: Commit**

```bash
git add src/settings/SettingsWindow.tsx
git commit -m "feat(settings): add LLM polish section to Settings page"
```

---

### Task 4: FloatingWindow polishing 状态 + shimmer 动画

**Files:**
- Modify: `src/components/FloatingWindow.tsx`
- Modify: `src/components/floating-window.css`

**Step 1: 在 `floating-window.css` 末尾追加 shimmer keyframe**

```css
/* ============================================
 * LLM polishing shimmer
 * ============================================ */

@keyframes shimmer {
  0%, 100% { opacity: 0.92; }
  50%       { opacity: 0.40; }
}

.pill__result--polishing {
  animation: shimmer 1.2s ease-in-out infinite;
}
```

**Step 2: 更新 `FloatingWindow.tsx` 处理 polishing 状态**

将现有的：

```tsx
  const fading = status === 'processing';

  return (
    <div className="floating-window">
      <div className="pill">
        {(status === 'done' || status === 'processing') && result?.text ? (
          <span className="pill__result">{result.text}</span>
        ) : (
          <WaveformVisualizer levels={audioLevels} fading={fading} />
        )}
```

替换为：

```tsx
  const fading = status === 'processing';
  const polishing = status === 'polishing';

  return (
    <div className="floating-window">
      <div className="pill">
        {(status === 'done' || status === 'processing' || status === 'polishing') && result?.text ? (
          <span className={`pill__result${polishing ? ' pill__result--polishing' : ''}`}>
            {result.text}
          </span>
        ) : (
          <WaveformVisualizer levels={audioLevels} fading={fading} />
        )}
```

**Step 3: 构建前端并整包编译**

```bash
cd /Users/locke/workspace/murmur && pnpm build 2>&1 | tail -20
```

期望：`dist/` 生成成功，无 error

```bash
cd /Users/locke/workspace/murmur/src-tauri && cargo build 2>&1 | tail -20
```

期望：`Compiling murmur` … `Finished` 无 error

**Step 4: 手动验证**

1. 启动应用（Terminal.app）：
   ```bash
   osascript -e 'tell application "Terminal" to do script "/Users/locke/workspace/murmur/src-tauri/target/debug/murmur"'
   ```
2. 打开 Settings → 找到"LLM 归整"区块，勾选"启用"→ 展开字段
3. 填入 Base URL / Model / API Key → Save
4. 按住 PTT 键录音，松开：应看到 `polishing` 状态文字闪烁，随后文字被替换为归整后版本
5. 禁用 LLM：重复步骤 4，应直接跳过 `polishing` 正常插入原始文本

**Step 5: Commit**

```bash
git add src/components/FloatingWindow.tsx src/components/floating-window.css
git commit -m "feat(ui): add polishing state shimmer animation to FloatingWindow"
```

---

### Task 5: Push

```bash
git push
```
