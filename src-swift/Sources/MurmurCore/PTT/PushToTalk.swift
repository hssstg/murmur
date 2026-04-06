import Foundation

@MainActor
public class PushToTalk {
    public private(set) var status: ASRStatus = .idle
    public private(set) var currentText: String = ""
    public private(set) var audioLevels: [Float] = Array(repeating: 0, count: 16)
    public private(set) var isSessionActive = false

    public var onStatusChange: ((ASRStatus) -> Void)?
    public var onTextChange:   ((String) -> Void)?
    public var onAudioLevels:  (([Float]) -> Void)?

    private var config: AppConfig
    private var recognizer: SherpaRecognizer?
    private var idleTimer: Task<Void, Never>?
    private var peakRms: Float = 0
    private var sessionGeneration: Int = 0
    private var audioBuffer: Data = Data()  // accumulate PCM for saving

    public init(config: AppConfig) {
        self.config = config
        // Pre-load recognizer on a background thread
        Task.detached { [weak self] in
            let modelDir = Self.modelDirectory()
            fputs("[PushToTalk] loading model from \(modelDir)\n", stderr)
            let rec = SherpaRecognizer(modelDir: modelDir)
            await MainActor.run { [weak self] in
                self?.recognizer = rec
                if rec == nil {
                    fputs("[PushToTalk] WARNING: model failed to load\n", stderr)
                } else {
                    fputs("[PushToTalk] model ready\n", stderr)
                }
            }
        }
    }

    public func updateConfig(_ cfg: AppConfig) {
        config = cfg
    }

    // MARK: - PTT events

    public func handleStart() {
        fputs("[PTT] handleStart called, isSessionActive=\(isSessionActive)\n", stderr)
        guard !isSessionActive else {
            fputs("[PTT] handleStart skipped — session already active\n", stderr)
            return
        }
        guard let rec = recognizer else {
            fputs("[PTT] handleStart skipped — recognizer not loaded\n", stderr)
            return
        }

        sessionGeneration += 1
        let myGeneration = sessionGeneration
        isSessionActive = true
        fputs("[PTT] session \(myGeneration) starting\n", stderr)
        idleTimer?.cancel()
        idleTimer = nil

        audioLevels = Array(repeating: 0, count: 16)
        peakRms = 0
        currentText = ""
        audioBuffer = Data()

        // SenseVoice fires onResult once with the final result after finishAudio
        rec.onResult = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == myGeneration else { return }
                self.currentText = result.text
                self.onTextChange?(result.text)

                var textToInsert = result.text
                if !textToInsert.isEmpty {
                    let cfg = self.config
                    if cfg.llm_enabled && !cfg.llm_base_url.isEmpty {
                        guard self.sessionGeneration == myGeneration else { return }
                        self.setStatus(.polishing)
                        textToInsert = await LLMClient.polish(text: textToInsert, config: cfg)
                    }
                    guard self.sessionGeneration == myGeneration else { return }
                    await TextInserter.insert(textToInsert)
                }

                guard self.sessionGeneration == myGeneration else { return }
                if textToInsert.isEmpty {
                    self.currentText = ""
                    self.setStatus(.idle)
                    fputs("[PTT] session \(myGeneration) done (empty)\n", stderr)
                } else {
                    self.setStatus(.done)
                    self.scheduleIdleReset(after: 0.8)
                    fputs("[PTT] session \(myGeneration) done: \(textToInsert)\n", stderr)
                }
            }
        }
        rec.onStatus = { [weak self] s in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == myGeneration else { return }
                self.setStatus(s)
            }
        }

        setStatus(.listening)
        rec.startSession()
    }

    public func handleStop() {
        fputs("[PTT] handleStop called, isSessionActive=\(isSessionActive)\n", stderr)
        guard isSessionActive else {
            fputs("[PTT] handleStop skipped — no active session\n", stderr)
            return
        }
        isSessionActive = false
        fputs("[PTT] session \(sessionGeneration) stopping\n", stderr)

        // Save audio to WAV for benchmark (skip if < 0.5s)
        let savedAudio = audioBuffer
        audioBuffer = Data()
        if savedAudio.count > 16000 {  // 16000 bytes = 0.5s at 16kHz 16bit mono
            Task.detached { Self.saveWav(pcm: savedAudio) }
        }

        guard let rec = recognizer else {
            setStatus(.idle)
            return
        }

        setStatus(.processing)
        rec.finishAudio()
        // Result arrives via onResult callback set in handleStart
    }

    public func handleAudioChunk(_ data: Data) {
        recognizer?.sendAudio(data)
        audioBuffer.append(data)

        let count = data.count / 2
        guard count > 0 else { return }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let sumSq = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = Float(sqrt(sumSq / Double(count))) / 32768.0
        let level = min(1.0, rms * 20.0)
        if rms > peakRms { peakRms = rms }

        var next = Array(audioLevels.dropFirst())
        next.append(level)
        audioLevels = next
        onAudioLevels?(next)
    }

    // MARK: - Private

    private func setStatus(_ s: ASRStatus) {
        status = s
        onStatusChange?(s)
    }

    private func scheduleIdleReset(after seconds: Double) {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self = self, !Task.isCancelled, !self.isSessionActive else { return }
            self.setStatus(.idle)
            self.currentText = ""
        }
    }

    /// Returns the path to the model directory bundled with the app.
    nonisolated private static func modelDirectory() -> String {
        // Release .app bundle: Contents/Resources/models/
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("models/sense-voice-zh-en")
            if FileManager.default.fileExists(atPath: (bundled as NSString).appendingPathComponent("model.int8.onnx")) {
                return bundled
            }
        }

        // Development fallback: models/ in the repo root
        let cwd = FileManager.default.currentDirectoryPath as NSString
        let devPath = cwd.appendingPathComponent("models/sense-voice-zh-en")
        if FileManager.default.fileExists(atPath: (devPath as NSString).appendingPathComponent("model.int8.onnx")) {
            return devPath
        }

        // Last resort
        return "/Users/locke/workspace/murmur/models/sense-voice-zh-en"
    }

    /// Save raw PCM (16kHz mono Int16) as WAV to ~/Library/Application Support/com.locke.murmur/recordings/
    nonisolated private static func saveWav(pcm: Data) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("com.locke.murmur/recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = formatter.string(from: Date()) + ".wav"
        let url = dir.appendingPathComponent(filename)

        // WAV header for 16kHz mono 16-bit PCM
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: (36 + dataSize).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var wav = header
        wav.append(pcm)
        try? wav.write(to: url)
        fputs("[PushToTalk] saved \(filename) (\(pcm.count / 2 / 16000)s)\n", stderr)
    }
}
