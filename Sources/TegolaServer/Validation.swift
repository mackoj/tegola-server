/// The contract's limits that swift-openapi-generator doesn't enforce: `pattern`, `maxLength`, `minimum`/`maximum`,
/// `maxItems`, and SearchRequest's "at least one of" rule. The generated decoders already refuse unknown keys
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

  static func search(_ request: Components.Schemas.SearchRequest) throws(Failure) {
    try length(request.title, max: 300, "title")
    try length(request.subtitle, max: 300, "subtitle")
    try length(request.text, max: 2000, "text")
    try length(request.catalogueNumber, max: 64, "catalogueNumber")
    if let year = request.year, !(1800...2100).contains(year) { throw Failure(field: "year") }
    try subtype(request.subtype)
    try region(request.region)
    if let limit = request.limit, !(1...10).contains(limit) { throw Failure(field: "limit") }
    let hasQuery = [request.title, request.text, request.catalogueNumber].contains { value in
      guard let value else { return false }
      return !value.allSatisfy(\.isWhitespace)
    }
    guard hasQuery else { throw Failure(field: "title") }
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
