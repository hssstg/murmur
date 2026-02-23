# Murmur 代码审查报告

审查日期：2026-02-23
范围：`src/`、`src-tauri/`、构建配置

## 结论（先看重点）
当前代码主链路可读性不错，且 TypeScript 类型检查通过；但存在 1 个高风险安全问题和 3 个中风险问题，建议先处理 P0/P1。

## 发现的问题（按严重度排序）

### P0-1 生产代码保留了 `/tmp` 文件触发的“伪热键”入口（高风险）
- 位置：`src-tauri/src/keyboard.rs:35`
- 位置：`src-tauri/src/keyboard.rs:36`
- 位置：`src-tauri/src/keyboard.rs:43`
- 位置：`src-tauri/src/keyboard.rs:56`

代码在常驻循环中检查 `/tmp/murmur_ptt_start` 与 `/tmp/murmur_ptt_stop`，任意本机进程都可以通过 `touch` 触发录音/停止流程，绕过真实热键输入。这在生产环境属于隐私与滥用风险。

建议：
1. 将该逻辑放到 `#[cfg(debug_assertions)]` 下，仅 debug 可用。
2. 更稳妥做法是删除文件触发逻辑，测试改走受控的命令通道。

### P1-1 识别文本被写入 `/tmp` 调试日志，存在敏感信息泄露面（中风险）
- 位置：`src/hooks/usePushToTalk.ts:188`
- 位置：`src/asr/volcengine-client.ts:495`
- 位置：`src-tauri/src/text.rs:9`

`flog` 会调用 `append_log`，而日志文件固定写入 `/tmp/murmur_debug.log`。当前日志内容包含最终识别文本（可能是账号、地址、口令片段等敏感信息）。

建议：
1. 生产构建禁用 `append_log` 或默认关闭。
2. 严禁记录全文识别结果；若需排障，仅记录长度、状态码、请求 ID。

### P1-2 Access Token 明文落盘（中风险）
- 位置：`src-tauri/src/config.rs:12`
- 位置：`src-tauri/src/config.rs:82`

`api_access_token` 以明文写入配置文件，读取本地配置文件即可直接拿到云 ASR 凭据。

建议：
1. Token 存到系统凭据存储（macOS Keychain）。
2. `config.json` 仅保存非敏感字段（如 App ID/Resource ID/UI 配置）。

### P1-3 WebSocket 响应解析缺少长度边界检查，异常帧可触发运行时异常（中风险）
- 位置：`src/asr/volcengine-client.ts:152`
- 位置：`src/asr/volcengine-client.ts:175`
- 位置：`src/asr/volcengine-client.ts:477`

`parseResponse` 在读取 `msgSize/payloadSize` 后直接切片和解码，没有先校验最小长度与边界。若收到截断/畸形二进制帧，`DataView.getInt32` 或后续解压/JSON 解析可能抛错，影响会话稳定性。

建议：
1. 在解析前校验 `data.length` 是否满足 `header + fields + payload`。
2. 在 `handleMessage` 外层增加兜底 `try/catch`，避免异常冒泡导致状态机异常。

### P2-1 键盘检测为 20ms 轮询，常驻 CPU 唤醒频率偏高（低风险）
- 位置：`src-tauri/src/keyboard.rs:66`

目前使用固定 20ms 轮询，长期运行对能耗不友好，且在负载高时对时序稳定性不如事件驱动。

建议：
1. 评估切换到系统级事件监听。
2. 若维持轮询，可按状态自适应间隔（空闲长、按住短）。

### P2-2 前后端默认 `resource_id` 不一致，降级路径可能直接失败（低风险）
- 位置：`src/settings/SettingsWindow.tsx:21`
- 位置：`src-tauri/src/config.rs:33`

前端默认 `api_resource_id` 是空字符串，Rust 默认值是 `volc.bigasr.sauc.duration`。当 `get_config` 失败并回退到前端默认值时，后续连接可能直接失败。

建议：统一默认值，避免“配置读取失败 -> 参数为空 -> 连接失败”的连锁问题。

## 验证记录
- 已执行：`pnpm -C ~/workspace/murmur exec tsc --noEmit`（通过）
- 未执行：`cargo check`（当前环境缺少 `cargo` 命令）

## 修复优先级建议
1. 立即处理：P0-1
2. 本周处理：P1-1、P1-2、P1-3
3. 迭代优化：P2-1、P2-2
