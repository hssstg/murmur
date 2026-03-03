import Foundation
import MurmurCore

@MainActor func runGzipUtilsTests() {
    suite("GzipUtils/roundtrip") {
        let original = "Hello, gzip! This is a test of compress and decompress.".data(using: .utf8)!
        let compressed = try GzipUtils.compress(original)
        let decompressed = try GzipUtils.decompress(compressed)
        check(decompressed == original, "roundtrip: decompress(compress(data)) == original")
    }

    suite("GzipUtils/emptyData") {
        let result = try GzipUtils.compress(Data())
        check(result == Data(), "compress(empty) == empty")
        let result2 = try GzipUtils.decompress(Data())
        check(result2 == Data(), "decompress(empty) == empty")
    }

    suite("GzipUtils/compressionReducesSize") {
        // Highly repetitive data compresses well
        let repetitive = Data(repeating: 0x41, count: 10000)
        let compressed = try GzipUtils.compress(repetitive)
        check(compressed.count < repetitive.count, "compressed size \(compressed.count) < original \(repetitive.count)")
    }
}
