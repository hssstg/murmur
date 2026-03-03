import SwiftUI
import MurmurCore
import AVFoundation

struct SettingsView: View {
    @Binding var config: AppConfig
    var onSave: () -> Void

    @State private var saveLabel = "保存"

    var body: some View {
        TabView {
            AsrTab(config: $config)
                .tabItem { Label("语音识别", systemImage: "waveform") }

            HotkeyTab(config: $config)
                .tabItem { Label("快捷键", systemImage: "keyboard") }

            LLMTab(config: $config)
                .tabItem { Label("LLM 润色", systemImage: "sparkles") }

            HotwordsTab(config: $config)
                .tabItem { Label("热词凭证", systemImage: "text.book.closed") }
        }
        .padding(20)
        .frame(width: 480)
        .safeAreaInset(edge: .bottom) {
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Murmur v\(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 12)
            }
        }
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

// MARK: - ASR Tab

private struct AsrTab: View {
    @Binding var config: AppConfig
    @State private var showToken = false

    let langOptions: [(String, String)] = [
        ("中文", "zh-CN"), ("English", "en-US"),
        ("粤语", "zh-Yue"), ("日本語", "ja-JP"),
    ]

    var body: some View {
        Form {
            Section("凭证") {
                LabeledContent("App ID") {
                    TextField("", text: $config.api_app_id)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Access Token") {
                    SecretField("", text: $config.api_access_token, show: $showToken)
                }
                LabeledContent("Resource ID") {
                    TextField("volc.bigasr.sauc.duration", text: $config.api_resource_id)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("识别选项") {
                Picker("语言", selection: $config.asr_language) {
                    ForEach(langOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                LabeledContent("热词表名") {
                    TextField("", text: $config.asr_vocabulary)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("标点符号", isOn: $config.asr_enable_punc)
                Toggle("数字转换 (ITN)", isOn: $config.asr_enable_itn)
                Toggle("顺滑处理 (DDC)", isOn: $config.asr_enable_ddc)
            }

            Section("麦克风") {
                MicrophonePicker(selected: $config.microphone)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkey Tab

private struct HotkeyTab: View {
    @Binding var config: AppConfig

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

    let mouseEnterOptions: [(String, String?)] = [
        ("禁用", nil),
        ("Middle",     "MouseMiddle"),
        ("Side Back",  "MouseSideBack"),
        ("Side Fwd",   "MouseSideFwd"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("录音热键", selection: $config.hotkey) {
                    ForEach(hotkeyOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text("按住触发录音，松开后开始识别")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("鼠标 Enter 映射", selection: $config.mouse_enter_btn) {
                    ForEach(mouseEnterOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text("将指定鼠标键映射为 Enter，方便快速确认")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - LLM Tab

private struct LLMTab: View {
    @Binding var config: AppConfig
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                Toggle("识别后自动润色", isOn: $config.llm_enabled)
            } footer: {
                Text("调用 LLM 去语气词、修正同音错字、整理标点")
                    .foregroundStyle(.secondary)
            }

            Section("接口配置") {
                LabeledContent("Base URL") {
                    TextField("https://api.openai.com/", text: $config.llm_base_url)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("模型") {
                    TextField("gpt-4o", text: $config.llm_model)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("API Key") {
                    SecretField("", text: $config.llm_api_key, show: $showKey)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotwords Tab

private struct HotwordsTab: View {
    @Binding var config: AppConfig
    @State private var showAk = false
    @State private var showSk = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Access Key ID") {
                    SecretField("", text: $config.hotwords_ak, show: $showAk)
                }
                LabeledContent("Secret Access Key") {
                    SecretField("", text: $config.hotwords_sk, show: $showSk)
                }
            } footer: {
                Text("火山引擎自学习平台凭证，用于热词同步")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

private struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var show: Bool

    init(_ placeholder: String, text: Binding<String>, show: Binding<Bool>) {
        self.placeholder = placeholder
        self._text = text
        self._show = show
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if show {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .multilineTextAlignment(.trailing)

            Button {
                show.toggle()
            } label: {
                Image(systemName: show ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
