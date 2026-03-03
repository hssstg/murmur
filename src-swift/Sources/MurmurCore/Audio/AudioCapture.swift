import AVFoundation
import CoreAudio

public class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    public var onChunk: (@Sendable (Data) -> Void)?
    public var onDeviceName: (@Sendable (String) -> Void)?
    public private(set) var isRunning = false

    public init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
    }

    public func start(deviceUID: String? = nil) throws {
        guard !isRunning else { return }

        if let targetUID = deviceUID, !targetUID.isEmpty {
            setDefaultInputDevice(uid: targetUID)
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        try engine.start()
        isRunning = true

        let name = Self.currentInputDeviceName()
        let cb = onDeviceName
        DispatchQueue.main.async { cb?(name) }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: - Private

    private func processTap(buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let inputFormat = buffer.format
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, outBuf.frameLength > 0,
              let int16Data = outBuf.int16ChannelData else { return }

        let byteCount = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data[0], count: byteCount)
        onChunk?(data)
    }

    private func setDefaultInputDevice(uid targetUID: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &devices)

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        for id in devices {
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidRef)
            if let uid = uidRef as String?, uid == targetUID {
                deviceID = id
                break
            }
        }

        guard deviceID != kAudioObjectUnknown else { return }

        var setAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &setAddr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
    }

    private static func currentInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanagedName: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &unmanagedName) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(nameSize)) { rawPtr in
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, rawPtr)
            }
        }
        if status == noErr, let name = unmanagedName?.takeRetainedValue() {
            return name as String
        }
        return "Unknown"
    }
}
