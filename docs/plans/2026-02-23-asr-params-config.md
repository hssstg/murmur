# ASR Parameters Config Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose 5 Volcengine ASR parameters (language, punctuation, ITN, DDC, vocabulary) as user-configurable settings stored in the existing Rust config system and surfaced in the Settings UI.

**Architecture:** Extend `Config` struct with 5 serde-defaulted fields → thread through `VolcengineClientConfig` → used in `volcengine-client.ts` init request. Add a "Recognition" section to `SettingsWindow.tsx` with a select and four toggles.

**Tech Stack:** Rust/serde_json, React/TypeScript, Tauri v2 invoke commands

---

### Task 1: Extend Rust Config struct

**Files:**
- Modify: `src-tauri/src/config.rs`

The `Config` struct currently has 5 fields. Add 5 more with `#[serde(default = "...")]`
so that existing `config.json` files without these keys still load cleanly.

**Step 1: Add serde default helper functions and new fields**

Replace the entire `config.rs` with the following (the existing code is preserved,
only additions are made):

```rust
use std::sync::{Arc, Mutex};
use tauri::Manager;

pub type SharedConfig = Arc<Mutex<Config>>;

fn default_asr_language() -> String { "zh-CN".to_string() }
fn default_true() -> bool { true }

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Config {
    pub api_app_id: String,
    pub api_access_token: String,
    pub api_resource_id: String,
    pub hotkey: String,
    pub microphone: Option<String>,

    #[serde(default = "default_asr_language")]
    pub asr_language: String,
    #[serde(default)]
    pub asr_enable_punc: bool,
    #[serde(default = "default_true")]
    pub asr_enable_itn: bool,
    #[serde(default = "default_true")]
    pub asr_enable_ddc: bool,
    #[serde(default)]
    pub asr_vocabulary: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            api_app_id: String::new(),
            api_access_token: String::new(),
            api_resource_id: "volc.bigasr.sauc.duration".to_string(),
            hotkey: "ROption".to_string(),
            microphone: None,
            asr_language: default_asr_language(),
            asr_enable_punc: false,
            asr_enable_itn: true,
            asr_enable_ddc: true,
            asr_vocabulary: String::new(),
        }
    }
}
```

Keep the `load_config`, `save_config_to_disk`, `get_config`, `save_config` functions
exactly as they are — no changes needed there.

**Step 2: Build to verify no compile errors**

```bash
~/.cargo/bin/cargo build --manifest-path src-tauri/Cargo.toml 2>&1 | tail -5
```

Expected: `Finished \`dev\` profile`

**Step 3: Commit**

```bash
git add src-tauri/src/config.rs
git commit -m "feat: add asr params fields to Config struct"
```

---

### Task 2: Extend TypeScript ASR types and client

**Files:**
- Modify: `src/asr/types.ts`
- Modify: `src/asr/volcengine-client.ts`

**Step 1: Add fields to `VolcengineClientConfig` in `src/asr/types.ts`**

The current interface (lines 21–25) is:
```ts
export interface VolcengineClientConfig {
  appId: string;
  accessToken: string;
  resourceId: string;
}
```

Replace it with:
```ts
export interface VolcengineClientConfig {
  appId: string;
  accessToken: string;
  resourceId: string;
  language: string;
  enablePunc: boolean;
  enableItn: boolean;
  enableDdc: boolean;
  vocabulary?: string;
}
```

**Step 2: Update init request in `src/asr/volcengine-client.ts`**

Find the `initRequest` object in `connect()` (around line 321). The current `request` block is:
```ts
      request: {
        model_name: 'bigmodel',
        enable_punc: false,
        enable_itn: true,
        enable_ddc: true,
        show_utterances: true,
        result_type: 'full',
      },
```

Replace it with:
```ts
      request: {
        model_name: 'bigmodel',
        language: this.config.language,
        enable_punc: this.config.enablePunc,
        enable_itn: this.config.enableItn,
        enable_ddc: this.config.enableDdc,
        ...(this.config.vocabulary ? { vocabulary_id: this.config.vocabulary } : {}),
        show_utterances: true,
        result_type: 'full',
      },
```

**Step 3: Verify TypeScript compiles**

```bash
cd /Users/locke/workspace/murmur && npx tsc --noEmit 2>&1 | head -20
```

Expected: no errors (or only pre-existing unrelated errors)

**Step 4: Commit**

```bash
git add src/asr/types.ts src/asr/volcengine-client.ts
git commit -m "feat: thread asr params through VolcengineClientConfig"
```

---

### Task 3: Update usePushToTalk to pass new config fields

**Files:**
- Modify: `src/hooks/usePushToTalk.ts`

**Step 1: Find the VolcengineClient constructor call**

In `usePushToTalk.ts`, the `ptt:start` handler calls `get_config` and then constructs
a `VolcengineClient` (around lines 84–93). The current code is:

```ts
        const rawConfig = await invoke<{
          api_app_id: string;
          api_access_token: string;
          api_resource_id: string;
        }>('get_config');
        const client = new VolcengineClient({
          appId: rawConfig.api_app_id,
          accessToken: rawConfig.api_access_token,
          resourceId: rawConfig.api_resource_id,
        });
```

**Step 2: Extend the invoke type and constructor call**

Replace those lines with:

```ts
        const rawConfig = await invoke<{
          api_app_id: string;
          api_access_token: string;
          api_resource_id: string;
          asr_language: string;
          asr_enable_punc: boolean;
          asr_enable_itn: boolean;
          asr_enable_ddc: boolean;
          asr_vocabulary: string;
        }>('get_config');
        const client = new VolcengineClient({
          appId: rawConfig.api_app_id,
          accessToken: rawConfig.api_access_token,
          resourceId: rawConfig.api_resource_id,
          language: rawConfig.asr_language,
          enablePunc: rawConfig.asr_enable_punc,
          enableItn: rawConfig.asr_enable_itn,
          enableDdc: rawConfig.asr_enable_ddc,
          vocabulary: rawConfig.asr_vocabulary || undefined,
        });
```

**Step 3: Verify TypeScript compiles**

```bash
cd /Users/locke/workspace/murmur && npx tsc --noEmit 2>&1 | head -20
```

Expected: no errors

**Step 4: Commit**

```bash
git add src/hooks/usePushToTalk.ts
git commit -m "feat: pass asr params from config to VolcengineClient"
```

---

### Task 4: Add Recognition section to Settings UI

**Files:**
- Modify: `src/settings/SettingsWindow.tsx`
- Modify: `src/settings/SettingsWindow.css`

**Step 1: Add toggle CSS to `SettingsWindow.css`**

Append to the end of `SettingsWindow.css`:

```css
/* ============================================
 * Toggle Switch
 * ============================================ */

.settings-toggle-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}

.settings-toggle-row:last-child {
  margin-bottom: 0;
}

.settings-toggle-row__label {
  font-size: 13px;
  color: rgba(255, 255, 255, 0.85);
}

.settings-toggle {
  position: relative;
  width: 36px;
  height: 20px;
  flex-shrink: 0;
}

.settings-toggle input {
  opacity: 0;
  width: 0;
  height: 0;
  position: absolute;
}

.settings-toggle__track {
  position: absolute;
  inset: 0;
  background: rgba(255, 255, 255, 0.12);
  border-radius: 10px;
  cursor: pointer;
  transition: background 0.2s ease;
}

.settings-toggle input:checked + .settings-toggle__track {
  background: #0a84ff;
}

.settings-toggle__track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 16px;
  height: 16px;
  background: white;
  border-radius: 50%;
  transition: transform 0.2s ease;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
}

.settings-toggle input:checked + .settings-toggle__track::after {
  transform: translateX(16px);
}
```

**Step 2: Update `Config` interface and `DEFAULT_CONFIG` in `SettingsWindow.tsx`**

Find the `Config` interface (lines 5–11) and `DEFAULT_CONFIG` (lines 13–19).

Replace the `Config` interface:
```ts
interface Config {
  api_app_id: string;
  api_access_token: string;
  api_resource_id: string;
  hotkey: string;
  microphone: string | null;
  asr_language: string;
  asr_enable_punc: boolean;
  asr_enable_itn: boolean;
  asr_enable_ddc: boolean;
  asr_vocabulary: string;
}
```

Replace `DEFAULT_CONFIG`:
```ts
const DEFAULT_CONFIG: Config = {
  api_app_id: '',
  api_access_token: '',
  api_resource_id: '',
  hotkey: 'ROption',
  microphone: null,
  asr_language: 'zh-CN',
  asr_enable_punc: false,
  asr_enable_itn: true,
  asr_enable_ddc: true,
  asr_vocabulary: '',
};
```

**Step 3: Add LANGUAGE_OPTIONS constant**

After the `HOTKEY_OPTIONS` array (after line 29), add:

```ts
const LANGUAGE_OPTIONS: { label: string; value: string }[] = [
  { label: '中文', value: 'zh-CN' },
  { label: 'English', value: 'en-US' },
  { label: '粤语', value: 'zh-Yue' },
  { label: '日本語', value: 'ja-JP' },
];
```

**Step 4: Add Recognition section to the JSX**

In the `return` block, after the closing `</section>` of the Microphone section
(after line 219) and before the closing `</div>` of `settings-content`, add:

```tsx
        {/* ── Recognition ── */}
        <section className="settings-section">
          <div className="settings-section__heading">Recognition</div>

          <div className="settings-field">
            <label className="settings-field__label">Language</label>
            <select
              className="settings-field__select"
              value={config.asr_language}
              onChange={(e) => setField('asr_language', e.target.value)}
            >
              {LANGUAGE_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>
                  {opt.label}
                </option>
              ))}
            </select>
          </div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">Punctuation</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.asr_enable_punc}
                onChange={(e) => setField('asr_enable_punc', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">Number Format</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.asr_enable_itn}
                onChange={(e) => setField('asr_enable_itn', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          <div className="settings-toggle-row">
            <span className="settings-toggle-row__label">Filter Fillers</span>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={config.asr_enable_ddc}
                onChange={(e) => setField('asr_enable_ddc', e.target.checked)}
              />
              <span className="settings-toggle__track" />
            </label>
          </div>

          <div className="settings-field">
            <label className="settings-field__label">Vocabulary</label>
            <input
              className="settings-field__input settings-field__input--mono"
              type="text"
              placeholder="Vocabulary ID (optional)"
              value={config.asr_vocabulary}
              onChange={(e) => setField('asr_vocabulary', e.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
            <span className="settings-field__hint">
              Custom vocabulary ID for improved recognition of domain-specific terms.
            </span>
          </div>
        </section>
```

**Step 5: Build and test manually**

```bash
cd /Users/locke/workspace/murmur && npx tsc --noEmit 2>&1 | head -20
```

Then rebuild and relaunch the app:
```bash
~/.cargo/bin/cargo build --manifest-path src-tauri/Cargo.toml 2>&1 | tail -3
pkill -x murmur 2>/dev/null
osascript -e 'tell application "Terminal" to do script "/Users/locke/workspace/murmur/src-tauri/target/debug/murmur"'
```

Open Settings from the tray menu. Verify:
- "Recognition" section appears with Language dropdown, 3 toggles, Vocabulary input
- Toggling options and saving works (no console errors)
- PTT session still works after changing a setting

**Step 6: Commit**

```bash
git add src/settings/SettingsWindow.tsx src/settings/SettingsWindow.css
git commit -m "feat: add Recognition section to Settings UI"
```

---

### Done

All 4 tasks complete. The feature is fully implemented:
- Config fields stored in `~/.config/murmur/config.json`
- Settings UI lets users toggle/select ASR params
- Every PTT session picks up the current config at connect time
