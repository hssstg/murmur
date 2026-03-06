import SwiftUI
import MurmurCore
import AVFoundation

struct SettingsView: View {
    @Binding var config: AppConfig
    var onSave: () -> Void

    @State private var saveLabel: LocalizedStringKey = "common.save"

    var body: some View {
        TabView {
            AsrTab(config: $config)
                .tabItem { Label("settings.tab.asr", systemImage: "waveform") }

            HotkeyTab(config: $config)
                .tabItem { Label("settings.tab.hotkey", systemImage: "keyboard") }

            LLMTab(config: $config)
                .tabItem { Label("settings.tab.llm", systemImage: "sparkles") }

            HotwordsTab(config: $config)
                .tabItem { Label("settings.tab.hotwords", systemImage: "text.book.closed") }
        }
        .padding(20)
        .frame(width: 560, height: 560)
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
                    saveLabel = "common.saved"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveLabel = "common.save"
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
            Section("settings.asr.section") {
                LabeledContent("App ID") {
                    TextField("", text: $config.api_app_id)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Access Token") {
                    SecretField("", text: $config.api_access_token, show: $showToken)
                }
                LabeledContent("Resource ID") {
                    TextField("", text: $config.api_resource_id)
                        .help("settings.asr.resourceid.help")
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("settings.asr2.section") {
                Picker("settings.asr.language", selection: $config.asr_language) {
                    ForEach(langOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                LabeledContent("settings.asr.vocabulary") {
                    TextField("", text: $config.asr_vocabulary)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("settings.asr.punc", isOn: $config.asr_enable_punc)
                Toggle("settings.asr.itn", isOn: $config.asr_enable_itn)
                Toggle("settings.asr.ddc", isOn: $config.asr_enable_ddc)
            }

            Section("settings.mic.section") {
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
        (String(localized: "common.disabled"), nil),
        ("Middle",     "MouseMiddle"),
        ("Side Back",  "MouseSideBack"),
        ("Side Fwd",   "MouseSideFwd"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("settings.hotkey.label", selection: $config.hotkey) {
                    ForEach(hotkeyOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text("settings.hotkey.footer")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("settings.mouseenter.label", selection: $config.mouse_enter_btn) {
                    ForEach(mouseEnterOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text("settings.mouseenter.footer")
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
                Toggle("settings.llmpolish.enable", isOn: $config.llm_enabled)
            } footer: {
                Text("settings.llmpolish.footer")
                    .foregroundStyle(.secondary)
            }

            Section("settings.llm.section") {
                LabeledContent("Base URL") {
                    TextField("", text: $config.llm_base_url)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("settings.llm.model") {
                    TextField("", text: $config.llm_model)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("API Key") {
                    SecretField("", text: $config.llm_api_key, show: $showKey)
                }
            }

            Section("settings.llm.prompt.section") {
                TextEditor(text: $config.llm_prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                HStack {
                    Spacer()
                    Button("settings.llm.prompt.reset") {
                        config.llm_prompt = defaultLLMPrompt
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
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
                Text("settings.hotwords.footer")
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
        Picker("settings.mic.label", selection: $selected) {
            Text("common.system_default").tag(Optional<String>.none)
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
