import Foundation
import Logging

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// Board games from BoardGameGeek's XML API 2 (D-22), words only: BGG has no barcode index (tegola's
/// `board-games.yml` says so too). The API needs an application's bearer token, and attribution. A search is two
/// requests: `search` for ids, then `thing` for the details of the best few. Releases and works are both
/// `boardgamegeek:<id>`: BGG's unit is the game, not the edition.
struct BoardGameGeekSource: CatalogueSource {
  let connection: SourceConnection
  let token: String
  let base = URL(string: "https://boardgamegeek.com/xmlapi2/")!

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

  func barcode(_ query: BarcodeQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] { [] }

  func search(_ query: SourceQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] {
    guard !query.title.isEmpty else { return [] }
    guard
      let data = try await connection.send(
        request(
          "search",
          [.init(name: "query", value: String(query.title.prefix(200))), .init(name: "type", value: "boardgame")]
        )
      )
    else { return [] }
    let hits = try parse(data)
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

  func work(id: String) async throws(SourceFailure) -> Components.Schemas.Work? {
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

  private func things(_ ids: [Int]) async throws(SourceFailure) -> [Item] {
    let list = ids.filter { $0 > 0 }.map(String.init).joined(separator: ",")
    guard !list.isEmpty,
      let data = try await connection.send(
        request("thing", [.init(name: "id", value: list), .init(name: "stats", value: "1")])
      )
    else { return [] }
    return try parse(data).filter { $0.type == "boardgame" }
  }

  private func request(_ endpoint: String, _ items: [URLQueryItem]) -> OutboundRequest {
    var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
    components.queryItems = items
    return OutboundRequest(
      url: components.url!,
      headers: ["Authorization": "Bearer \(token)", "Accept": "application/xml"]
    )
  }

  private func parse(_ data: Data) throws(SourceFailure) -> [Item] {
    let reader = ItemsReader()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse() else {
      connection.logger.warning("source failed", metadata: ["source": "\(name)", "reason": "undecodable"])
      throw .failed("undecodable")
    }
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
