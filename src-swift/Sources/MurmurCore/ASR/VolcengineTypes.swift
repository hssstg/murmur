import Foundation

public enum ASRStatus: String, Equatable, Sendable {
    case idle, connecting, listening, processing, polishing, done, error
}

public struct ASRResult: Sendable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public struct VolcengineConfig {
    public var appId: String
    public var accessToken: String
    public var resourceId: String
    public var language: String
    public var enablePunc: Bool
    public var enableItn: Bool
    public var enableDdc: Bool
    public var vocabulary: String?

    public init(from cfg: AppConfig) {
        appId       = cfg.api_app_id
        accessToken = cfg.api_access_token
        resourceId  = cfg.api_resource_id
        language    = cfg.asr_language
        enablePunc  = cfg.asr_enable_punc
        enableItn   = cfg.asr_enable_itn
        enableDdc   = cfg.asr_enable_ddc
        vocabulary  = cfg.asr_vocabulary.isEmpty ? nil : cfg.asr_vocabulary
    }
}
