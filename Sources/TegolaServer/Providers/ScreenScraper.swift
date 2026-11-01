import Foundation
import OpenAPIRuntime
import ScreenScraperAPI

/// Video games from ScreenScraper (D-22), through the client generated from `api/sources/screenscraper.openapi.yaml`
/// (D-23). Words only, strong on retro platforms and regional titles. It needs a developer id and password (and,
/// optionally, a member's, for a higher quota). Its API takes them in the query string, so these URLs are never
/// logged, and its media URLs, which carry them too, are never passed to the app: candidates from ScreenScraper have
/// no images. An answer without `jeux` (or `jeu`) is an error page, not "no match".
/// Works are `screenscraper:game:<id>`, releases `screenscraper:game:<id>:<region or any>`.
struct ScreenScraperProvider: DataProvider {
  typealias Game = ScreenScraperAPI.Components.Schemas.Game

  let connection: ProviderConnection
  let credentials: ScreenScraperCredentials
  let client: ScreenScraperAPI.Client

  let name = "screenscraper"
  let typeID = "video-game"
  let idPrefix = "screenscraper:"
  let answersBarcodes = false

  static let source = Components.Schemas.Source.named(
    "ScreenScraper",
    url: "https://www.screenscraper.fr",
    attribution: "Data from ScreenScraper.fr"
  )

  init(connection: ProviderConnection, credentials: ScreenScraperCredentials) {
    self.connection = connection
    self.credentials = credentials
    self.client = ScreenScraperAPI.Client(
      serverURL: try! ScreenScraperAPI.Servers.Server1.url(),
      transport: ProviderTransport(connection: connection)
    )
  }

  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [Components.Schemas.Candidate] { [] }

  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [Components.Schemas.Candidate] {
    guard !query.title.isEmpty else { return [] }
    let platform = VideoGamePlatforms.platform(subtype: query.subtype)
    let output = try await connection.call {
      try await client.search(
        query: .init(
          devid: credentials.developerID,
          devpassword: credentials.developerPassword,
          softname: "tegola-server",
          output: .json,
          ssid: credentials.user,
          sspassword: credentials.password,
          recherche: String(query.title.prefix(200)),
          systemeid: platform?.screenScraperSystem
        )
      )
    }
    let games: [Game]
    switch output {
    case .ok(let ok): games = try await connection.decoded { try ok.body.json.response.jeux }
    case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
    }
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
        candidates.append(
          candidate(id: id, game: game, release: release, confidence: confidence, reason: query.reason)
        )
      }
    }
    return candidates
  }

  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work? {
    let prefix = "screenscraper:game:"
    guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number > 0 else { return nil }
    let output = try await connection.call {
      try await client.game(
        query: .init(
          devid: credentials.developerID,
          devpassword: credentials.developerPassword,
          softname: "tegola-server",
          output: .json,
          ssid: credentials.user,
          sspassword: credentials.password,
          gameid: number
        )
      )
    }
    let game: Game
    switch output {
    case .ok(let ok): game = try await connection.decoded { try ok.body.json.response.jeu }
    case .notFound: return nil
    case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
    }
    let releases = Self.releases(game)
    guard let first = releases.first else { return nil }
    let subtype = VideoGamePlatforms.subtype(screenScraperSystem: game.systeme?.id.flatMap(Int.init))
    return .init(
      workID: id,
      title: first.title,
      releases: releases.map {
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
}

/// A ScreenScraper account. Its `description` never shows the passwords.
struct ScreenScraperCredentials: Sendable, CustomStringConvertible {
  var developerID: String
  var developerPassword: String
  var user: String?
  var password: String?

  var description: String { "ScreenScraperCredentials(developer, \(user == nil ? "no member" : "member"))" }
}
