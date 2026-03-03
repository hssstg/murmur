import SwiftUI
import MurmurCore
import AVFoundation

struct SettingsView: View {
    @Binding var config: AppConfig
    var onSave: () -> Void

    @State private var saveLabel: LocalizedStringKey = "common.save"
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
        (String(localized: "common.disabled"), nil),
        ("Middle", "MouseMiddle"),
        ("Side Back", "MouseSideBack"),
        ("Side Fwd", "MouseSideFwd"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("AppID", text: $config.api_app_id)
                    .help("settings.asr.appid.help")
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
                .help("settings.asr.token.help")
                TextField("Resource ID", text: $config.api_resource_id)
                    .help("settings.asr.resourceid.help")
            } header: {
                Text("settings.asr.section")
            } footer: {
                Text("settings.asr.footer")
                    .foregroundStyle(.secondary)
            }

            Section("settings.hotkey.section") {
                Picker("settings.hotkey.label", selection: $config.hotkey) {
                    ForEach(hotkeyOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Picker("settings.mouseenter.label", selection: $config.mouse_enter_btn) {
                    ForEach(mouseEnterOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
            }

            Section("settings.asr2.section") {
                Picker("settings.asr.language", selection: $config.asr_language) {
                    ForEach(langOptions, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Toggle("settings.asr.punc", isOn: $config.asr_enable_punc)
                Toggle("settings.asr.itn", isOn: $config.asr_enable_itn)
                Toggle("settings.asr.ddc", isOn: $config.asr_enable_ddc)
                TextField("settings.asr.vocabulary", text: $config.asr_vocabulary)
            }

            Section("settings.llm.section") {
                TextField("Base URL", text: $config.llm_base_url)
                    .help("settings.llm.baseurl.help")
                TextField("settings.llm.model", text: $config.llm_model)
                    .help("settings.llm.model.help")
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

            Section("settings.llmpolish.section") {
                Toggle("settings.llmpolish.enable", isOn: $config.llm_enabled)
            }

            Section("settings.hotwords.section") {
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

            Section("settings.mic.section") {
                MicrophonePicker(selected: $config.microphone)
            }
        }
        .formStyle(.grouped)
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
