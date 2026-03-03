import Foundation
import MurmurCore

// Minimal test harness
nonisolated(unsafe) private var passed = 0
nonisolated(unsafe) private var failed = 0

@MainActor func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        print("  PASS: \(message)")
        passed += 1
    } else {
        print("  FAIL: \(message) (\(file):\(line))")
        failed += 1
    }
}

@MainActor func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    check(a == b, "\(message) [got \(a), expected \(b)]", file: file, line: line)
}

@MainActor func suite(_ name: String, _ body: () throws -> Void) {
    print("Suite: \(name)")
    do { try body() } catch { print("  ERROR: \(error)"); failed += 1 }
}

// MARK: - Tests

suite("testDefaults") {
    let cfg = AppConfig()
    assertEqual(cfg.hotkey, "ROption", "hotkey default")
    assertEqual(cfg.api_resource_id, "volc.bigasr.sauc.duration", "api_resource_id default")
    assertEqual(cfg.asr_language, "zh-CN", "asr_language default")
    check(cfg.asr_enable_punc, "asr_enable_punc default true")
    check(cfg.asr_enable_itn, "asr_enable_itn default true")
    check(cfg.asr_enable_ddc, "asr_enable_ddc default true")
    check(!cfg.llm_enabled, "llm_enabled default false")
    check(cfg.microphone == nil, "microphone default nil")
    check(cfg.mouse_enter_btn == nil, "mouse_enter_btn default nil")
    assertEqual(cfg.asr_vocabulary, "", "asr_vocabulary default")
    assertEqual(cfg.api_app_id, "", "api_app_id default")
}

suite("testRoundtrip") {
    var cfg = AppConfig()
    cfg.api_app_id = "testapp"
    cfg.hotkey = "LControl"
    cfg.llm_enabled = true
    cfg.llm_model = "gpt-4"
    cfg.mouse_enter_btn = "MouseSideBack"
    cfg.microphone = "DJI Mic Mini"

    let data = try JSONEncoder().encode(cfg)
    let restored = try JSONDecoder().decode(AppConfig.self, from: data)

    assertEqual(restored.api_app_id, "testapp", "api_app_id roundtrip")
    assertEqual(restored.hotkey, "LControl", "hotkey roundtrip")
    check(restored.llm_enabled, "llm_enabled roundtrip")
    assertEqual(restored.llm_model, "gpt-4", "llm_model roundtrip")
    assertEqual(restored.mouse_enter_btn, "MouseSideBack", "mouse_enter_btn roundtrip")
    assertEqual(restored.microphone, "DJI Mic Mini", "microphone roundtrip")
}

suite("testMissingFieldsUseDefaults") {
    let json = """
    {"api_app_id":"123","api_access_token":"tok","api_resource_id":"volc.bigasr.sauc.duration","hotkey":"ROption"}
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
    assertEqual(cfg.asr_language, "zh-CN", "asr_language defaults when missing")
    check(cfg.asr_enable_punc, "asr_enable_punc defaults when missing")
    check(!cfg.llm_enabled, "llm_enabled defaults when missing")
    check(cfg.mouse_enter_btn == nil, "mouse_enter_btn nil when missing")
    check(cfg.microphone == nil, "microphone nil when missing")
}

suite("testMicrophoneNullAndSome") {
    let jsonNull = #"{"api_app_id":"","api_access_token":"","api_resource_id":"","hotkey":"ROption","microphone":null}"#.data(using: .utf8)!
    let cfgNull = try JSONDecoder().decode(AppConfig.self, from: jsonNull)
    check(cfgNull.microphone == nil, "microphone null -> nil")

    let jsonSome = #"{"api_app_id":"","api_access_token":"","api_resource_id":"","hotkey":"ROption","microphone":"DJI Mic Mini"}"#.data(using: .utf8)!
    let cfgSome = try JSONDecoder().decode(AppConfig.self, from: jsonSome)
    assertEqual(cfgSome.microphone, "DJI Mic Mini", "microphone some -> value")
}

// MARK: - GzipUtils Tests

runGzipUtilsTests()

// MARK: - VolcengineProtocol Tests

runVolcengineProtocolTests()

// MARK: - Results

print("\nResults: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
