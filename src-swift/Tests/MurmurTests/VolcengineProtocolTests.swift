import Foundation
import MurmurCore

@MainActor func runVolcengineProtocolTests() {

    // Test 1: buildHeader byte values
    suite("VolcengineProtocol/buildHeader") {
        let header = VolcengineProtocol.buildHeader(
            msgType: 0x01, msgFlags: 0x01, serial: 0x01, compress: 0x00
        )
        check(header.count == 4, "header is 4 bytes")
        // byte 0: version=1 (high nibble), headerSize=1 (low nibble) = 0x11
        assertEqual(header[0], UInt8(0x11), "byte[0] = 0x11 (version=1, headerSize=1)")
        // byte 1: (msgType << 4) | flags = (0x01 << 4) | 0x01 = 0x11
        assertEqual(header[1], UInt8(0x11), "byte[1] = (msgType<<4)|flags")
        // byte 2: (serial << 4) | compress = (0x01 << 4) | 0x00 = 0x10
        assertEqual(header[2], UInt8(0x10), "byte[2] = (serial<<4)|compress")
        // byte 3: always 0x00
        assertEqual(header[3], UInt8(0x00), "byte[3] = 0x00")
    }

    // Test 2: int32ToData(1) = [0,0,0,1] and roundtrip
    suite("VolcengineProtocol/int32ToData positive") {
        let d = VolcengineProtocol.int32ToData(1)
        check(d.count == 4, "int32 is 4 bytes")
        assertEqual(d[0], UInt8(0), "byte[0] = 0")
        assertEqual(d[1], UInt8(0), "byte[1] = 0")
        assertEqual(d[2], UInt8(0), "byte[2] = 0")
        assertEqual(d[3], UInt8(1), "byte[3] = 1")
        let roundtrip = VolcengineProtocol.dataToInt32(d)
        assertEqual(roundtrip, Int32(1), "dataToInt32(int32ToData(1)) == 1")
    }

    // Test 3: int32ToData(-5) roundtrip (negative sequence for finish packets)
    suite("VolcengineProtocol/int32ToData negative") {
        let d = VolcengineProtocol.int32ToData(-5)
        check(d.count == 4, "int32 negative is 4 bytes")
        let roundtrip = VolcengineProtocol.dataToInt32(d)
        assertEqual(roundtrip, Int32(-5), "dataToInt32(int32ToData(-5)) == -5")
        // Verify big-endian: -5 in two's complement big-endian = 0xFFFFFFFB
        assertEqual(d[0], UInt8(0xFF), "byte[0] of -5 = 0xFF")
        assertEqual(d[1], UInt8(0xFF), "byte[1] of -5 = 0xFF")
        assertEqual(d[2], UInt8(0xFF), "byte[2] of -5 = 0xFF")
        assertEqual(d[3], UInt8(0xFB), "byte[3] of -5 = 0xFB")
    }

    // Test 4: buildAudioPacket isLast=true has negative sequence in bytes 4-7
    suite("VolcengineProtocol/buildAudioPacket isLast=true") {
        let audio = Data([0x01, 0x02, 0x03])
        let packet = VolcengineProtocol.buildAudioPacket(audio: audio, sequence: 5, isLast: true)
        // Packet layout: header(4) + sequence(4) + payloadSize(4) + audio(n)
        check(packet.count >= 12, "packet has at least 12 bytes")
        // When isLast=true, sequence is negated: -5
        let seqInPacket = VolcengineProtocol.dataToInt32(packet, offset: 4)
        assertEqual(seqInPacket, Int32(-5), "isLast=true sequence in packet is -5")
        // byte 1 low nibble should be flagNegSequence (0x03)
        let flags = packet[1] & 0x0F
        assertEqual(flags, UInt8(0x03), "isLast=true sets flagNegSequence (0x03)")
        // payload size should be 3
        let payloadSize = VolcengineProtocol.dataToInt32(packet, offset: 8)
        assertEqual(payloadSize, Int32(3), "payload size = 3")
    }

    // Test 4b: buildAudioPacket isLast=false has positive sequence
    suite("VolcengineProtocol/buildAudioPacket isLast=false") {
        let audio = Data([0xAA, 0xBB])
        let packet = VolcengineProtocol.buildAudioPacket(audio: audio, sequence: 7, isLast: false)
        let seqInPacket = VolcengineProtocol.dataToInt32(packet, offset: 4)
        assertEqual(seqInPacket, Int32(7), "isLast=false sequence in packet is +7")
        let flags = packet[1] & 0x0F
        assertEqual(flags, UInt8(0x01), "isLast=false sets flagPosSequence (0x01)")
    }

    // Test 5: parseResponse for a manually crafted ACK message
    // ACK layout: header(4) + sequence(4) = 8 bytes
    // byte[1] = (msgServerAck << 4) | anyFlags = (0x0B << 4) | 0x00 = 0xB0
    suite("VolcengineProtocol/parseResponse ACK") {
        var ackData = Data(count: 8)
        ackData[0] = 0x11
        ackData[1] = (0x0B << 4) | 0x00   // msgServerAck, no flags
        ackData[2] = 0x00
        ackData[3] = 0x00
        // sequence = 42 in big-endian at offset 4
        let seqBytes = VolcengineProtocol.int32ToData(42)
        ackData.replaceSubrange(4..<8, with: seqBytes)

        let parsed = VolcengineProtocol.parseResponse(ackData)
        check(parsed != nil, "ACK parse returns non-nil")
        if let p = parsed {
            check(p.kind == .ack, "ACK kind is .ack")
            assertEqual(p.sequence, Int32(42), "ACK sequence = 42")
        }
    }

    // Test 6: parseResponse for a manually crafted server error message
    // Error layout: header(4) + errorCode(4) + msgSize(4) + message(n)
    // byte[1] = (msgServerError << 4) | 0x00 = (0x0F << 4) | 0x00 = 0xF0
    suite("VolcengineProtocol/parseResponse server error") {
        let errorText = "auth failed"
        let errorBytes = errorText.data(using: .utf8)!

        var errData = Data(count: 12 + errorBytes.count)
        errData[0] = 0x11
        errData[1] = (0x0F << 4) | 0x00   // msgServerError, no compression
        errData[2] = 0x00
        errData[3] = 0x00
        // error code at offset 4 (unused in our parser beyond returning kind=error)
        let codeBytes = VolcengineProtocol.int32ToData(1001)
        errData.replaceSubrange(4..<8, with: codeBytes)
        // msgSize at offset 8
        let sizeBytes = VolcengineProtocol.int32ToData(Int32(errorBytes.count))
        errData.replaceSubrange(8..<12, with: sizeBytes)
        // message at offset 12
        errData.replaceSubrange(12..<(12 + errorBytes.count), with: errorBytes)

        let parsed = VolcengineProtocol.parseResponse(errData)
        check(parsed != nil, "server error parse returns non-nil")
        if let p = parsed {
            check(p.kind == .error, "error kind is .error")
            assertEqual(p.errorMessage, "auth failed", "error message = 'auth failed'")
        }
    }

    // Test 7: parseResponse returns nil for data that is too short
    suite("VolcengineProtocol/parseResponse too short") {
        let shortData = Data([0x11, 0x00, 0x00])
        let parsed = VolcengineProtocol.parseResponse(shortData)
        check(parsed == nil, "parse of 3-byte data returns nil")
    }

    // Test 8: parseResponse returns nil for unknown message type
    suite("VolcengineProtocol/parseResponse unknown type") {
        var unknownData = Data(count: 8)
        unknownData[0] = 0x11
        unknownData[1] = (0x05 << 4) | 0x00   // type 0x05 = unknown
        unknownData[2] = 0x00
        unknownData[3] = 0x00
        let parsed = VolcengineProtocol.parseResponse(unknownData)
        check(parsed == nil, "parse of unknown message type returns nil")
    }

    // Test 9: dataToInt32 with non-zero offset
    suite("VolcengineProtocol/dataToInt32 with offset") {
        var data = Data(count: 8)
        let val = VolcengineProtocol.int32ToData(256)
        data.replaceSubrange(4..<8, with: val)
        let result = VolcengineProtocol.dataToInt32(data, offset: 4)
        assertEqual(result, Int32(256), "dataToInt32 with offset=4 reads correct value")
    }
}
