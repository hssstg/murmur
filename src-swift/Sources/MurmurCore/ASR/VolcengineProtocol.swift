import Foundation

/// Volcengine BigASR V3 binary protocol constants and helpers.
/// See: https://www.volcengine.com/docs/6561/1354869
public enum VolcengineProtocol {
    public static let endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"

    // Message types (high nibble of byte 1)
    static let msgFullClientRequest:  UInt8 = 0x01
    static let msgAudioOnlyRequest:   UInt8 = 0x02
    static let msgFullServerResponse: UInt8 = 0x09
    static let msgServerAck:          UInt8 = 0x0B
    static let msgServerError:        UInt8 = 0x0F

    // Sequence flags (low nibble of byte 1)
    static let flagPosSequence: UInt8 = 0x01
    static let flagNegSequence: UInt8 = 0x03

    // Serialization (high nibble of byte 2)
    static let serialJson:   UInt8 = 0x01

    // Compression (low nibble of byte 2)
    static let compressNone: UInt8 = 0x00
    static let compressGzip: UInt8 = 0x01

    // MARK: - Header building

    public static func buildHeader(
        msgType: UInt8, msgFlags: UInt8, serial: UInt8, compress: UInt8
    ) -> Data {
        var d = Data(count: 4)
        d[0] = (0x01 << 4) | 0x01   // version=1, headerSize=1
        d[1] = (msgType << 4) | msgFlags
        d[2] = (serial << 4) | compress
        d[3] = 0x00
        return d
    }

    // MARK: - Int32 big-endian helpers

    public static func int32ToData(_ value: Int32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    public static func dataToInt32(_ data: Data, offset: Int = 0) -> Int32 {
        var v: Int32 = 0
        withUnsafeMutableBytes(of: &v) { dest in
            _ = data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return Int32(bigEndian: v)
    }

    // MARK: - Packet building

    /// Build the full init request packet (with gzip-compressed JSON payload).
    public static func buildInitPacket(payload: [String: Any], sequence: Int32) throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let compressed = try GzipUtils.compress(jsonData)

        var packet = buildHeader(
            msgType: msgFullClientRequest,
            msgFlags: flagPosSequence,
            serial: serialJson,
            compress: compressGzip
        )
        packet.append(int32ToData(sequence))
        packet.append(int32ToData(Int32(compressed.count)))
        packet.append(compressed)
        return packet
    }

    /// Build an audio chunk packet.
    public static func buildAudioPacket(audio: Data, sequence: Int32, isLast: Bool) -> Data {
        let flag: UInt8 = isLast ? flagNegSequence : flagPosSequence
        let seqValue: Int32 = isLast ? -sequence : sequence

        var packet = buildHeader(
            msgType: msgAudioOnlyRequest,
            msgFlags: flag,
            serial: serialJson,
            compress: compressNone
        )
        packet.append(int32ToData(seqValue))
        packet.append(int32ToData(Int32(audio.count)))
        packet.append(audio)
        return packet
    }

    // MARK: - Response parsing

    public struct ParsedResponse {
        public enum Kind { case ack, result, error }
        public var kind: Kind
        public var sequence: Int32
        public var text: String?
        public var isFinal: Bool
        public var errorMessage: String?
    }

    public static func parseResponse(_ data: Data) -> ParsedResponse? {
        guard data.count >= 4 else { return nil }
        let msgType  = (data[1] >> 4) & 0x0F
        let msgFlags =  data[1] & 0x0F
        let compress =  data[2] & 0x0F

        switch msgType {
        case msgServerError:
            guard data.count >= 12 else { return nil }
            let msgSize = Int(dataToInt32(data, offset: 8))
            guard msgSize >= 0, data.count >= 12 + msgSize else { return nil }
            let raw = data.subdata(in: 12..<(12 + msgSize))
            let msg: String
            if compress == compressGzip, let dec = try? GzipUtils.decompress(raw) {
                msg = String(data: dec, encoding: .utf8) ?? ""
            } else {
                msg = String(data: raw, encoding: .utf8) ?? ""
            }
            return ParsedResponse(kind: .error, sequence: 0, isFinal: false, errorMessage: msg)

        case msgServerAck:
            guard data.count >= 8 else { return nil }
            let seq = dataToInt32(data, offset: 4)
            return ParsedResponse(kind: .ack, sequence: seq, isFinal: false)

        case msgFullServerResponse:
            guard data.count >= 12 else { return nil }
            let seq = dataToInt32(data, offset: 4)
            let payloadSize = Int(dataToInt32(data, offset: 8))
            guard payloadSize >= 0, data.count >= 12 + payloadSize else { return nil }
            let rawPayload = data.subdata(in: 12..<(12 + payloadSize))
            let payloadData: Data
            if compress == compressGzip {
                guard let dec = try? GzipUtils.decompress(rawPayload) else { return nil }
                payloadData = dec
            } else {
                payloadData = rawPayload
            }
            guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }
            let isFinal = seq < 0 || msgFlags == flagNegSequence
            var text = ""
            if let result = json["result"] as? [String: Any] {
                text = result["text"] as? String ?? ""
                if text.isEmpty, let utts = result["utterances"] as? [[String: Any]] {
                    text = utts.compactMap { $0["text"] as? String }.joined()
                }
            }
            return ParsedResponse(kind: .result, sequence: seq, text: text, isFinal: isFinal)

        default:
            return nil
        }
    }
}
