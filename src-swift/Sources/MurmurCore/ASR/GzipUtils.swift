import Foundation
import zlib

public enum GzipUtils {

    /// Compress data using gzip format (windowBits=31 = gzip header).
    public static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            31,       // 15 + 16 = gzip output format
            8,        // default memory level
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw GzipError.deflateInitFailed(Int(status))
        }
        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) throws -> Data in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: ptr.bindMemory(to: Bytef.self).baseAddress!
            )
            stream.avail_in = uInt(data.count)

            var result = Data()
            let bufSize = 32768
            var buf = [Bytef](repeating: 0, count: bufSize)

            repeat {
                try buf.withUnsafeMutableBufferPointer { bufPtr in
                    stream.next_out = bufPtr.baseAddress!
                    stream.avail_out = uInt(bufSize)
                    status = deflate(&stream, Z_FINISH)
                    guard status != Z_STREAM_ERROR else {
                        throw GzipError.deflateError(Int(status))
                    }
                    let produced = bufSize - Int(stream.avail_out)
                    result.append(contentsOf: bufPtr.prefix(produced))
                }
            } while stream.avail_out == 0

            return result
        }
    }

    /// Decompress gzip data. windowBits=47 = auto-detect zlib/gzip.
    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        var status = inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GzipError.inflateInitFailed(Int(status))
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) throws -> Data in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: ptr.bindMemory(to: Bytef.self).baseAddress!
            )
            stream.avail_in = uInt(data.count)

            var result = Data()
            let bufSize = 32768
            var buf = [Bytef](repeating: 0, count: bufSize)

            repeat {
                try buf.withUnsafeMutableBufferPointer { bufPtr in
                    stream.next_out = bufPtr.baseAddress!
                    stream.avail_out = uInt(bufSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status != Z_STREAM_ERROR else {
                        throw GzipError.inflateError(Int(status))
                    }
                    let produced = bufSize - Int(stream.avail_out)
                    result.append(contentsOf: bufPtr.prefix(produced))
                }
            } while stream.avail_in > 0 || stream.avail_out == 0

            return result
        }
    }
}

public enum GzipError: Error {
    case deflateInitFailed(Int)
    case deflateError(Int)
    case inflateInitFailed(Int)
    case inflateError(Int)
}
