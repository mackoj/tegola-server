import Foundation

/// A development server's source in mock mode (D-28): one per type, answering from the mock catalogue and making up
/// the rest, with no network. It's a `DataProvider` like any other, so its records go through the same router
/// (ranking, merging, caching, tiers) and the app sees what a real source would give it. Ids are
/// `mock:<type>:<id>` and works `mock:<type>:work:<work>`; made-up ones are `mock:<type>:gen:<slug>:<n>` and
/// `mock:<type>:gen:<slug>`, so a made-up work can be made up again from its id.
struct MockProvider: DataProvider {
  let typeID: String
  let catalogue: MockCatalogue
  let name = "mock"
  let answersBarcodes = true
  var idPrefix: String { "mock:\(typeID):" }

  static let source = Components.Schemas.Source.named(
    "Mock",
    attribution: "Mock data from a tegola-server development build"
  )

  private var releases: [MockCatalogue.Release] { catalogue.releases.filter { $0.type == typeID } }

  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [ProviderRecord] {
    guard try await play(catalogue.scenario(barcode: query.code)) else { return [] }
    let codes = Set(Self.variants(query.code))
    let found = releases.filter { release in
      (release.barcodes ?? []).contains { !codes.isDisjoint(with: Self.variants($0)) }
        && (query.subtype == nil || release.subtype == query.subtype)
    }
    if !found.isEmpty { return found.map(record) }
    return [generator.release(slug: "code-" + Self.slug(query.code), edition: 0, asked: .init(subtype: query.subtype))]
  }

  /// The catalogue's releases whose title is close to the words, all of them ranked by the router. When none is a
  /// near match, made-up releases join them: one, two editions of one title (so an import row is ambiguous), or
  /// none (unknown), chosen by the words, so the same words always get the same answer.
  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [ProviderRecord] {
    guard try await play(catalogue.scenario(title: query.title)) else { return [] }
    let fits = releases.filter { release in
      (query.subtype == nil || release.subtype == query.subtype)
        && (query.region == nil || release.region == nil || release.region == query.region)
    }
    if query.title.isEmpty {
      // A catalogue number alone: the catalogue's exact matches, nothing made up.
      guard let number = query.catalogueNumber.map(TextMatch.normalise), !number.isEmpty else { return [] }
      return fits.filter { Self.catalogueNumber($0).map(TextMatch.normalise) == number }.map { release in
        var found = record(release)
        found.matched.insert(.catalogueNumber)
        found.relevance = 1
        return found
      }
    }
    let close = fits.filter { Self.closeness(query.title, $0) >= 0.5 }
    var found = close.map(record)
    if !close.contains(where: { Self.closeness(query.title, $0) >= 0.8 }) {
      let slug = Self.slug(query.title)
      let editions = [1, 1, 1, 1, 1, 1, 1, 2, 2, 0][Int(MockGenerator.hash(slug) % 10)]
      let asked = MockGenerator.Asked(
        title: query.title,
        subtitle: query.subtitle,
        year: query.year,
        subtype: query.subtype,
        region: query.region
      )
      found += (0..<editions).map { generator.release(slug: slug, edition: $0, asked: asked) }
    }
    return found
  }

  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work? {
    _ = try await play(nil)
    if id.hasPrefix(idPrefix + "work:") {
      let work = String(id.dropFirst((idPrefix + "work:").count))
      let members = releases.filter { $0.work == work }
      guard let first = members.first else { return nil }
      return .init(
        workID: id,
        title: first.title,
        releases: members.map {
          .init(
            releaseID: idPrefix + $0.id,
            typeID: typeID,
            subtype: $0.subtype,
            title: $0.title,
            year: $0.year,
            region: $0.region
          )
        }
      )
    }
    if id.hasPrefix(idPrefix + "gen:") {
      let slug = String(id.dropFirst((idPrefix + "gen:").count))
      guard slug.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,59}/) != nil else { return nil }
      return generator.work(slug: slug)
    }
    return nil
  }

  // MARK: - behaviour

  private var generator: MockGenerator { MockGenerator(typeID: typeID, idPrefix: idPrefix, source: Self.source) }

  /// The catalogue's latency, then the scenario, if any: `busy` for an unavailable source, false for "no match".
  private func play(_ scenario: MockCatalogue.Scenario?) async throws(ProviderFailure) -> Bool {
    var delay = catalogue.latencyMs
    if let scenario, scenario.outcome == .slow { delay += scenario.delayMs ?? 3000 }
    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
    guard let scenario else { return true }
    switch scenario.outcome {
    case .unavailable: throw .busy(retryAfter: scenario.retryAfter ?? 30)
    case .nothing: return false
    case .slow: return true
    }
  }

  private func record(_ release: MockCatalogue.Release) -> ProviderRecord {
    ProviderRecord(
      provider: name,
      releaseID: idPrefix + release.id,
      workID: release.work.map { idPrefix + "work:" + $0 },
      typeID: typeID,
      subtype: release.subtype,
      title: release.title,
      subtitle: release.subtitle,
      year: release.year,
      region: release.region,
      fields: release.fields ?? [:],
      entries: release.entries ?? [:],
      externalIDs: ["mock": typeID + ":" + release.id],
      identifying: ["mock"],
      source: Self.source
    )
  }

  // MARK: - matching

  /// How close words are to a release: its title, or its title and subtitle together ("OK Computer Radiohead").
  static func closeness(_ words: String, _ release: MockCatalogue.Release) -> Double {
    let both = release.subtitle.map { release.title + " " + $0 } ?? release.title
    return max(TextMatch.similarity(words, release.title), TextMatch.similarity(words, both))
  }

  static func catalogueNumber(_ release: MockCatalogue.Release) -> String? {
    for key in ["catalogNumber", "catalogueNumber"] {
      if case .case1(let value)? = release.fields?[key] { return value }
    }
    return nil
  }

  /// A code as scanned, digits only, and a UPC-A with or without its EAN-13 leading zero.
  static func variants(_ code: String) -> [String] {
    let digits = code.filter { $0.isASCII && $0.isNumber }
    var variants = [code, digits]
    if digits.count == 12 { variants.append("0" + digits) }
    if digits.count == 13, digits.hasPrefix("0") { variants.append(String(digits.dropFirst())) }
    return variants.filter { !$0.isEmpty }
  }

  /// Folded words as an id-safe slug: a-z, 0-9 and -, at most 60 characters.
  static func slug(_ text: String) -> String {
    let words = TextMatch.normalise(text).split(separator: " ").joined(separator: "-")
    let safe = String(
      words.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    )
    .lowercased()
    let trimmed = String(safe.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "x" : trimmed
  }
}
