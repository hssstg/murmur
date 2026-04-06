import Foundation
import CSherpaOnnx

/// Local streaming ASR using sherpa-onnx.
/// The recognizer (model) is loaded once and reused across sessions.
/// Each PTT session creates a lightweight stream owned by its decode thread.
public class SherpaRecognizer: @unchecked Sendable {
    public var onStatus: ((ASRStatus) -> Void)?
    public var onResult: ((ASRResult) -> Void)?
    public var onError:  ((Error) -> Void)?

    private let recognizer: OpaquePointer
    private var punctuation: OpaquePointer?
    private let lock = NSLock()

    // Current session — protected by lock
    private var activeStream: OpaquePointer?
    private var generation: Int = 0
    private var inputEnded = false

    public init?(modelDir: String, numThreads: Int = 2) {
        let encoderPath = (modelDir as NSString).appendingPathComponent("encoder.int8.onnx")
        let decoderPath = (modelDir as NSString).appendingPathComponent("decoder.int8.onnx")
        let tokensPath  = (modelDir as NSString).appendingPathComponent("tokens.txt")

        guard FileManager.default.fileExists(atPath: encoderPath) else {
            fputs("[SherpaRecognizer] encoder not found: \(encoderPath)\n", stderr)
            return nil
        }

        var config = SherpaOnnxOnlineRecognizerConfig(
            feat_config: SherpaOnnxFeatureConfig(sample_rate: 16000, feature_dim: 80),
            model_config: SherpaOnnxOnlineModelConfig(
                transducer: SherpaOnnxOnlineTransducerModelConfig(
                    encoder: strdup(""), decoder: strdup(""), joiner: strdup("")
                ),
                paraformer: SherpaOnnxOnlineParaformerModelConfig(
                    encoder: strdup(encoderPath), decoder: strdup(decoderPath)
                ),
                zipformer2_ctc: SherpaOnnxOnlineZipformer2CtcModelConfig(model: strdup("")),
                tokens: strdup(tokensPath),
                num_threads: Int32(numThreads),
                provider: strdup("cpu"),
                debug: 0,
                model_type: strdup("paraformer"),
                modeling_unit: strdup("cjkchar"),
                bpe_vocab: strdup(""),
                tokens_buf: strdup(""),
                tokens_buf_size: 0,
                nemo_ctc: SherpaOnnxOnlineNemoCtcModelConfig(model: strdup("")),
                t_one_ctc: SherpaOnnxOnlineToneCtcModelConfig(model: strdup(""))
            ),
            decoding_method: strdup("greedy_search"),
            max_active_paths: 4,
            enable_endpoint: 0,
            rule1_min_trailing_silence: 2.4,
            rule2_min_trailing_silence: 0.8,
            rule3_min_utterance_length: 30,
            hotwords_file: strdup(""),
            hotwords_score: 1.5,
            ctc_fst_decoder_config: SherpaOnnxOnlineCtcFstDecoderConfig(
                graph: strdup(""), max_active: 3000
            ),
            rule_fsts: strdup(""),
            rule_fars: strdup(""),
            blank_penalty: 0.0,
            hotwords_buf: strdup(""),
            hotwords_buf_size: 0,
            hr: SherpaOnnxHomophoneReplacerConfig(
                dict_dir: strdup(""), lexicon: strdup(""), rule_fsts: strdup("")
            )
        )

        guard let rec = SherpaOnnxCreateOnlineRecognizer(&config) else {
            fputs("[SherpaRecognizer] failed to create recognizer\n", stderr)
            return nil
        }
        self.recognizer = rec
        fputs("[SherpaRecognizer] model loaded from \(modelDir)\n", stderr)

        let punctDir = ((modelDir as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("punct-ct-transformer-zh-en")
        let punctModel = (punctDir as NSString).appendingPathComponent("model.onnx")
        if FileManager.default.fileExists(atPath: punctModel) {
            var punctConfig = SherpaOnnxOfflinePunctuationConfig(
                model: SherpaOnnxOfflinePunctuationModelConfig(
                    ct_transformer: strdup(punctModel),
                    num_threads: Int32(numThreads),
                    debug: 0,
                    provider: strdup("cpu")
                )
            )
            self.punctuation = SherpaOnnxCreateOfflinePunctuation(&punctConfig)
            fputs("[SherpaRecognizer] punctuation model loaded\n", stderr)
        }
    }

    deinit {
        lock.lock()
        if let s = activeStream { SherpaOnnxDestroyOnlineStream(s) }
        activeStream = nil
        lock.unlock()
        if let p = punctuation { SherpaOnnxDestroyOfflinePunctuation(p) }
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    /// Start a new recognition session.
    public func startSession() {
        lock.lock()
        generation += 1
        let myGen = generation
        // Don't destroy old stream here — old decode thread still owns it
        // Just detach it so sendAudio goes to the new stream
        let newStream = SherpaOnnxCreateOnlineStream(recognizer)!
        activeStream = newStream
        inputEnded = false
        lock.unlock()

        fputs("[SherpaRecognizer] session \(myGen) started\n", stderr)
        onStatus?(.listening)

        // Decode thread owns `newStream` — it will destroy it when done
        let thread = Thread { [weak self] in
            self?.decodeLoop(gen: myGen, stream: newStream)
        }
        thread.name = "sherpa-decode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Feed raw Int16 PCM audio (16kHz mono).
    public func sendAudio(_ data: Data) {
        let floats = int16ToFloat(data)
        lock.lock()
        guard let s = activeStream else { lock.unlock(); return }
        SherpaOnnxOnlineStreamAcceptWaveform(s, 16000, floats, Int32(floats.count))
        lock.unlock()
    }

    /// Signal end of audio.
    public func finishAudio() {
        lock.lock()
        guard let s = activeStream else { lock.unlock(); return }
        // 1s silence tail — gives the model time to finalize the last token
        let tail = [Float](repeating: 0.0, count: 16000)
        SherpaOnnxOnlineStreamAcceptWaveform(s, 16000, tail, Int32(tail.count))
        SherpaOnnxOnlineStreamInputFinished(s)
        inputEnded = true
        lock.unlock()
        onStatus?(.processing)
    }

    /// Stop the current session without waiting for result.
    public func stopSession() {
        lock.lock()
        generation += 1
        activeStream = nil  // detach — decode thread will clean up its own stream
        inputEnded = false
        lock.unlock()
        onStatus?(.idle)
    }

    // MARK: - Private

    /// Decode loop — owns and destroys `stream` when done.
    private func decodeLoop(gen: Int, stream: OpaquePointer) {
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        var lastText = ""

        while true {
            // Check if this session is still active
            lock.lock()
            let stillActive = (generation == gen)
            let ended = inputEnded
            lock.unlock()

            guard stillActive else { return }

            // Decode available frames (no lock needed — only this thread decodes this stream)
            var decoded = false
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
                decoded = true
            }

            // Emit partial result
            if let resultPtr = SherpaOnnxGetOnlineStreamResult(recognizer, stream) {
                let text = resultPtr.pointee.text.map { String(cString: $0) } ?? ""
                SherpaOnnxDestroyOnlineRecognizerResult(resultPtr)
                if text != lastText {
                    lastText = text
                    onResult?(ASRResult(text: text, isFinal: false))
                }
            }

            // Input finished + nothing left to decode → emit final
            if ended && !decoded {
                if let resultPtr = SherpaOnnxGetOnlineStreamResult(recognizer, stream) {
                    let rawText = resultPtr.pointee.text.map { String(cString: $0) } ?? ""
                    SherpaOnnxDestroyOnlineRecognizerResult(resultPtr)
                    let text = addPunctuation(rawText)
                    fputs("[SherpaRecognizer] session \(gen) final: \(text)\n", stderr)
                    onResult?(ASRResult(text: text, isFinal: true))
                }
                onStatus?(.done)
                return
            }

            if !decoded {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(samples[$0]) / 32768.0 }
        }
    }

    private func addPunctuation(_ text: String) -> String {
        guard let p = punctuation, !text.isEmpty else { return text }
        guard let cResult = SherpaOfflinePunctuationAddPunct(p, (text as NSString).utf8String) else {
            return text
        }
        let result = String(cString: cResult)
        SherpaOfflinePunctuationFreeText(cResult)
        return result
    }
}
