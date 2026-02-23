# ASR Parameters Config Design

**Goal:** Expose 5 Volcengine ASR parameters (language, punctuation, ITN, DDC, vocabulary) as user-configurable settings stored in the existing Config system.

**Architecture:** Extend the existing Rust `Config` struct with 5 new fields (serde defaults for backward compatibility). Pass them through `VolcengineClientConfig` → `VolcengineClient.connect()` → init request. Add a "Recognition" section to `SettingsWindow.tsx`.

**Tech Stack:** Rust/serde_json (config), React/TypeScript (UI), Volcengine BigModel ASR V3 WebSocket

---

## Data Layer

### `src-tauri/src/config.rs`

Add 5 fields to `Config` struct with `#[serde(default)]` for backward compatibility:

```rust
#[serde(default = "default_asr_language")]
pub asr_language: String,       // "zh-CN"

#[serde(default = "default_false")]
pub asr_enable_punc: bool,      // false

#[serde(default = "default_true")]
pub asr_enable_itn: bool,       // true

#[serde(default = "default_true")]
pub asr_enable_ddc: bool,       // true

#[serde(default)]
pub asr_vocabulary: String,     // "" (empty = don't send to API)
```

### `src/asr/types.ts` — `VolcengineClientConfig`

Add matching fields:

```ts
language: string;
enablePunc: boolean;
enableItn: boolean;
enableDdc: boolean;
vocabulary?: string;
```

### `src/asr/volcengine-client.ts` — init request

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
}
```

### `src/hooks/usePushToTalk.ts`

Pass new fields when constructing `VolcengineClient` in `ptt:start`:

```ts
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

---

## UI

### `src/settings/SettingsWindow.tsx`

Add "Recognition" section after the Microphone section:

- **Language** — `<select>` with 4 options:
  - 中文 → `zh-CN`
  - English → `en-US`
  - 粤语 → `zh-Yue`
  - 日本語 → `ja-JP`
- **Punctuation** — toggle (`enable_punc`, default off)
- **Number Format** — toggle (`enable_itn`, default on)
- **Filter Fillers** — toggle (`enable_ddc`, default on)
- **Vocabulary** — text input, placeholder "Vocabulary ID (optional)"

Update the local `Config` interface and `DEFAULT_CONFIG` to include the 5 new fields.

### `src/settings/SettingsWindow.css`

Add toggle switch styles (reusable `.settings-toggle` class) if not already present.

---

## Files Changed

| File | Change |
|------|--------|
| `src-tauri/src/config.rs` | +5 fields with serde defaults |
| `src/asr/types.ts` | +5 fields in `VolcengineClientConfig` |
| `src/asr/volcengine-client.ts` | Use new config fields in init request |
| `src/hooks/usePushToTalk.ts` | Pass new fields to `VolcengineClient` |
| `src/settings/SettingsWindow.tsx` | +Recognition section, update Config interface |
| `src/settings/SettingsWindow.css` | +Toggle switch styles (if needed) |

No new files, no new Tauri commands.
