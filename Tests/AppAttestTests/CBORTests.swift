import AppAttest
import AppAttestTestSupport
import Testing

@Suite("CBOR reader")
struct CBORTests {
  @Test func roundTripsWhatAppAttestUses() throws {
    let value = CBOR.map([
      "fmt": .text("apple-appattest"),
      "attStmt": .map(["x5c": .array([.bytes([1, 2, 3]), .bytes([])])]),
      "authData": .bytes(Array(repeating: 7, count: 300)),
      "n": .unsigned(70_000),
      "m": .negative(4),
    ])
    #expect(try CBORReader.decode(CBOREncoder.encode(value)) == value)
  }

  @Test(
    arguments: [
      ([0x5f], "indefinite byte string"),
      ([0xc0, 0x00], "tag"),
      ([0xf5], "true"),
      ([0xfb, 0, 0, 0, 0, 0, 0, 0, 0], "float"),
      ([0x00, 0x00], "trailing byte"),
      ([0x5a, 0xff, 0xff, 0xff, 0xff], "length past the end"),
      ([0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], "array count past the end"),
      ([0xa1, 0x01, 0x01], "integer map key"),
      ([0xa2, 0x61, 0x61, 0x00, 0x61, 0x61, 0x01], "duplicate map key"),
      ([0x62, 0xc3, 0x28], "invalid UTF-8"),
      ([], "empty"),
    ] as [([UInt8], String)]
  )
  func refuses(_ bytes: [UInt8], _ label: String) {
    #expect(throws: CBORError.self, "\(label)") { try CBORReader.decode(bytes) }
  }

  @Test func capsNesting() {
    let deep = [UInt8](repeating: 0x81, count: 20) + [0x00]
    #expect(throws: CBORError.tooDeep) { try CBORReader.decode(deep) }
  }
}
