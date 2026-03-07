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
    private var client: VolcengineClient?
    private var latestResult: ASRResult?
    private var idleTimer: Task<Void, Never>?
    private var peakRms: Float = 0
    private var sessionGeneration: Int = 0
    private var pendingChunks: [Data] = []

    public init(config: AppConfig) {
        self.config = config
    }

    public func updateConfig(_ cfg: AppConfig) {
        config = cfg
    }

    // MARK: - PTT events

    public func handleStart() {
        guard !isSessionActive else { return }
        sessionGeneration += 1
        let myGeneration = sessionGeneration
        isSessionActive = true
        idleTimer?.cancel()
        idleTimer = nil

        audioLevels = Array(repeating: 0, count: 16)
        peakRms = 0
        latestResult = nil
        currentText = ""
        setStatus(.connecting)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let client = VolcengineClient(config: VolcengineConfig(from: self.config))

            client.onResult = { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.latestResult = result
                    self?.currentText = result.text
                    self?.onTextChange?(result.text)
                }
            }
            client.onStatus = { [weak self] s in
                Task { @MainActor [weak self] in
                    // Only propagate listening/processing/done — connecting already set
                    if s == .listening || s == .processing || s == .done {
                        self?.setStatus(s)
                    }
                }
            }
            client.onError = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == myGeneration else { return }
                    self.client = nil
                    self.isSessionActive = false
                    self.setStatus(.idle)
                }
            }

            // Assign to self before connecting so audio callbacks can reach it
            self.client = client

            do {
                try await client.connect()
                // Flush chunks that arrived before the client was assigned.
                // Must happen after connect() so connectionState == "connected" and sendAudio() works.
                let buffered = self.pendingChunks
                self.pendingChunks = []
                for chunk in buffered { client.sendAudio(chunk) }
            } catch {
                guard self.sessionGeneration == myGeneration else { return }
                self.client = nil
                self.isSessionActive = false
                self.pendingChunks = []
                self.setStatus(.idle)
            }
        }
    }

    public func handleStop() {
        guard isSessionActive else { return }
        let myGeneration = sessionGeneration
        setStatus(.processing)

        let capturedClient = client
        client = nil
        isSessionActive = false
        pendingChunks = []

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let c = capturedClient else {
                self.setStatus(.idle)
                return
            }

            c.finishAudio()

            guard self.sessionGeneration == myGeneration else {
                c.disconnect()
                return
            }
            let finalResult = await self.waitForFinalResult(client: c, timeout: 3.0)
            c.disconnect()

            let cfg = self.config
            var textToInsert = finalResult?.text ?? ""

            if !textToInsert.isEmpty {
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
            } else {
                self.setStatus(.done)
                self.scheduleIdleReset(after: 0.8)
            }
        }
    }

    public func handleAudioChunk(_ data: Data) {
        if let client = client {
            client.sendAudio(data)
        } else if isSessionActive {
            pendingChunks.append(data)
        }

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

    private func waitForFinalResult(client: VolcengineClient, timeout: Double) async -> ASRResult? {
        await withCheckedContinuation { cont in
            nonisolated(unsafe) var resolved = false
            let lock = NSLock()

            func resolve(_ r: ASRResult?) {
                lock.lock(); defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                cont.resume(returning: r)
            }

            let capturedLatest = latestResult

            client.onResult = { [weak self] r in
                Task { @MainActor [weak self] in
                    self?.latestResult = r
                    self?.currentText = r.text
                    self?.onTextChange?(r.text)
                }
                if r.isFinal { resolve(r) }
            }
            client.onStatus = { [weak self] s in
                if s == .done || s == .idle {
                    Task { @MainActor [weak self] in
                        let latest = self?.latestResult ?? capturedLatest
                        resolve(latest)
                    }
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resolve(self?.latestResult ?? capturedLatest)
            }
        }
    }
}
