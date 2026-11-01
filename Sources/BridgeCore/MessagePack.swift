import Foundation

/// A small MessagePack codec for provider protocols that use binary frames. Maps have string
/// keys. Decoding is bounded: it rejects truncated input, deep nesting and oversized lengths.
/// https://github.com/msgpack/msgpack/blob/master/spec.md
public indirect enum MessagePackValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([String: MessagePackValue])

    public subscript(key: String) -> MessagePackValue? {
        if case .map(let map) = self { return map[key] }
        return nil
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var int: Int64? { if case .int(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
}

public enum MessagePack {
    public enum DecodingError: Error, Equatable { case truncated, unsupported, tooDeep, trailingBytes }

    public static func encode(_ value: MessagePackValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    public static func decode(_ data: Data) throws -> MessagePackValue {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.value(depth: 0)
        guard reader.offset == reader.bytes.count else { throw DecodingError.trailingBytes }
        return value
    }

    private static func write(_ value: MessagePackValue, into out: inout Data) {
        func big<T: FixedWidthInteger>(_ number: T) { withUnsafeBytes(of: number.bigEndian) { out.append(contentsOf: $0) } }
        func length(_ count: Int, fix: UInt8?, fixLimit: Int, _ c8: UInt8?, _ c16: UInt8, _ c32: UInt8) {
            if let fix, count < fixLimit { out.append(fix | UInt8(count)) }
            else if let c8, count <= 0xff { out.append(c8); out.append(UInt8(count)) }
            else if count <= 0xffff { out.append(c16); big(UInt16(count)) }
            else { out.append(c32); big(UInt32(count)) }
        }
        switch value {
        case .null: out.append(0xc0)
        case .bool(let flag): out.append(flag ? 0xc3 : 0xc2)
        case .int(let number):
            if number >= 0 && number < 128 { out.append(UInt8(number)) }
            else if number < 0 && number >= -32 { out.append(UInt8(bitPattern: Int8(number))) }
            else { out.append(0xd3); big(number) }
        case .double(let number): out.append(0xcb); big(number.bitPattern)
        case .string(let text):
            let bytes = Data(text.utf8)
            length(bytes.count, fix: 0xa0, fixLimit: 32, 0xd9, 0xda, 0xdb); out.append(bytes)
        case .binary(let bytes):
            length(bytes.count, fix: nil, fixLimit: 0, 0xc4, 0xc5, 0xc6); out.append(bytes)
        case .array(let items):
            length(items.count, fix: 0x90, fixLimit: 16, nil, 0xdc, 0xdd)
            items.forEach { write($0, into: &out) }
        case .map(let map):
            length(map.count, fix: 0x80, fixLimit: 16, nil, 0xde, 0xdf)
            // Sorted keys make the encoding deterministic.
            for key in map.keys.sorted() { write(.string(key), into: &out); write(map[key]!, into: &out) }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - offset else { throw DecodingError.truncated }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }
        mutating func unsigned(_ size: Int) throws -> UInt64 { try take(size).reduce(0) { $0 << 8 | UInt64($1) } }
        mutating func signed(_ size: Int) throws -> Int64 {
            let raw = try unsigned(size), shift = UInt64(64 - size * 8)
            return Int64(bitPattern: raw << shift) >> Int64(shift)
        }
        mutating func value(depth: Int) throws -> MessagePackValue {
            guard depth < 32 else { throw DecodingError.tooDeep }
            let byte = try take(1).first!
            switch byte {
            case 0x00...0x7f: return .int(Int64(byte))
            case 0xe0...0xff: return .int(Int64(Int8(bitPattern: byte)))
            case 0xa0...0xbf: return try text(Int(byte & 0x1f))
            case 0x90...0x9f: return try array(Int(byte & 0x0f), depth: depth)
            case 0x80...0x8f: return try map(Int(byte & 0x0f), depth: depth)
            case 0xc0: return .null
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)
            case 0xc4: return .binary(Data(try take(Int(try unsigned(1)))))
            case 0xc5: return .binary(Data(try take(Int(try unsigned(2)))))
            case 0xc6: return .binary(Data(try take(Int(try unsigned(4)))))
            case 0xca: return .double(Double(Float(bitPattern: UInt32(try unsigned(4)))))
            case 0xcb: return .double(Double(bitPattern: try unsigned(8)))
            case 0xcc: return .int(Int64(try unsigned(1)))
            case 0xcd: return .int(Int64(try unsigned(2)))
            case 0xce: return .int(Int64(try unsigned(4)))
            case 0xcf:
                let number = try unsigned(8)
                guard number <= UInt64(Int64.max) else { throw DecodingError.unsupported }
                return .int(Int64(number))
            case 0xd0: return .int(try signed(1))
            case 0xd1: return .int(try signed(2))
            case 0xd2: return .int(try signed(4))
            case 0xd3: return .int(try signed(8))
            case 0xd9: return try text(Int(try unsigned(1)))
            case 0xda: return try text(Int(try unsigned(2)))
            case 0xdb: return try text(Int(try unsigned(4)))
            case 0xdc: return try array(Int(try unsigned(2)), depth: depth)
            case 0xdd: return try array(Int(try unsigned(4)), depth: depth)
            case 0xde: return try map(Int(try unsigned(2)), depth: depth)
            case 0xdf: return try map(Int(try unsigned(4)), depth: depth)
            default: throw DecodingError.unsupported // Extension types are not used.
            }
        }
        mutating func text(_ count: Int) throws -> MessagePackValue {
            guard let value = String(bytes: try take(count), encoding: .utf8) else { throw DecodingError.unsupported }
            return .string(value)
        }
        mutating func array(_ count: Int, depth: Int) throws -> MessagePackValue {
            // Every element takes at least one byte, so a count past the input is truncated.
            guard count <= bytes.count - offset else { throw DecodingError.truncated }
            return .array(try (0..<count).map { _ in try value(depth: depth + 1) })
        }
        mutating func map(_ count: Int, depth: Int) throws -> MessagePackValue {
            guard count <= (bytes.count - offset) / 2 else { throw DecodingError.truncated }
            var result: [String: MessagePackValue] = [:]
            for _ in 0..<count {
                guard case .string(let key) = try value(depth: depth + 1) else { throw DecodingError.unsupported }
                result[key] = try value(depth: depth + 1)
            }
            return .map(result)
        }
    }
}
