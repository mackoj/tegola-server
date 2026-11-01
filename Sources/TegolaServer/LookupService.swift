/// Where answers come from: the game, music and board-game databases the server holds the keys for (PLAN §4).
///
/// Handlers validate their input, then ask a `LookupService`. Sources are added behind this protocol, one per type,
/// each with its own keys from the environment, its own timeouts, and its attribution in `Candidate.sources`.
/// v1's first milestone ships none (`NoSourcesLookupService`): every lookup answers 200 with no candidates, which the
/// contract defines as "no match", and `/health` lists no types, so the app knows not to ask yet (DECISIONS D-12).
package protocol LookupService: Sendable {
  /// Type ids with at least one source.
  var supportedTypes: [String] { get }
  func barcode(_ query: BarcodeQuery) async throws -> [Components.Schemas.Candidate]
  /// `identifyObject`'s hints: words, OCR text, a catalogue number, a barcode. A photo never reaches a
  /// `LookupService`: no source matches images yet, so the handler checks it and drops it (D-24).
  func identify(typeID: String, _ hints: Components.Schemas.IdentifyHints) async throws
    -> [Components.Schemas.Candidate]
  func match(typeID: String, _ item: Components.Schemas.MatchItem) async throws -> [Components.Schemas.Candidate]
  func work(id: String) async throws -> Components.Schemas.Work?
}

package struct BarcodeQuery: Sendable, Equatable {
  package var typeID: String
  package var code: String
  package var symbology: Components.Schemas.Symbology?
  package var subtype: String?
  package var region: String?
}

/// A source is down or rate-limited us. The handler answers 503 with `Retry-After`; the app queues the lookup.
package struct SourceUnavailable: Error {
  package var retryAfter: Int

  package init(retryAfter: Int) {
    self.retryAfter = retryAfter
  }
}

package struct NoSourcesLookupService: LookupService {
  package init() {}

  package var supportedTypes: [String] { [] }

  package func barcode(_ query: BarcodeQuery) async throws -> [Components.Schemas.Candidate] { [] }

  package func identify(typeID: String, _ hints: Components.Schemas.IdentifyHints) async throws
    -> [Components.Schemas.Candidate]
  { [] }

  package func match(typeID: String, _ item: Components.Schemas.MatchItem) async throws
    -> [Components.Schemas.Candidate]
  { [] }

  package func work(id: String) async throws -> Components.Schemas.Work? { nil }
}
