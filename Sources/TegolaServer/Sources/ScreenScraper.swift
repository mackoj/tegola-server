import Foundation

/// Video games from ScreenScraper (D-22), words only, strong on retro platforms and regional titles. It needs a
/// developer id and password (and, optionally, a member's, for a higher quota). Its API takes them in the query
/// string, so these URLs are never logged, and its media URLs, which carry them too, are never passed to the app:
/// candidates from ScreenScraper have no images.
/// Works are `screenscraper:game:<id>`, releases `screenscraper:game:<id>:<region or any>`.
struct ScreenScraperSource: CatalogueSource {
  let connection: SourceConnection
  let credentials: ScreenScraperCredentials
  let base = URL(string: "https://api.screenscraper.fr/api2/")!

  let name = "screenscraper"
  let typeID = "video-game"
  let idPrefix = "screenscraper:"
  let answersBarcodes = false

  static let source = Components.Schemas.Source.named(
    "ScreenScraper",
    url: "https://www.screenscraper.fr",
    attribution: "Data from ScreenScraper.fr"
  )

  func barcode(_ query: BarcodeQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] { [] }

  func search(_ query: SourceQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] {
    guard !query.title.isEmpty else { return [] }
    var items = [URLQueryItem(name: "recherche", value: String(query.title.prefix(200)))]
    let platform = VideoGamePlatforms.platform(subtype: query.subtype)
    if let platform { items.append(.init(name: "systemeid", value: String(platform.screenScraperSystem))) }
    guard let data = try await connection.send(request("jeuRecherche.php", items)) else { return [] }
    let games = try connection.decode(SearchAnswer.self, from: data).response.jeux ?? []
    var candidates: [Components.Schemas.Candidate] = []
    for game in games.prefix(query.limit * 2) {
      guard let id = game.id.flatMap(Int.init), id > 0 else { continue }  // an empty search answers [{}]
      for release in Self.releases(game) {
        guard VideoGamePlatforms.fits(region: release.region, asked: query.region) else { continue }
        let confidence = TextMatch.confidence(
          title: query.title,
          candidateTitle: release.title,
          subtitle: query.subtitle,
          candidateSubtitle: TextMatch.clean(game.systeme?.text),
          year: query.year,
          candidateYear: release.year
        )
        candidates.append(candidate(id: id, game: game, release: release, confidence: confidence, reason: query.reason))
      }
    }
    return candidates
  }

  func work(id: String) async throws(SourceFailure) -> Components.Schemas.Work? {
    let prefix = "screenscraper:game:"
    guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number > 0 else { return nil }
    guard let data = try await connection.send(request("jeuInfos.php", [.init(name: "gameid", value: String(number))]))
    else { return nil }
    guard let game = try connection.decode(InfoAnswer.self, from: data).response.jeu,
      let release = Self.releases(game).first
    else { return nil }
    let subtype = VideoGamePlatforms.subtype(screenScraperSystem: game.systeme?.id.flatMap(Int.init))
    return .init(
      workID: id,
      title: release.title,
      releases: Self.releases(game).map {
        .init(
          releaseID: "screenscraper:game:\(number):\($0.region ?? "any")",
          typeID: typeID,
          subtype: subtype,
          title: $0.title,
          year: $0.year,
          region: $0.region
        )
      }
    )
  }

  // MARK: - requests

  private func request(_ endpoint: String, _ items: [URLQueryItem]) -> OutboundRequest {
    var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
    var query = [
      URLQueryItem(name: "devid", value: credentials.developerID),
      URLQueryItem(name: "devpassword", value: credentials.developerPassword),
      URLQueryItem(name: "softname", value: "tegola-server"),
      URLQueryItem(name: "output", value: "json"),
    ]
    if let user = credentials.user, let password = credentials.password {
      query += [URLQueryItem(name: "ssid", value: user), URLQueryItem(name: "sspassword", value: password)]
    }
    components.queryItems = query + items
    return OutboundRequest(url: components.url!, headers: ["Accept": "application/json"])
  }

  // MARK: - mapping

  struct Release {
    var title: String
    var region: String?
    var year: Int?
  }

  /// One per region ScreenScraper dates the game in, titled with that region's name when it has one.
  static func releases(_ game: Game) -> [Release] {
    let names = game.noms ?? []
    func title(for region: String?) -> String? {
      let preferred =
        names.first { $0.region == region } ?? names.first { $0.region == "ss" }
        ?? names.first { $0.region == "wor" } ?? names.first
      return TextMatch.clean(preferred?.text)
    }
    var releases: [Release] = []
    var regions = Set<String>()
    for date in game.dates ?? [] {
      let region = VideoGamePlatforms.region(date.region)
      guard regions.insert(region ?? "any").inserted, let title = title(for: date.region) else { continue }
      releases.append(.init(title: title, region: region, year: TextMatch.year(date.text)))
    }
    if releases.isEmpty, let title = title(for: nil) { releases.append(.init(title: title)) }
    return Array(releases.prefix(6))
  }

  private func candidate(
    id: Int,
    game: Game,
    release: Release,
    confidence: Double,
    reason: Components.Schemas.Reason.KindPayload
  ) -> Components.Schemas.Candidate {
    let system = TextMatch.clean(game.systeme?.text)
    let subtype = VideoGamePlatforms.subtype(screenScraperSystem: game.systeme?.id.flatMap(Int.init))
    var fields: [String: Components.Schemas.FieldValue] = [:]
    if let platform = VideoGamePlatforms.platform(subtype: subtype)?.name ?? system {
      fields["platform"] = .case1(platform)
    }
    if let publisher = TextMatch.clean(game.editeur?.text) { fields["publisher"] = .case1(publisher) }
    if let region = release.region { fields["region"] = .case1(region) }
    var reasons: [Components.Schemas.Reason] = [.init(kind: reason)]
    if subtype != nil { reasons.append(.init(kind: .subtype)) }
    return .init(
      releaseID: "screenscraper:game:\(id):\(release.region ?? "any")",
      workID: "screenscraper:game:\(id)",
      typeID: typeID,
      subtype: subtype,
      title: release.title,
      subtitle: system,
      year: release.year,
      region: release.region,
      fields: fields.isEmpty ? nil : .init(additionalProperties: fields),
      confidence: confidence,
      reasons: reasons,
      sources: [Self.source],
      externalIDs: .init(additionalProperties: ["screenscraper": String(id)])
    )
  }

  // MARK: - wire

  struct SearchAnswer: Decodable {
    var response: Response

    struct Response: Decodable {
      var jeux: [Game]?
    }
  }

  struct InfoAnswer: Decodable {
    var response: Response

    struct Response: Decodable {
      var jeu: Game?
    }
  }

  struct Game: Decodable {
    var id: String?
    var noms: [Regional]?
    var systeme: Named?
    var editeur: Named?
    var dates: [Regional]?
  }

  struct Regional: Decodable {
    var region: String?
    var text: String?
  }

  struct Named: Decodable {
    var id: String?
    var text: String?
  }
}

struct ScreenScraperCredentials: Sendable {
  var developerID: String
  var developerPassword: String
  var user: String?
  var password: String?
}
