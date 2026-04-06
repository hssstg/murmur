import Foundation
import CSherpaOnnx

/// Local offline ASR using sherpa-onnx SenseVoice.
/// The recognizer (model) is loaded once at startup and reused across sessions.
/// Audio is accumulated during a PTT session, then decoded in one shot on release.
public class SherpaRecognizer: @unchecked Sendable {
    public var onStatus: ((ASRStatus) -> Void)?
    public var onResult: ((ASRResult) -> Void)?

    private let recognizer: OpaquePointer
    private let lock = NSLock()

    private static let silenceRmsThreshold: Float = 0.005

    // Accumulated Float32 audio for the current session
    private var audioBuffer: [Float] = []
    private var sessionActive = false

    public init?(modelDir: String, numThreads: Int = 2) {
        let modelPath = (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        let tokensPath = (modelDir as NSString).appendingPathComponent("tokens.txt")

        guard FileManager.default.fileExists(atPath: modelPath) else {
            fputs("[SherpaRecognizer] model not found: \(modelPath)\n", stderr)
            return nil
        }

        var config = SherpaOnnxOfflineRecognizerConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = UnsafePointer(strdup(modelPath))
        config.model_config.sense_voice.language = UnsafePointer(strdup("auto"))
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = UnsafePointer(strdup(tokensPath))
        config.model_config.num_threads = Int32(numThreads)
        config.model_config.provider = UnsafePointer(strdup("cpu"))
        config.model_config.debug = 0
        config.decoding_method = UnsafePointer(strdup("greedy_search"))

        guard let rec = SherpaOnnxCreateOfflineRecognizer(&config) else {
            fputs("[SherpaRecognizer] failed to create offline recognizer\n", stderr)
            return nil
        }
        self.recognizer = rec
        fputs("[SherpaRecognizer] SenseVoice model loaded from \(modelDir)\n", stderr)
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Start a new recognition session (just resets the audio buffer).
    public func startSession() {
        lock.lock()
        audioBuffer.removeAll(keepingCapacity: true)
        sessionActive = true
        lock.unlock()
        fputs("[SherpaRecognizer] session started\n", stderr)
    }

    /// Feed raw Int16 PCM audio (16kHz mono). Accumulated for offline decode.
    public func sendAudio(_ data: Data) {
        let floats = int16ToFloat(data)
        lock.lock()
        audioBuffer.append(contentsOf: floats)
        lock.unlock()
    }

    /// Signal end of audio — runs offline decode and emits final result.
    /// Callbacks are dispatched back to the main thread to avoid data races.
    public func finishAudio() {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        sessionActive = false
        let samples = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        onStatus?(.processing)

        guard !samples.isEmpty else {
            fputs("[SherpaRecognizer] finishAudio: empty audio\n", stderr)
            onResult?(ASRResult(text: "", isFinal: true))
            return
        }

        // Skip recognition if audio is too quiet (silence/noise → hallucination)
        let sumSq = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = Float(sqrt(sumSq / Double(samples.count)))
        if rms < Self.silenceRmsThreshold {
            fputs("[SherpaRecognizer] finishAudio: audio too quiet (rms=\(String(format: "%.4f", rms))), skipping\n", stderr)
            onResult?(ASRResult(text: "", isFinal: true))
            return
        }

        let duration = Double(samples.count) / 16000.0
        fputs("[SherpaRecognizer] decoding \(String(format: "%.1f", duration))s audio...\n", stderr)

        // Run offline decode on a background thread to avoid blocking the caller.
        // Dispatch callbacks back to main thread to avoid data races on closure properties.
        let rec = recognizer
        Thread.detachNewThread { [weak self] in
            guard let stream = SherpaOnnxCreateOfflineStream(rec) else {
                fputs("[SherpaRecognizer] failed to create offline stream\n", stderr)
                DispatchQueue.main.async { self?.onResult?(ASRResult(text: "", isFinal: true)) }
                return
            }
            defer { SherpaOnnxDestroyOfflineStream(stream) }

            samples.withUnsafeBufferPointer { buf in
                SherpaOnnxAcceptWaveformOffline(stream, 16000, buf.baseAddress, Int32(buf.count))
            }
            SherpaOnnxDecodeOfflineStream(rec, stream)

            let resultPtr = SherpaOnnxGetOfflineStreamResult(stream)
            let text = resultPtr?.pointee.text.map { String(cString: $0) } ?? ""
            if let r = resultPtr { SherpaOnnxDestroyOfflineRecognizerResult(r) }

            fputs("[SherpaRecognizer] result: \(text)\n", stderr)
            DispatchQueue.main.async {
                self?.onResult?(ASRResult(text: text, isFinal: true))
                self?.onStatus?(.done)
            }
        }
    }

    /// Stop the current session without decoding.
    public func stopSession() {
        lock.lock()
        sessionActive = false
        audioBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        onStatus?(.idle)
    }

    // MARK: - Private

    private func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(samples[$0]) / 32768.0 }
        }
    }
}
