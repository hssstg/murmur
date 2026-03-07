import Foundation

public class VolcengineClient: NSObject, @unchecked Sendable {
    private let config: VolcengineConfig
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let lock = NSLock()
    private var connectionState: String = "disconnected"
    private var requestId = ""
    private var sequence: Int32 = 0
    private var pendingAudioChunks: [Data] = []
    private var pendingFinish = false

    public var onStatus:  ((ASRStatus) -> Void)?
    public var onResult:  ((ASRResult) -> Void)?
    public var onError:   ((Error) -> Void)?

    public init(config: VolcengineConfig) {
        self.config = config
    }

    public var isConnected: Bool { lock.withLock { connectionState == "connected" && webSocket != nil } }

    public func connect() async throws {
        guard !isConnected else { return }
        lock.withLock { reset() }
        lock.withLock { connectionState = "connecting" }
        let onStatusCb = lock.withLock { onStatus }
        onStatusCb?(.connecting)

        let newRequestId = UUID().uuidString
        lock.withLock {
            requestId = newRequestId
            sequence = 1
        }

        let url = URL(string: VolcengineProtocol.endpoint)!
        var req = URLRequest(url: url)
        req.setValue(config.appId,        forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(config.accessToken,  forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(config.resourceId,   forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(newRequestId,        forHTTPHeaderField: "X-Api-Connect-Id")

        let newSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        let task = newSession.webSocketTask(with: req)
        lock.withLock {
            session = newSession
            webSocket = task
        }
        task.resume()
        startReceiveLoop(task)

        // Build init payload
        var requestBody: [String: Any] = [
            "model_name": "bigmodel",
            "language": config.language,
            "enable_punc": config.enablePunc,
            "enable_itn": config.enableItn,
            "enable_ddc": config.enableDdc,
            "show_utterances": true,
            "result_type": "full"
        ]
        if let vocab = config.vocabulary {
            requestBody["corpus"] = ["boosting_table_name": vocab]
        }
        let initPayload: [String: Any] = [
            "user": ["uid": "murmur_user"],
            "audio": [
                "format": "pcm",
                "sample_rate": 16000,
                "channel": 1,
                "bits": 16,
                "codec": "raw"
            ],
            "request": requestBody
        ]

        let seq1 = lock.withLock { sequence }
        let packet = try VolcengineProtocol.buildInitPacket(payload: initPayload, sequence: seq1)
        lock.withLock { sequence = 2 }

        try await sendRaw(packet)

        // Flush buffered audio from connecting phase
        let chunks = lock.withLock { () -> [Data] in
            let c = pendingAudioChunks
            pendingAudioChunks = []
            return c
        }
        for chunk in chunks { sendAudioChunk(chunk) }

        let (connected, hasPendingFinish) = lock.withLock { () -> (Bool, Bool) in
            guard connectionState == "connecting" else {
                return (false, false)  // receive loop already failed
            }
            connectionState = "connected"
            let p = pendingFinish
            if p { pendingFinish = false }
            return (true, p)
        }

        guard connected else {
            throw URLError(.networkConnectionLost)
        }

        if hasPendingFinish {
            sendFinishPacket()
        } else {
            let cb = lock.withLock { onStatus }
            cb?(.listening)
        }
    }

    public func sendAudio(_ data: Data) {
        let state = lock.withLock { connectionState }
        if state == "connecting" {
            lock.withLock { pendingAudioChunks.append(data) }
            return
        }
        guard isConnected else { return }
        sendAudioChunk(data)
    }

    public func finishAudio() {
        let state = lock.withLock { connectionState }
        if state == "connecting" {
            lock.withLock { pendingFinish = true }
            return
        }
        guard isConnected else { return }
        sendFinishPacket()
    }

    public func disconnect() {
        let (ws, sess) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            connectionState = "disconnected"
            let w = webSocket
            let s = session
            webSocket = nil
            session = nil
            return (w, s)
        }
        ws?.cancel(with: .goingAway, reason: nil)
        sess?.invalidateAndCancel()
        let cb = lock.withLock { onStatus }
        cb?(.idle)
    }

    // MARK: - Private

    // Must be called with lock held
    private func reset() {
        requestId = ""
        sequence = 0
        pendingAudioChunks = []
        pendingFinish = false
    }

    private func sendAudioChunk(_ data: Data) {
        let (packet, ws) = lock.withLock { () -> (Data, URLSessionWebSocketTask?) in
            let p = VolcengineProtocol.buildAudioPacket(audio: data, sequence: sequence, isLast: false)
            sequence += 1
            return (p, webSocket)
        }
        ws?.send(.data(packet)) { _ in }
    }

    private func sendFinishPacket() {
        let (packet, ws) = lock.withLock { () -> (Data, URLSessionWebSocketTask?) in
            let p = VolcengineProtocol.buildAudioPacket(audio: Data(), sequence: sequence, isLast: true)
            return (p, webSocket)
        }
        let cb = lock.withLock { onStatus }
        cb?(.processing)
        ws?.send(.data(packet)) { _ in }
    }

    private func sendRaw(_ data: Data) async throws {
        let ws = lock.withLock { webSocket }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ws?.send(.data(data)) { error in
                if let e = error { cont.resume(throwing: e) }
                else { cont.resume() }
            }
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                if case .data(let data) = msg { self.handleMessage(data) }
                self.startReceiveLoop(task)
            case .failure(let error):
                let state = self.lock.withLock { self.connectionState }
                if state != "disconnected" {
                    self.lock.withLock { self.connectionState = "disconnected" }
                    let (onErrorCb, onStatusCb) = self.lock.withLock { (self.onError, self.onStatus) }
                    onErrorCb?(error)
                    onStatusCb?(.error)
                }
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let parsed = VolcengineProtocol.parseResponse(data) else { return }
        switch parsed.kind {
        case .error:
            let msg = parsed.errorMessage ?? "unknown ASR server error"
            let (onErrorCb, onStatusCb) = lock.withLock { (onError, onStatus) }
            onErrorCb?(NSError(domain: "VolcengineASR", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: msg]))
            onStatusCb?(.error)
        case .ack:
            break
        case .result:
            let result = ASRResult(text: parsed.text ?? "", isFinal: parsed.isFinal)
            let (onResultCb, onStatusCb) = lock.withLock { (onResult, onStatus) }
            onResultCb?(result)
            if parsed.isFinal { onStatusCb?(.done) }
        }
    }
}
