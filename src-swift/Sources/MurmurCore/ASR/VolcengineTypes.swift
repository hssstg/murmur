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
