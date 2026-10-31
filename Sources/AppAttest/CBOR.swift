// A strict CBOR (RFC 8949) reader for the two objects App Attest sends: the attestation object and the assertion.
//
// It reads only what those objects use (unsigned and negative integers, byte and text strings, arrays, maps with text
// keys) and refuses everything else: indefinite lengths, tags, floats, simple values, duplicate map keys, trailing
// bytes. Lengths are checked against the bytes left before anything is allocated, and nesting is capped, so a hostile
// input can't make it allocate more than its own size or recurse without bound (DECISIONS D-5).

/// A decoded CBOR value.
public indirect enum CBOR: Equatable, Sendable {
  case unsigned(UInt64)
  case negative(UInt64)  // the value is -1 - n
  case bytes([UInt8])
  case text(String)
  case array([CBOR])
  case map([String: CBOR])

  public subscript(key: String) -> CBOR? {
    if case .map(let entries) = self { return entries[key] }
    return nil
  }

  public var bytesValue: [UInt8]? {
    if case .bytes(let value) = self { return value }
    return nil
  }

  public var textValue: String? {
    if case .text(let value) = self { return value }
    return nil
  }

  public var arrayValue: [CBOR]? {
    if case .array(let value) = self { return value }
    return nil
  }
}

public enum CBORError: Error, Equatable, Sendable {
  case truncated
  case unsupported(majorType: UInt8, additional: UInt8)
  case tooDeep
  case invalidText
  case nonTextMapKey
  case duplicateMapKey
  case trailingBytes
}

public struct CBORReader {
  public static let maximumDepth = 8

  /// Decodes exactly one value that spans all of `bytes`.
  public static func decode(_ bytes: [UInt8]) throws(CBORError) -> CBOR {
    var reader = CBORReader(bytes: bytes)
    let value = try reader.readValue(depth: 0)
    guard reader.offset == bytes.count else { throw .trailingBytes }
    return value
  }

  private let bytes: [UInt8]
  private var offset = 0

  private init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  private var remaining: Int { bytes.count - offset }

  private mutating func readByte() throws(CBORError) -> UInt8 {
    guard offset < bytes.count else { throw .truncated }
    defer { offset += 1 }
    return bytes[offset]
  }

  private mutating func readBytes(_ count: Int) throws(CBORError) -> [UInt8] {
    guard count >= 0, count <= remaining else { throw .truncated }
    defer { offset += count }
    return Array(bytes[offset..<(offset + count)])
  }

  private mutating func readArgument(_ additional: UInt8, major: UInt8) throws(CBORError) -> UInt64 {
    switch additional {
    case 0..<24:
      return UInt64(additional)
    case 24, 25, 26, 27:
      let width = 1 << Int(additional - 24)
      var value: UInt64 = 0
      for byte in try readBytes(width) { value = value << 8 | UInt64(byte) }
      return value
    default:
      // 28–30 are reserved, 31 is an indefinite length: neither appears in App Attest objects.
      throw .unsupported(majorType: major, additional: additional)
    }
  }

  /// A length that must fit in what's left: each item takes at least one byte, so a count larger than the bytes left
  /// is a lie, and refusing it here keeps allocations bounded by the input's size.
  private mutating func readLength(_ additional: UInt8, major: UInt8) throws(CBORError) -> Int {
    let length = try readArgument(additional, major: major)
    guard length <= UInt64(remaining) else { throw .truncated }
    return Int(length)
  }

  private mutating func readValue(depth: Int) throws(CBORError) -> CBOR {
    guard depth <= Self.maximumDepth else { throw .tooDeep }
    let initial = try readByte()
    let major = initial >> 5
    let additional = initial & 0x1f
    switch major {
    case 0:
      return .unsigned(try readArgument(additional, major: major))
    case 1:
      return .negative(try readArgument(additional, major: major))
    case 2:
      return .bytes(try readBytes(try readLength(additional, major: major)))
    case 3:
      let raw = try readBytes(try readLength(additional, major: major))
      guard let text = String(validating: raw, as: UTF8.self) else { throw .invalidText }
      return .text(text)
    case 4:
      let count = try readLength(additional, major: major)
      var items: [CBOR] = []
      items.reserveCapacity(count)
      for _ in 0..<count { items.append(try readValue(depth: depth + 1)) }
      return .array(items)
    case 5:
      let count = try readLength(additional, major: major)
      var entries: [String: CBOR] = [:]
      for _ in 0..<count {
        guard case .text(let key) = try readValue(depth: depth + 1) else { throw .nonTextMapKey }
        let value = try readValue(depth: depth + 1)
        guard entries.updateValue(value, forKey: key) == nil else { throw .duplicateMapKey }
      }
      return .map(entries)
    default:
      throw .unsupported(majorType: major, additional: additional)
    }
  }
}
