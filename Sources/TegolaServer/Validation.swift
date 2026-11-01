/// The contract's limits that swift-openapi-generator doesn't enforce: `pattern`, `maxLength`, `minimum`/`maximum`,
/// `maxItems`, and IdentifyHints's "at least one of" rule. The generated decoders already refuse unknown keys
/// (`additionalProperties: false`) and wrong types. Every handler checks its input here before using it, so nothing
/// past this point sees an input the contract forbids (DECISIONS D-11).
enum Validation {
  struct Failure: Error, Equatable {
    /// Names the field, never echoes its value.
    var field: String
  }

  static let maximumMatchItems = 50

  // Lengths count Unicode scalars, as JSON Schema's maxLength counts code points.
  static func length(_ value: String?, max: Int, _ field: String) throws(Failure) {
    if let value, value.unicodeScalars.count > max { throw Failure(field: field) }
  }

  static func typeID(_ value: String) throws(Failure) {
    guard value.wholeMatch(of: /[a-z][a-z0-9-]{1,40}/) != nil else { throw Failure(field: "typeID") }
  }

  static func subtype(_ value: String?) throws(Failure) {
    guard let value else { return }
    guard value.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,40}/) != nil else { throw Failure(field: "subtype") }
  }

  static func region(_ value: String?) throws(Failure) {
    try length(value, max: 16, "region")
  }

  static func barcode(_ value: String) throws(Failure) {
    guard value.wholeMatch(of: /[0-9A-Za-z-]{6,32}/) != nil else { throw Failure(field: "code") }
  }

  static func workID(_ value: String) throws(Failure) {
    guard !value.isEmpty else { throw Failure(field: "workID") }
    try length(value, max: 128, "workID")
  }

  /// The hints' limits, and, when they're the whole body (`requireQuery`), the "at least one of" rule: a title, OCR
  /// text, a catalogue number or a barcode (D-33 in tegola, D-71). Beside a photo, empty hints are fine.
  static func identify(_ hints: Components.Schemas.IdentifyHints, requireQuery: Bool) throws(Failure) {
    try length(hints.title, max: 300, "title")
    try length(hints.subtitle, max: 300, "subtitle")
    try length(hints.text, max: 2000, "text")
    try length(hints.catalogueNumber, max: 64, "catalogueNumber")
    if let barcode = hints.barcode {
      guard barcode.code.wholeMatch(of: /[0-9A-Za-z-]{6,32}/) != nil else { throw Failure(field: "barcode") }
    }
    if let year = hints.year, !(1800...2100).contains(year) { throw Failure(field: "year") }
    try subtype(hints.subtype)
    try region(hints.region)
    if let limit = hints.limit, !(1...10).contains(limit) { throw Failure(field: "limit") }
    guard requireQuery else { return }
    guard hasQuery(hints) else { throw Failure(field: "title") }
  }

  /// Whether the hints hold something to look up: words that aren't all blank, or a barcode.
  static func hasQuery(_ hints: Components.Schemas.IdentifyHints) -> Bool {
    hints.barcode != nil
      || [hints.title, hints.text, hints.catalogueNumber].contains { value in
        guard let value else { return false }
        return !value.allSatisfy(\.isWhitespace)
      }
  }

  /// A JPEG starts with an SOI marker followed by another marker (`FF D8 FF`). The part's declared type isn't
  /// trusted on its own.
  static func isJPEG(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
  }

  /// `maxItems` is checked by the caller (413, as the contract says); this checks everything else.
  static func match(_ request: Components.Schemas.MatchRequest) throws(Failure) {
    guard !request.items.isEmpty else { throw Failure(field: "items") }
    for item in request.items {
      try length(item.ref, max: 64, "ref")
      try length(item.title, max: 300, "title")
      try length(item.subtitle, max: 300, "subtitle")
      try length(item.note, max: 300, "note")
      try subtype(item.subtype)
      try region(item.region)
    }
  }

  static func registration(_ request: Components.Schemas.AttestKeyRegistration) throws(Failure) {
    try length(request.keyID, max: 128, "keyID")
    try length(request.attestation, max: 16384, "attestation")
    try length(request.challenge, max: 128, "challenge")
  }
}
