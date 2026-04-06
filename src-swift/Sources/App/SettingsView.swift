import SwiftUI
import MurmurCore
import AVFoundation

struct SettingsView: View {
    @Binding var config: AppConfig
    var onSave: () -> Void

    @State private var saveLabel: String = L("common.save")

    var body: some View {
        TabView {
            GeneralTab(config: $config)
                .tabItem { Label(L("settings.tab.hotkey"), systemImage: "keyboard") }

            LLMTab(config: $config)
                .tabItem { Label(L("settings.tab.llm"), systemImage: "sparkles") }
        }
        .padding(20)
        .frame(width: 560, height: 480)
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
                    saveLabel = L("common.saved")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveLabel = L("common.save")
                    }
                }
            }
        }
    }
}

// MARK: - General Tab (Hotkey + Microphone)

private struct GeneralTab: View {
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
        (L("common.disabled"), nil),
        ("Middle",     "MouseMiddle"),
        ("Side Back",  "MouseSideBack"),
        ("Side Fwd",   "MouseSideFwd"),
    ]

    var body: some View {
        Form {
            Section {
                Picker(L("settings.hotkey.label"), selection: $config.hotkey) {
                    ForEach(hotkeyOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text(L("settings.hotkey.footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L("settings.mouseenter.label"), selection: $config.mouse_enter_btn) {
                    ForEach(mouseEnterOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text(L("settings.mouseenter.footer"))
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.mic.section")) {
                MicrophonePicker(selected: $config.microphone)
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
                Toggle(L("settings.llmpolish.enable"), isOn: $config.llm_enabled)
            } footer: {
                Text(L("settings.llmpolish.footer"))
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.llm.section")) {
                LabeledContent("Base URL") {
                    TextField("", text: $config.llm_base_url)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(L("settings.llm.model")) {
                    TextField("", text: $config.llm_model)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("API Key") {
                    SecretField("", text: $config.llm_api_key, show: $showKey)
                }
            }

            Section(L("settings.llm.prompt.section")) {
                TextEditor(text: $config.llm_prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                HStack {
                    Spacer()
                    Button(L("settings.llm.prompt.reset")) {
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
        Picker(L("settings.mic.label"), selection: $selected) {
            Text(L("common.system_default")).tag(Optional<String>.none)
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
