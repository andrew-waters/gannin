import Foundation

public enum FrameError: Error, Equatable {
    case tooLarge(Int)
    /// The other side speaks a version this one doesn't.
    case unsupportedVersion(Int)
    case malformed
}

/// What goes inside a frame: the protocol version and the message.
struct Frame<Message: Codable>: Codable {
    var v: Int
    var m: Message
}

private struct FrameHeader: Decodable {
    var v: Int
}

/// Frames are a four-byte big-endian length, then that many bytes of JSON.
public enum FrameCodec {
    public static func encode<Message: Codable>(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(Frame(v: RemoteProtocol.version, m: message))
        guard body.count <= RemoteProtocol.maxFrameBytes else { throw FrameError.tooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        var out = Data()
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Reads one frame's payload, checking its version before the message, so a newer
    /// side's messages are reported as a version mismatch rather than as garbage.
    public static func decode<Message: Codable>(_ payload: Data, as type: Message.Type) throws -> Message {
        guard let header = try? JSONDecoder().decode(FrameHeader.self, from: payload) else { throw FrameError.malformed }
        guard header.v == RemoteProtocol.version else { throw FrameError.unsupportedVersion(header.v) }
        guard let frame = try? JSONDecoder().decode(Frame<Message>.self, from: payload) else { throw FrameError.malformed }
        return frame.m
    }
}

/// Collects bytes as they arrive and hands back whole frames. After it throws, the
/// connection can't be trusted to be on a frame boundary: close it.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next whole frame's payload, or nil when more bytes are needed.
    public mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        // Refused on the prefix alone, so a hostile length never makes us buffer it.
        guard length <= RemoteProtocol.maxFrameBytes else { throw FrameError.tooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return payload
    }
}
