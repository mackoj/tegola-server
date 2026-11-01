import Foundation
import OpenAPIRuntime
import WikidataAPI

/// Wikidata (D-26), through the client generated from `api/sources/wikidata.openapi.yaml` (D-23): words and barcodes
/// (GTIN, P3962), no key. Wikimedia asks for a User-Agent naming the application and a contact, and for requests one
/// at a time; the connection's pacer keeps to it. Its data is CC0.
///
/// One supplier per type, each with its profile: which classes (P31) count as that type, which statement names the
/// subtitle, and its tier. All of them share one connection, so Wikidata sees one paced client. Items are
/// `wikidata:<Q-id>`; an item is a work more often than an edition, so a candidate has no subtype and no work id, and
/// its confidence is weighted down.
struct WikidataSupplier: DataSupplier {
  typealias Entity = WikidataAPI.Components.Schemas.Entity
  typealias Claims = WikidataAPI.Components.Schemas.Claims
  typealias Statements = WikidataAPI.Components.Schemas.Statements

  let profile: WikidataProfile
  let connection: SupplierConnection
  let client: WikidataAPI.Client

  let name = "wikidata"
  let idPrefix = "wikidata:"
  let answersBarcodes = true
  var typeID: String { profile.typeID }
  var tier: SupplierTier { profile.tier }

  /// Labels are asked in English, with Wikidata's fallback to another language; the contract's requests carry no
  /// language yet.
  static let language = "en"

  static let source = Components.Schemas.Source.named(
    "Wikidata",
    url: "https://www.wikidata.org",
    attribution: "Data from Wikidata (CC0)"
  )

  init(profile: WikidataProfile, connection: SupplierConnection, userAgent: String) {
    self.profile = profile
    self.connection = connection
    self.client = WikidataAPI.Client(
      serverURL: try! WikidataAPI.Servers.Server1.url(),
      transport: SupplierTransport(connection: connection),
      middlewares: [HeadersMiddleware { ["User-Agent": userAgent] }]
    )
  }

  func barcode(_ query: BarcodeQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    let codes = Self.gtinVariants(query.code)
    guard !codes.isEmpty else { return [] }
    let answer = try await api(
      .init(
        action: .query,
        format: .json,
        list: .search,
        srsearch: "haswbstatement:" + codes.map { "P3962=\($0)" }.joined(separator: "|"),
        srlimit: 10,
        srnamespace: ._0
      )
    )
    let ids = (answer.query?.search ?? []).compactMap { Self.itemID($0.title) }
    return try await candidates(ids) { entity in
      // The index matches loosely; only an exact GTIN counts as a barcode match.
      let gtins = Self.strings(entity.claims?.p3962)
      guard gtins.contains(where: codes.contains) else { return nil }
      return (0.9, [.init(kind: .barcode)])
    }
  }

  func search(_ query: SupplierQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    // Wikidata's search reads labels and aliases: a catalogue number alone finds nothing worth asking for.
    guard let words = TextMatch.clean(query.title, max: 250) else { return [] }
    let answer = try await api(
      .init(
        action: .wbsearchentities,
        format: .json,
        search: words,
        _type: .item,
        language: Self.language,
        uselang: Self.language,
        limit: min(20, max(5, query.limit * 3))
      )
    )
    let ids = (answer.search ?? []).compactMap { Self.itemID($0.id) }
    return try await candidates(ids) { entity, title, subtitle, year in
      let score = TextMatch.confidence(
        title: query.title,
        candidateTitle: title,
        subtitle: query.subtitle,
        candidateSubtitle: subtitle,
        year: query.year,
        candidateYear: year
      )
      return (score * profile.weight, [.init(kind: query.reason)])
    }
  }

  /// Wikidata items aren't grouped into works with editions here.
  func work(id: String) async throws(SupplierFailure) -> Components.Schemas.Work? { nil }

  // MARK: - requests

  private func api(_ query: WikidataAPI.Operations.Api.Input.Query) async throws(SupplierFailure)
    -> WikidataAPI.Components.Schemas.ApiAnswer
  {
    let output = try await connection.call { try await client.api(query: query) }
    switch output {
    case .ok(let ok):
      let answer = try await connection.decoded { try ok.body.json }
      // The Action API reports its errors in a 200.
      if answer.error != nil { throw .failed("api-error") }
      return answer
    case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
    }
  }

  private func entities(_ ids: [String], props: String) async throws(SupplierFailure) -> [String: Entity] {
    guard !ids.isEmpty else { return [:] }
    let answer = try await api(
      .init(
        action: .wbgetentities,
        format: .json,
        ids: ids.joined(separator: "|"),
        props: props,
        languages: Self.language,
        languagefallback: ._1
      )
    )
    return (answer.entities?.additionalProperties ?? [:]).filter { $0.value.missing == nil }
  }

  /// The items, in the order asked, kept when their class is the profile's; the subtitle's labels in one more
  /// request. `rank` gives a kept item its confidence and reasons, or drops it.
  private func candidates(
    _ ids: [String],
    rank: (Entity) -> (Double, [Components.Schemas.Reason])?
  ) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    try await candidates(ids) { entity, _, _, _ in rank(entity) }
  }

  private func candidates(
    _ ids: [String],
    rank: (Entity, String, String?, Int?) -> (Double, [Components.Schemas.Reason])?
  ) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    var unique: [String] = []
    for id in ids where !unique.contains(id) { unique.append(id) }
    let ordered = Array(unique.prefix(20))
    let found = try await entities(ordered, props: "labels|descriptions|claims")
    let kept: [(id: String, entity: Entity, title: String)] = ordered.compactMap { id in
      guard let entity = found[id], profile.accepts(Self.items(entity.claims?.p31)),
        let title = TextMatch.clean(Self.text(entity.labels?.additionalProperties))
      else { return nil }
      return (id, entity, title)
    }
    let subtitleIDs = kept.compactMap { profile.subtitleItem(in: $0.entity.claims) }
    var subtitleLabels: [String: String] = [:]
    if !subtitleIDs.isEmpty {
      let named = try await entities(Array(Set(subtitleIDs)).sorted(), props: "labels")
      subtitleLabels = named.compactMapValues { TextMatch.clean(Self.text($0.labels?.additionalProperties)) }
    }
    return kept.compactMap { item in
      let subtitle = profile.subtitleItem(in: item.entity.claims).flatMap { subtitleLabels[$0] }
      let year = Self.year(item.entity.claims)
      guard let (confidence, reasons) = rank(item.entity, item.title, subtitle, year) else { return nil }
      return .init(
        releaseID: "wikidata:\(item.id)",
        typeID: typeID,
        title: item.title,
        subtitle: subtitle,
        year: year,
        confidence: min(1, max(0, confidence)),
        reasons: reasons,
        sources: [
          .named("Wikidata", url: "https://www.wikidata.org/wiki/\(item.id)", attribution: Self.source.attribution)
        ],
        externalIDs: .init(additionalProperties: ["wikidata": item.id])
      )
    }
  }

  // MARK: - mapping

  /// Item ids are `Q` and digits; anything else is refused, so an id never smuggles a value into a request.
  static func itemID(_ raw: String?) -> String? {
    guard let raw, raw.count >= 2, raw.count <= 12, raw.first == "Q", raw.dropFirst().first != "0",
      raw.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return raw
  }

  /// The GTINs a scanned code can be stored as: as scanned, and a UPC-A with or without its EAN-13 leading zero.
  static func gtinVariants(_ code: String) -> [String] {
    let digits = code.filter { $0.isASCII && $0.isNumber }
    guard digits.count == code.count, [8, 12, 13, 14].contains(digits.count) else { return [] }
    var variants = [digits]
    if digits.count == 12 { variants.append("0" + digits) }
    if digits.count == 13, digits.hasPrefix("0") { variants.append(String(digits.dropFirst())) }
    return variants
  }

  /// Statements in rank order, preferred first, never deprecated.
  static func ranked(_ statements: Statements?) -> [WikidataAPI.Components.Schemas.DataValue] {
    let usable = (statements ?? []).filter { $0.rank != "deprecated" }
    let preferred = usable.filter { $0.rank == "preferred" }
    return (preferred + usable.filter { $0.rank != "preferred" }).compactMap { $0.mainsnak?.datavalue?.value }
  }

  static func items(_ statements: Statements?) -> [String] {
    ranked(statements).compactMap { if case .case2(let value) = $0 { itemID(value.id) } else { nil } }
  }

  static func strings(_ statements: Statements?) -> [String] {
    ranked(statements).compactMap { if case .case1(let value) = $0 { value } else { nil } }
  }

  /// The earliest publication date (P577), else the inception (P571). Times look like `+1997-05-21T00:00:00Z`.
  static func year(_ claims: Claims?) -> Int? {
    for statements in [claims?.p577, claims?.p571] {
      let years = ranked(statements).compactMap { value -> Int? in
        guard case .case2(let payload) = value, let time = payload.time, time.hasPrefix("+") else { return nil }
        return TextMatch.year(String(time.dropFirst()))
      }
      if let earliest = years.min() { return earliest }
    }
    return nil
  }

  static func text(_ texts: [String: WikidataAPI.Components.Schemas.Text]?) -> String? {
    texts?[language]?.value ?? texts?.values.compactMap(\.value).first
  }
}

/// What one type asks of Wikidata (D-26).
struct WikidataProfile: Sendable {
  enum Subtitle: Sendable {
    case performer, publisher, manufacturer, brand, creator, developer

    func statements(_ claims: WikidataAPI.Components.Schemas.Claims?) -> WikidataAPI.Components.Schemas.Statements? {
      switch self {
      case .performer: claims?.p175
      case .publisher: claims?.p123
      case .manufacturer: claims?.p176
      case .brand: claims?.p1716
      case .creator: claims?.p170
      case .developer: claims?.p178
      }
    }
  }

  var typeID: String
  var tier: SupplierTier
  /// The classes (P31) that are this type. Empty: any class except `excluded`.
  var classes: Set<String>
  var excluded: Set<String> = []
  /// The statements that name the spine's subtitle, first found wins.
  var subtitle: [Subtitle]
  /// An item is a work, not the edition on the shelf: its confidence is weighted down.
  var weight: Double

  func accepts(_ instanceOf: [String]) -> Bool {
    guard !instanceOf.isEmpty else { return false }
    if classes.isEmpty { return !instanceOf.contains(where: excluded.contains) }
    return instanceOf.contains(where: classes.contains)
  }

  func subtitleItem(in claims: WikidataAPI.Components.Schemas.Claims?) -> String? {
    for property in subtitle {
      if let first = WikidataSupplier.items(property.statements(claims)).first { return first }
    }
    return nil
  }

  /// `thing`: Wikidata is its only source, so it's primary there. Anything that is an object, not a person, a place,
  /// a species or a page about Wikipedia itself. The subtitle is the maker.
  static let thing = WikidataProfile(
    typeID: "thing",
    tier: .primary,
    classes: [],
    excluded: [
      "Q5",  // human
      "Q4167410",  // Wikimedia disambiguation page
      "Q4167836",  // Wikimedia category
      "Q13406463",  // Wikimedia list article
      "Q11266439",  // Wikimedia template
      "Q17442446",  // Wikimedia internal item
      "Q16521",  // taxon
      "Q202444",  // given name
      "Q101352",  // family name
      "Q515",  // city
      "Q6256",  // country
      "Q486972",  // human settlement
    ],
    subtitle: [.manufacturer, .brand, .creator, .developer, .publisher],
    weight: 0.85
  )

  /// Music, after MusicBrainz: albums, EPs and singles. The subtitle is the artist.
  static let music = WikidataProfile(
    typeID: "music",
    tier: .fallback,
    classes: [
      "Q482994",  // album
      "Q208569",  // studio album
      "Q209939",  // live album
      "Q222910",  // compilation album
      "Q169930",  // extended play
      "Q134556",  // single
      "Q4176708",  // soundtrack album
      "Q963099",  // remix album
    ],
    subtitle: [.performer],
    weight: 0.75
  )

  /// Video games, after IGDB and ScreenScraper. The spine's subtitle is the platform, which an item that covers
  /// every platform can't give.
  static let videoGame = WikidataProfile(
    typeID: "video-game",
    tier: .fallback,
    classes: [
      "Q7889",  // video game
      "Q865493",  // video game expansion pack
      "Q16070115",  // video game compilation
    ],
    subtitle: [],
    weight: 0.7
  )

  /// Board games, after BoardGameGeek. The subtitle is the publisher.
  static let boardGame = WikidataProfile(
    typeID: "board-games",
    tier: .fallback,
    classes: [
      "Q131436",  // board game
      "Q1272194",  // tabletop game
    ],
    subtitle: [.publisher],
    weight: 0.75
  )

  static let all: [WikidataProfile] = [.thing, .music, .videoGame, .boardGame]
}
