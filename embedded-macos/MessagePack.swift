//
//  MessagePack.swift
//  embedded-macos
//

import Foundation

/// A MessagePack value — the wire format of Neovim's RPC API.
enum MessagePack: Equatable {
    struct Pair: Equatable {
        var key: MessagePack
        var value: MessagePack
    }

    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePack])
    case map([Pair])
    case ext(Int8, Data)

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int: Int? { if case .int(let value) = self { value } else { nil } }
    var array: [MessagePack]? { if case .array(let value) = self { value } else { nil } }
}

/// Encodes using only the widest header of each type — valid MessagePack, just not the most compact.
func pack(_ value: MessagePack) -> Data {
    var out = Data()
    pack(value, into: &out)
    return out
}

private func pack(_ value: MessagePack, into out: inout Data) {
    switch value {
    case .null: out.append(0xc0)
    case .bool(let bool): out.append(bool ? 0xc3 : 0xc2)
    case .int(let int): appendHeader(0xd3, UInt64(bitPattern: Int64(int)), width: 8, to: &out)
    case .double(let double): appendHeader(0xcb, double.bitPattern, width: 8, to: &out)
    case .string(let string):
        appendHeader(0xdb, UInt64(string.utf8.count), width: 4, to: &out)
        out.append(contentsOf: string.utf8)
    case .binary(let data):
        appendHeader(0xc6, UInt64(data.count), width: 4, to: &out)
        out.append(data)
    case .array(let items):
        appendHeader(0xdd, UInt64(items.count), width: 4, to: &out)
        items.forEach { pack($0, into: &out) }
    case .map(let pairs):
        appendHeader(0xdf, UInt64(pairs.count), width: 4, to: &out)
        for pair in pairs {
            pack(pair.key, into: &out)
            pack(pair.value, into: &out)
        }
    case .ext(let type, let data):
        appendHeader(0xc9, UInt64(data.count), width: 4, to: &out)
        out.append(UInt8(bitPattern: type))
        out.append(data)
    }
}

private func appendHeader(_ marker: UInt8, _ value: UInt64, width: Int, to out: inout Data) {
    out.append(marker)
    for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
        out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
}

struct InvalidMessagePack: Error {
    let marker: UInt8
}

/// Decodes the value at the front of `bytes`, or returns nil if `bytes` holds only part of one.
func unpack(_ bytes: [UInt8]) throws -> (value: MessagePack, length: Int)? {
    var reader = Reader(bytes: bytes)
    do {
        return (try reader.value(), reader.offset)
    } catch is Reader.Incomplete {
        return nil
    }
}

private struct Reader {
    struct Incomplete: Error {}

    let bytes: [UInt8]
    var offset = 0

    mutating func value() throws -> MessagePack {
        let marker = try take(1).first!
        switch marker {
        case 0x00...0x7f: return .int(Int(marker))
        case 0x80...0x8f: return try map(count: Int(marker & 0x0f))
        case 0x90...0x9f: return try array(count: Int(marker & 0x0f))
        case 0xa0...0xbf: return try string(length: Int(marker & 0x1f))
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4...0xc6: return .binary(Data(try take(length(width: 1 << (marker - 0xc4)))))
        case 0xc7...0xc9: return try ext(length: length(width: 1 << (marker - 0xc7)))
        case 0xca: return .double(Double(Float(bitPattern: UInt32(truncatingIfNeeded: try bits(4)))))
        case 0xcb: return .double(Double(bitPattern: try bits(8)))
        case 0xcc...0xcf: return .int(Int(truncatingIfNeeded: try bits(1 << (marker - 0xcc))))
        case 0xd0...0xd3: return .int(try signed(width: 1 << (marker - 0xd0)))
        case 0xd4...0xd8: return try ext(length: 1 << (marker - 0xd4))
        case 0xd9...0xdb: return try string(length: length(width: 1 << (marker - 0xd9)))
        case 0xdc...0xdd: return try array(count: length(width: 2 << (marker - 0xdc)))
        case 0xde...0xdf: return try map(count: length(width: 2 << (marker - 0xde)))
        case 0xe0...0xff: return .int(Int(Int8(bitPattern: marker)))
        default: throw InvalidMessagePack(marker: marker)
        }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard bytes.count - offset >= count else { throw Incomplete() }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    private mutating func bits(_ width: Int) throws -> UInt64 {
        try take(width).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func length(width: Int) throws -> Int {
        Int(try bits(width))
    }

    private mutating func signed(width: Int) throws -> Int {
        let unusedBits = Int64(64 - 8 * width)
        return Int(Int64(bitPattern: try bits(width) << UInt64(unusedBits)) >> unusedBits)
    }

    private mutating func string(length: Int) throws -> MessagePack {
        .string(String(decoding: try take(length), as: UTF8.self))
    }

    private mutating func array(count: Int) throws -> MessagePack {
        var items: [MessagePack] = []
        for _ in 0..<count { items.append(try value()) }
        return .array(items)
    }

    private mutating func map(count: Int) throws -> MessagePack {
        var pairs: [MessagePack.Pair] = []
        for _ in 0..<count {
            pairs.append(MessagePack.Pair(key: try value(), value: try value()))
        }
        return .map(pairs)
    }

    private mutating func ext(length: Int) throws -> MessagePack {
        let type = Int8(bitPattern: try take(1).first!)
        return .ext(type, Data(try take(length)))
    }
}
