# Murmur 深度代码审查报告

审查日期：2026-02-23  
审查范围：`src/`、`src-tauri/`、`scripts/`、Tauri 权限与安全配置

## 主要发现（按严重级别）

### High

#### H1. 生产环境可被 `/tmp` 文件无交互触发录音流程
- 位置：`src-tauri/src/keyboard.rs:35`
- 位置：`src-tauri/src/keyboard.rs:36`
- 位置：`src-tauri/src/keyboard.rs:43`
- 位置：`src-tauri/src/keyboard.rs:56`

`keyboard` 线程每 20ms 轮询 `/tmp/murmur_ptt_start` 与 `/tmp/murmur_ptt_stop`。任意本机进程可通过 `touch` 触发 `ptt:start` / `ptt:stop`，绕过真实键盘输入，属于明显的生产后门行为（即使初衷是自动化测试）。

影响：未经用户真实按键动作即可启动录音链路，存在隐私与滥用风险。

建议：
1. 用 `#[cfg(debug_assertions)]` 包裹该测试入口，release 构建彻底移除。
2. 自动化测试改为受控命令（仅测试构建注册）。

---

### Medium

#### M1. 识别文本被写入 `/tmp`，可造成敏感信息落盘
- 位置：`src/hooks/usePushToTalk.ts:188`
- 位置：`src/asr/volcengine-client.ts:495`
- 位置：`src-tauri/src/text.rs:9`

前端通过 `flog` 调用 `append_log`，会把最终识别文本直接写入 `/tmp/murmur_debug.log`。语音转写内容可能包含账号、地址、验证码等敏感信息。

建议：
1. 生产构建关闭 `append_log` 命令。
2. 禁止日志记录全文文本；仅保留长度、状态、request id。

#### M2. 凭证明文写入配置文件
- 位置：`src-tauri/src/config.rs:12`
- 位置：`src-tauri/src/config.rs:82`

`api_access_token` 明文进入 `config.json`，本机读取配置文件即可提取云服务凭据。

建议：
1. Token 存入系统凭据库（macOS Keychain）。
2. `config.json` 只保存非敏感字段。

#### M3. WebSocket 二进制帧解析缺少长度边界校验
- 位置：`src/asr/volcengine-client.ts:141`
- 位置：`src/asr/volcengine-client.ts:152`
- 位置：`src/asr/volcengine-client.ts:175`

`parseResponse` 在读取 `msgSize/payloadSize` 时未校验 `data.length` 是否满足最小结构长度和 payload 边界；畸形帧可能触发 `DataView` 越界异常或解压异常。

建议：
1. 解析前增加严格的最小长度与 `12 + size <= data.length` 校验。
2. `handleMessage` 外层加兜底 `try/catch`，避免异常打断会话状态机。

#### M4. `cpal` 输入流仅按 `f32` 构建，兼容性不足
- 位置：`src-tauri/src/audio.rs:86`
- 位置：`src-tauri/src/audio.rs:114`
- 位置：`src-tauri/src/audio.rs:121`

代码读取了 `default_input_config()`，但 `build_input_stream` 回调固定为 `|data: &[f32], _|`。若设备默认采样格式为 `i16/u16`，流构建可能失败（或无法覆盖所有设备）。

建议：按 `default_cfg.sample_format()` 分支分别处理 `F32/I16/U16` 并统一转换到 `f32` 后重采样。

#### M5. Tauri 能力面偏宽，含非必需路径权限
- 位置：`src-tauri/capabilities/default.json:13`
- 位置：`src-tauri/capabilities/default.json:14`

当前启用了 `core:window:allow-create` 与 `core:path:default`。就当前业务看，`path` 权限与任意窗口创建能力可进一步收缩。

建议：按最小权限原则移除不用的 capability，必要时拆分 main/settings 独立能力集。

---

### Low

#### L1. 前端与 Rust 默认 `resource_id` 不一致
- 位置：`src/settings/SettingsWindow.tsx:21`
- 位置：`src-tauri/src/config.rs:33`

前端默认值为空字符串，Rust 默认值为 `volc.bigasr.sauc.duration`。当 `get_config` 失败走前端默认时可能直接请求失败。

建议：统一默认值，避免降级路径不可用。

#### L2. 存在未使用组件与音频实现，增加维护噪音
- 位置：`src/components/StatusIndicator.tsx:35`
- 位置：`src/components/TranscriptDisplay.tsx:27`
- 位置：`src/components/ErrorDisplay.tsx:21`
- 位置：`src/asr/audio-recorder.ts:12`
- 位置：`src/asr/pcm-converter.ts:43`

这些文件当前未被主链路引用；其中 `audio-recorder.ts` 仍基于 `createScriptProcessor`（已废弃 API）。

建议：删除死代码，或明确标记为实验代码并隔离目录。

#### L3. `loadConfig()` 死代码保留了危险凭据模式
- 位置：`src/asr/volcengine-client.ts:509`

该函数读取 `VITE_` 环境变量（构建期会内联到前端包），虽目前未被调用，但保留在仓库中容易被误用。

建议：删除该函数，凭证仅走 Rust 侧配置接口。

#### L4. CSP 包含 `unsafe-inline`
- 位置：`src-tauri/tauri.conf.json:33`

当前 CSP 为：`script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'`。在桌面应用中风险小于 Web 公网场景，但仍放宽了注入防护。

建议：尽量移除 `unsafe-inline`（至少先去掉 `script-src` 的 inline）。

#### L5. 缺少自动化测试入口（回归保障弱）
- 位置：`package.json:6`

无 `test` 脚本；现有 `scripts/test-*.mjs` 为手工烟测脚本，未纳入 CI，且依赖本地 `say/afconvert` 与真实云凭据。

建议：补充最小单测/集成测试并接入 CI（至少覆盖协议编解码和状态机）。

## 已验证项
- `pnpm -C ~/workspace/murmur exec tsc --noEmit`：通过
- `pnpm -C ~/workspace/murmur build`：通过
- `cargo check`：未执行（当前环境无 `cargo`）

## 优先级建议
1. 立即修复：H1
2. 本周修复：M1、M2、M3、M4
3. 迭代治理：M5、L1、L2、L3、L4、L5

## 备注
- 本次为静态审查 + 构建验证，不包含运行时渗透测试与系统权限对抗测试。
