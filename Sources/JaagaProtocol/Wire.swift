import Foundation

/// Encoding and line framing for the daemon socket.
///
/// The framing is newline-delimited JSON: one compact JSON object per line, UTF-8, `\n` terminated.
/// JSON escapes newlines inside strings, so a literal `\n` byte always ends a frame — which means a
/// client in any language can frame messages with a line reader and no length prefix.
public enum Wire {
    /// Dates travel as seconds since the Unix epoch, so clients need no date-format agreement.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Encodes `value` as one newline-terminated frame.
    public static func frame<T: Encodable>(_ value: T, encoder: JSONEncoder = Wire.makeEncoder()) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from line: Data,
        decoder: JSONDecoder = Wire.makeDecoder()
    ) throws -> T {
        try decoder.decode(type, from: line)
    }
}

/// Splits a byte stream into newline-delimited frames, holding any partial tail until it completes.
///
/// Not thread-safe by itself; each connection owns one and feeds it from a single reader.
public struct LineFramer: Sendable {
    /// Refuse a frame larger than this rather than growing without bound on a misbehaving client.
    public let maximumFrameBytes: Int
    private var buffer = Data()

    public init(maximumFrameBytes: Int = 8 * 1024 * 1024) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    public enum FramingError: Error, Sendable {
        case frameTooLarge(bytes: Int)
    }

    /// Appends `chunk` and returns every complete frame it finished. Empty lines are dropped.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty {
                frames.append(Data(line))
            }
        }

        if buffer.count > maximumFrameBytes {
            let overflow = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw FramingError.frameTooLarge(bytes: overflow)
        }
        return frames
    }

    /// Bytes held back waiting for their terminating newline.
    public var pendingByteCount: Int { buffer.count }
}
