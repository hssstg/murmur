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
    check(!cfg.llm_enabled, "llm_enabled default false")
    check(cfg.microphone == nil, "microphone default nil")
    check(cfg.mouse_enter_btn == nil, "mouse_enter_btn default nil")
}

suite("testRoundtrip") {
    var cfg = AppConfig()
    cfg.hotkey = "LControl"
    cfg.llm_enabled = true
    cfg.llm_model = "gpt-4"
    cfg.mouse_enter_btn = "MouseSideBack"
    cfg.microphone = "DJI Mic Mini"

    let data = try JSONEncoder().encode(cfg)
    let restored = try JSONDecoder().decode(AppConfig.self, from: data)

    assertEqual(restored.hotkey, "LControl", "hotkey roundtrip")
    check(restored.llm_enabled, "llm_enabled roundtrip")
    assertEqual(restored.llm_model, "gpt-4", "llm_model roundtrip")
    assertEqual(restored.mouse_enter_btn, "MouseSideBack", "mouse_enter_btn roundtrip")
    assertEqual(restored.microphone, "DJI Mic Mini", "microphone roundtrip")
}

suite("testMissingFieldsUseDefaults") {
    // Old config JSON with Volcengine fields — should decode gracefully (unknown keys ignored)
    let json = """
    {"hotkey":"ROption","llm_enabled":false}
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
    check(!cfg.llm_enabled, "llm_enabled defaults when missing")
    check(cfg.mouse_enter_btn == nil, "mouse_enter_btn nil when missing")
    check(cfg.microphone == nil, "microphone nil when missing")
}

suite("testMicrophoneNullAndSome") {
    let jsonNull = #"{"hotkey":"ROption","microphone":null}"#.data(using: .utf8)!
    let cfgNull = try JSONDecoder().decode(AppConfig.self, from: jsonNull)
    check(cfgNull.microphone == nil, "microphone null -> nil")

    let jsonSome = #"{"hotkey":"ROption","microphone":"DJI Mic Mini"}"#.data(using: .utf8)!
    let cfgSome = try JSONDecoder().decode(AppConfig.self, from: jsonSome)
    assertEqual(cfgSome.microphone, "DJI Mic Mini", "microphone some -> value")
}

// MARK: - PushToTalk Tests

runPushToTalkTests()

// MARK: - Results

print("\nResults: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
