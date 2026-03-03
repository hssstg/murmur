import SwiftUI
import MurmurCore
import AVFoundation

struct SettingsView: View {
    @Binding var config: AppConfig
    var onSave: () -> Void

    @State private var saveLabel   = "保存"
    @State private var showApiKey  = false
    @State private var showLlmKey  = false
    @State private var showHwAk    = false
    @State private var showHwSk    = false

    let hotkeyOptions: [(String, String)] = [
        ("Right Option (⌥)", "ROption"),
        ("Left Option (⌥)",  "LOption"),
        ("Right Control (^)", "RControl"),
        ("Left Control (^)",  "LControl"),
        ("Middle Mouse",      "MouseMiddle"),
        ("Side Back (M4)",    "MouseSideBack"),
        ("Side Fwd (M5)",     "MouseSideFwd"),
        ("F13", "F13"), ("F14", "F14"), ("F15", "F15"),
    ]

    let langOptions: [(String, String)] = [
        ("中文", "zh-CN"),
        ("English", "en-US"),
        ("粤语", "zh-Yue"),
        ("日本語", "ja-JP"),
    ]

    let mouseEnterOptions: [(String, String?)] = [
        ("禁用", nil),
        ("Middle", "MouseMiddle"),
        ("Side Back", "MouseSideBack"),
        ("Side Fwd", "MouseSideFwd"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("AppID", text: $config.api_app_id)
                    .help("火山引擎控制台 → 语音技术 → 应用管理 → AppID")
                HStack {
                    if showApiKey {
                        TextField("Access Token", text: $config.api_access_token)
                    } else {
                        SecureField("Access Token", text: $config.api_access_token)
                    }
                    Button { showApiKey.toggle() } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }.buttonStyle(.plain)
                }
                .help("火山引擎控制台 → 语音技术 → 应用管理 → Access Token")
                TextField("Resource ID", text: $config.api_resource_id)
                    .help("默认：volc.bigasr.sauc.duration")
            } header: {
                Text("火山引擎 ASR")
            } footer: {
                Text("凭证在火山引擎控制台 speech.volcengine.com 获取")
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                Picker("热键", selection: $config.hotkey) {
                    ForEach(hotkeyOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Picker("鼠标 Enter", selection: $config.mouse_enter_btn) {
                    ForEach(mouseEnterOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
            }

            Section("语音识别") {
                Picker("语言", selection: $config.asr_language) {
                    ForEach(langOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Toggle("标点符号", isOn: $config.asr_enable_punc)
                Toggle("数字转换 (ITN)", isOn: $config.asr_enable_itn)
                Toggle("顺滑处理 (DDC)", isOn: $config.asr_enable_ddc)
                TextField("热词表名", text: $config.asr_vocabulary)
            }

            Section("LLM 润色") {
                Toggle("启用 LLM 润色", isOn: $config.llm_enabled)
                if config.llm_enabled {
                    TextField("Base URL", text: $config.llm_base_url)
                    TextField("模型", text: $config.llm_model)
                    HStack {
                        if showLlmKey {
                            TextField("API Key", text: $config.llm_api_key)
                        } else {
                            SecureField("API Key", text: $config.llm_api_key)
                        }
                        Button { showLlmKey.toggle() } label: {
                            Image(systemName: showLlmKey ? "eye.slash" : "eye")
                        }.buttonStyle(.plain)
                    }
                }
            }

            Section("热词凭证（火山自学习平台）") {
                HStack {
                    if showHwAk {
                        TextField("Access Key ID", text: $config.hotwords_ak)
                    } else {
                        SecureField("Access Key ID", text: $config.hotwords_ak)
                    }
                    Button { showHwAk.toggle() } label: {
                        Image(systemName: showHwAk ? "eye.slash" : "eye")
                    }.buttonStyle(.plain)
                }
                HStack {
                    if showHwSk {
                        TextField("Secret Access Key", text: $config.hotwords_sk)
                    } else {
                        SecureField("Secret Access Key", text: $config.hotwords_sk)
                    }
                    Button { showHwSk.toggle() } label: {
                        Image(systemName: showHwSk ? "eye.slash" : "eye")
                    }.buttonStyle(.plain)
                }
            }

            Section("麦克风") {
                MicrophonePicker(selected: $config.microphone)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saveLabel) {
                    onSave()
                    saveLabel = "已保存 ✓"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveLabel = "保存"
                    }
                }
            }
        }
    }
}

struct MicrophonePicker: View {
    @Binding var selected: String?
    @State private var devices: [(id: String, name: String)] = []

    var body: some View {
        Picker("麦克风", selection: $selected) {
            Text("系统默认").tag(Optional<String>.none)
            ForEach(devices, id: \.id) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
        .onAppear {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )
            devices = session.devices
                .filter { !$0.localizedName.hasPrefix("CA") }
                .map { (id: $0.uniqueID, name: $0.localizedName) }
        }
    }
}
