import Foundation

public struct AppConfig: Codable, Sendable {
    public var api_app_id: String
    public var api_access_token: String
    public var api_resource_id: String
    public var hotkey: String
    public var microphone: String?
    public var asr_language: String
    public var asr_enable_punc: Bool
    public var asr_enable_itn: Bool
    public var asr_enable_ddc: Bool
    public var asr_vocabulary: String
    public var llm_enabled: Bool
    public var llm_base_url: String
    public var llm_model: String
    public var llm_api_key: String
    public var mouse_enter_btn: String?

    public init() {
        api_app_id = ""
        api_access_token = ""
        api_resource_id = "volc.bigasr.sauc.duration"
        hotkey = "ROption"
        microphone = nil
        asr_language = "zh-CN"
        asr_enable_punc = true
        asr_enable_itn = true
        asr_enable_ddc = true
        asr_vocabulary = ""
        llm_enabled = false
        llm_base_url = ""
        llm_model = ""
        llm_api_key = ""
        mouse_enter_btn = nil
    }

    private enum CodingKeys: String, CodingKey {
        case api_app_id, api_access_token, api_resource_id, hotkey, microphone
        case asr_language, asr_enable_punc, asr_enable_itn, asr_enable_ddc, asr_vocabulary
        case llm_enabled, llm_base_url, llm_model, llm_api_key, mouse_enter_btn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api_app_id       = try c.decodeIfPresent(String.self, forKey: .api_app_id) ?? ""
        api_access_token = try c.decodeIfPresent(String.self, forKey: .api_access_token) ?? ""
        api_resource_id  = try c.decodeIfPresent(String.self, forKey: .api_resource_id) ?? "volc.bigasr.sauc.duration"
        hotkey           = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "ROption"
        microphone       = try c.decodeIfPresent(String.self, forKey: .microphone)
        asr_language     = try c.decodeIfPresent(String.self, forKey: .asr_language) ?? "zh-CN"
        asr_enable_punc  = try c.decodeIfPresent(Bool.self, forKey: .asr_enable_punc) ?? true
        asr_enable_itn   = try c.decodeIfPresent(Bool.self, forKey: .asr_enable_itn) ?? true
        asr_enable_ddc   = try c.decodeIfPresent(Bool.self, forKey: .asr_enable_ddc) ?? true
        asr_vocabulary   = try c.decodeIfPresent(String.self, forKey: .asr_vocabulary) ?? ""
        llm_enabled      = try c.decodeIfPresent(Bool.self, forKey: .llm_enabled) ?? false
        llm_base_url     = try c.decodeIfPresent(String.self, forKey: .llm_base_url) ?? ""
        llm_model        = try c.decodeIfPresent(String.self, forKey: .llm_model) ?? ""
        llm_api_key      = try c.decodeIfPresent(String.self, forKey: .llm_api_key) ?? ""
        mouse_enter_btn  = try c.decodeIfPresent(String.self, forKey: .mouse_enter_btn)
    }
}

// MARK: - ConfigStore

public class ConfigStore {
    public var config: AppConfig

    public static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.locke.murmur")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    public init() {
        config = AppConfig()
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return }
        config = cfg
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: Self.configURL, options: .atomic)
    }
}
