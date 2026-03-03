import Foundation

public class VolcengineClient: NSObject {
    private let config: VolcengineConfig
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
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

    public var isConnected: Bool { connectionState == "connected" && webSocket != nil }

    public func connect() async throws {
        guard !isConnected else { return }
        reset()
        connectionState = "connecting"
        onStatus?(.connecting)

        requestId = UUID().uuidString
        sequence = 1

        let url = URL(string: VolcengineProtocol.endpoint)!
        var req = URLRequest(url: url)
        req.setValue(config.appId,        forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(config.accessToken,  forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(config.resourceId,   forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(requestId,           forHTTPHeaderField: "X-Api-Connect-Id")

        session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        let task = session!.webSocketTask(with: req)
        webSocket = task
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

        let packet = try VolcengineProtocol.buildInitPacket(payload: initPayload, sequence: sequence)
        sequence = 2

        try await sendRaw(packet)

        // Flush buffered audio from connecting phase
        for chunk in pendingAudioChunks { sendAudioChunk(chunk) }
        pendingAudioChunks = []
        connectionState = "connected"

        if pendingFinish {
            pendingFinish = false
            sendFinishPacket()
        } else {
            onStatus?(.listening)
        }
    }

    public func sendAudio(_ data: Data) {
        if connectionState == "connecting" {
            pendingAudioChunks.append(data)
            return
        }
        guard isConnected else { return }
        sendAudioChunk(data)
    }

    public func finishAudio() {
        if connectionState == "connecting" {
            pendingFinish = true
            return
        }
        guard isConnected else { return }
        sendFinishPacket()
    }

    public func disconnect() {
        connectionState = "disconnected"
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        onStatus?(.idle)
    }

    // MARK: - Private

    private func reset() {
        requestId = ""
        sequence = 0
        pendingAudioChunks = []
        pendingFinish = false
    }

    private func sendAudioChunk(_ data: Data) {
        let packet = VolcengineProtocol.buildAudioPacket(audio: data, sequence: sequence, isLast: false)
        sequence += 1
        webSocket?.send(.data(packet)) { _ in }
    }

    private func sendFinishPacket() {
        let packet = VolcengineProtocol.buildAudioPacket(audio: Data(), sequence: sequence, isLast: true)
        onStatus?(.processing)
        webSocket?.send(.data(packet)) { _ in }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            webSocket?.send(.data(data)) { error in
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
            case .failure:
                if self.connectionState != "disconnected" {
                    self.connectionState = "disconnected"
                    self.onStatus?(.idle)
                }
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let parsed = VolcengineProtocol.parseResponse(data) else { return }
        switch parsed.kind {
        case .error:
            let msg = parsed.errorMessage ?? "unknown ASR server error"
            onError?(NSError(domain: "VolcengineASR", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: msg]))
            onStatus?(.error)
        case .ack:
            break
        case .result:
            let result = ASRResult(text: parsed.text ?? "", isFinal: parsed.isFinal)
            onResult?(result)
            if parsed.isFinal { onStatus?(.done) }
        }
    }
}
