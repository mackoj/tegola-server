import BoardGameGeekAPI
import Foundation
import Logging
import OpenAPIRuntime

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// Board games from BoardGameGeek's XML API 2 (D-22), through the client generated from
/// `api/sources/boardgamegeek.openapi.yaml` (D-23). Words only: BGG has no barcode index (tegola's `board-games.yml`
/// says so too). The API needs an application's bearer token, and attribution. A search is two requests: `search`
/// for ids, then `thing` for the details of the best few. Releases and works are both `boardgamegeek:<id>`: BGG's
/// unit is the game, not the edition. Answers are XML, which the generated client leaves raw: they're parsed here,
/// refused when they carry a DOCTYPE, and treated as an error page unless their root is `<items>`.
struct BoardGameGeekSupplier: DataSupplier {
  let connection: SupplierConnection
  let client: BoardGameGeekAPI.Client

  let name = "boardgamegeek"
  let typeID = "board-games"
  let idPrefix = "boardgamegeek:"
  let answersBarcodes = false

  static let source = Components.Schemas.Source.named(
    "BoardGameGeek",
    url: "https://boardgamegeek.com",
    attribution: "Powered by BoardGameGeek"
  )
  static let imageHosts: Set<String> = ["cf.geekdo-images.com"]

  init(connection: SupplierConnection, token: String) {
    self.connection = connection
    self.client = BoardGameGeekAPI.Client(
      serverURL: try! BoardGameGeekAPI.Servers.Server1.url(),
      transport: SupplierTransport(connection: connection),
      middlewares: [HeadersMiddleware { ["Authorization": "Bearer \(token)"] }]
    )
  }

  func barcode(_ query: BarcodeQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] { [] }

  func search(_ query: SupplierQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    guard !query.title.isEmpty else { return [] }
    let output = try await connection.call {
      try await client.search(query: .init(query: String(query.title.prefix(200)), _type: .boardgame))
    }
    let hits: [Item]
    switch output {
    case .ok(let ok): hits = try await parse(Self.body(ok.body))
    case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
    }
    // The search answers names only; keep the closest few, then ask for their details in one request.
    let best = hits.sorted {
      TextMatch.similarity(query.title, $0.name ?? "") > TextMatch.similarity(query.title, $1.name ?? "")
    }
    .prefix(min(10, query.limit * 2))
    guard !best.isEmpty else { return [] }
    let games = try await things(best.map(\.id))
    return games.compactMap { game in
      let confidence = TextMatch.confidence(
        title: query.title,
        candidateTitle: game.name ?? "",
        subtitle: query.subtitle,
        candidateSubtitle: query.subtitle.flatMap { asked in
          game.publishers.max { TextMatch.similarity(asked, $0) < TextMatch.similarity(asked, $1) }
        },
        year: query.year,
        candidateYear: game.year
      )
      return candidate(game, confidence: confidence, reason: query.reason)
    }
  }

  func work(id: String) async throws(SupplierFailure) -> Components.Schemas.Work? {
    guard id.hasPrefix(idPrefix), let number = Int(id.dropFirst(idPrefix.count)), number > 0,
      let game = try await things([number]).first, let title = TextMatch.clean(game.name)
    else { return nil }
    return .init(
      workID: id,
      title: title,
      releases: [.init(releaseID: id, typeID: typeID, title: title, year: game.year)]
    )
  }

  // MARK: - requests

  private func things(_ ids: [Int]) async throws(SupplierFailure) -> [Item] {
    let list = ids.filter { $0 > 0 }.map(String.init).joined(separator: ",")
    guard !list.isEmpty else { return [] }
    let output = try await connection.call { try await client.thing(query: .init(id: list, stats: ._1)) }
    switch output {
    case .ok(let ok):
      return try await parse(Self.body(ok.body)).filter { $0.type == "boardgame" }
    case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
    }
  }

  /// The raw answer, whichever XML type BGG labelled it with (it says `text/xml`).
  static func body(_ body: BoardGameGeekAPI.Operations.Search.Output.Ok.Body) -> HTTPBody {
    switch body {
    case .textXml(let raw), .xml(let raw): raw
    }
  }

  static func body(_ body: BoardGameGeekAPI.Operations.Thing.Output.Ok.Body) -> HTTPBody {
    switch body {
    case .textXml(let raw), .xml(let raw): raw
    }
  }

  /// Reads an answer: at most the connection's size, no DOCTYPE or entity declaration (so no entity is ever
  /// expanded or fetched, whatever the platform's parser does with them), and `<items>` as the root.
  private func parse(_ body: HTTPBody) async throws(SupplierFailure) -> [Item] {
    let data: Data
    do { data = try await Data(collecting: body, upTo: connection.maximumBytes) } catch {
      await connection.record(.failed("undecodable"))
      throw .failed("undecodable")
    }
    guard let items = Self.parse(data) else {
      await connection.record(.failed("undecodable"))
      throw .failed("undecodable")
    }
    return items
  }

  static func parse(_ data: Data) -> [Item]? {
    // UTF-8 without NULs only, so the declaration check below sees what the parser will (libxml2 would also read
    // UTF-16, where these bytes look different).
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return nil }
    let declarations = [Data("<!DOCTYPE".utf8), Data("<!ENTITY".utf8), Data("<!doctype".utf8)]
    guard declarations.allSatisfy({ data.range(of: $0) == nil }) else { return nil }
    let reader = ItemsReader()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse(), reader.root == "items" else { return nil }
    return reader.items
  }

  // MARK: - mapping

  private func candidate(
    _ game: Item,
    confidence: Double,
    reason: Components.Schemas.Reason.KindPayload
  ) -> Components.Schemas.Candidate? {
    guard let title = TextMatch.clean(game.name) else { return nil }
    var fields: [String: Components.Schemas.FieldValue] = [:]
    let designers = game.designers.compactMap { TextMatch.clean($0) }.prefix(3)
    if !designers.isEmpty { fields["designer"] = .case1(designers.joined(separator: ", ")) }
    if let players = Self.players(minimum: game.minPlayers, maximum: game.maxPlayers) {
      fields["players"] = .case1(players)
    }
    if let time = game.playingTime, time > 0 { fields["playTime"] = .case2(Double(time)) }
    if let age = game.minAge, age > 0 { fields["minAge"] = .case2(Double(age)) }
    if let weight = game.weight, weight > 0 { fields["weight"] = .case2((weight * 10).rounded() / 10) }
    var images: [Components.Schemas.Image] = []
    if let url = allowedImageURL(game.image, hosts: Self.imageHosts) { images.append(.init(role: .front, url: url)) }
    if let url = allowedImageURL(game.thumbnail, hosts: Self.imageHosts) {
      images.append(.init(role: .thumbnail, url: url))
    }
    return .init(
      releaseID: "boardgamegeek:\(game.id)",
      workID: "boardgamegeek:\(game.id)",
      typeID: typeID,
      title: title,
      subtitle: TextMatch.clean(game.publishers.first),
      year: game.year,
      fields: fields.isEmpty ? nil : .init(additionalProperties: fields),
      images: images.isEmpty ? nil : images,
      confidence: confidence,
      reasons: [.init(kind: reason)],
      sources: [Self.source],
      externalIDs: .init(additionalProperties: ["boardgamegeek": String(game.id)])
    )
  }

  /// The type file's `players` text: "2–4", or "2" when both ends agree.
  static func players(minimum: Int?, maximum: Int?) -> String? {
    switch (minimum, maximum) {
    case (let low?, let high?) where low > 0 && high >= low: low == high ? "\(low)" : "\(low)–\(high)"
    case (let low?, _) where low > 0: "\(low)+"
    default: nil
    }
  }

  // MARK: - wire

  struct Item {
    var id: Int
    var type: String
    var name: String?
    var year: Int?
    var minPlayers: Int?
    var maxPlayers: Int?
    var playingTime: Int?
    var minAge: Int?
    var weight: Double?
    var image: String?
    var thumbnail: String?
    var designers: [String] = []
    var publishers: [String] = []
  }

  /// Reads `<items><item …>` from a search or thing answer. The primary name wins over alternates.
  final class ItemsReader: NSObject, XMLParserDelegate {
    var items: [Item] = []
    /// The document's root element: a real answer's is `items`.
    private(set) var root: String?
    private var current: Item?
    private var text = ""
    private var primaryName = false

    func parser(
      _ parser: XMLParser,
      didStartElement element: String,
      namespaceURI: String?,
      qualifiedName: String?,
      attributes: [String: String] = [:]
    ) {
      if root == nil { root = element }
      text = ""
      if element == "item" {
        guard let id = attributes["id"].flatMap(Int.init), id > 0 else { return }
        current = Item(id: id, type: attributes["type"] ?? "")
        primaryName = false
        return
      }
      guard current != nil else { return }
      let value = attributes["value"]
      switch element {
      case "name":
        let isPrimary = attributes["type"] == "primary"
        if current?.name == nil || (isPrimary && !primaryName) {
          current?.name = value
          primaryName = isPrimary
        }
      case "yearpublished": current?.year = value.flatMap(Int.init).flatMap { (1800...2100).contains($0) ? $0 : nil }
      case "minplayers": current?.minPlayers = value.flatMap(Int.init)
      case "maxplayers": current?.maxPlayers = value.flatMap(Int.init)
      case "playingtime": current?.playingTime = value.flatMap(Int.init)
      case "minage": current?.minAge = value.flatMap(Int.init)
      case "averageweight": current?.weight = value.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
      case "link":
        guard let value else { return }
        if attributes["type"] == "boardgamedesigner" { current?.designers.append(value) }
        if attributes["type"] == "boardgamepublisher" { current?.publishers.append(value) }
      default: break
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      if text.count < 2048 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
      switch element {
      case "image": current?.image = text.trimmingCharacters(in: .whitespacesAndNewlines)
      case "thumbnail": current?.thumbnail = text.trimmingCharacters(in: .whitespacesAndNewlines)
      case "item":
        if let current { items.append(current) }
        current = nil
      default: break
      }
      text = ""
    }
  }
}
