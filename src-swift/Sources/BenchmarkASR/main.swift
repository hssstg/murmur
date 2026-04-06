import Foundation
import CSherpaOnnx

let punctModel = "/Users/locke/workspace/murmur/models/punct-ct-transformer-zh-en/model.onnx"

print("Loading punctuation model...")
let start = CFAbsoluteTimeGetCurrent()

var config = SherpaOnnxOfflinePunctuationConfig(
    model: SherpaOnnxOfflinePunctuationModelConfig(
        ct_transformer: strdup(punctModel),
        num_threads: 2,
        debug: 0,
        provider: strdup("cpu")
    )
)

guard let punct = SherpaOnnxCreateOfflinePunctuation(&config) else {
    print("ERROR: Failed to create punctuation model")
    exit(1)
}
let loadTime = CFAbsoluteTimeGetCurrent() - start
print("Punctuation model loaded in \(String(format: "%.2f", loadTime))s")

// Test with Chinese text
let testCases = [
    "你好我是语音助手",
    "今天天气怎么样明天会下雨吗",
    "我想买一杯咖啡一个面包",
    "hello how are you I am fine thank you",
]

for text in testCases {
    let t0 = CFAbsoluteTimeGetCurrent()
    let cResult = SherpaOfflinePunctuationAddPunct(punct, (text as NSString).utf8String)!
    let result = String(cString: cResult)
    SherpaOfflinePunctuationFreeText(cResult)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    print("[\(String(format: "%.0f", elapsed * 1000))ms] \(text) → \(result)")
}

SherpaOnnxDestroyOfflinePunctuation(punct)
print("Done")
