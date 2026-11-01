import Foundation
import IGDBAPI
import OpenAPIRuntime
import TwitchAPI

/// Video games from IGDB (D-22), through the clients generated from `api/sources/igdb.openapi.yaml` and
/// `twitch.openapi.yaml` (D-23). Words only: IGDB has no barcode index. It needs a Twitch application's client id and
/// secret, exchanged for an app access token; requests carry both. IGDB allows four requests a second and requires
/// attribution. A candidate is one release date of a game: one platform in one region.
/// Works are `igdb:game:<id>`, releases `igdb:game:<id>:<platform id>:<region or any>`.
struct IGDBSupplier: DataSupplier {
  typealias Game = IGDBAPI.Components.Schemas.Game

  let connection: SupplierConnection
  let tokens: TwitchTokens
  let client: IGDBAPI.Client

  let name = "igdb"
  let typeID = "video-game"
  let idPrefix = "igdb:"
  let answersBarcodes = false

  static let source = Components.Schemas.Source.named(
    "IGDB",
    url: "https://www.igdb.com",
    attribution: "Data from IGDB.com"
  )
  static let imageHosts: Set<String> = ["images.igdb.com"]
  static let fields = [
    "name", "first_release_date", "cover.image_id", "franchises.name", "collections.name",
    "involved_companies.company.name", "involved_companies.publisher", "release_dates.y",
    "release_dates.region", "release_dates.release_region.region", "release_dates.platform.id",
    "release_dates.platform.name", "platforms.id", "platforms.name",
  ].joined(separator: ",")

  init(connection: SupplierConnection, tokens: TwitchTokens) {
    self.connection = connection
    self.tokens = tokens
    self.client = IGDBAPI.Client(
      serverURL: try! IGDBAPI.Servers.Server1.url(),
      transport: SupplierTransport(connection: connection),
      middlewares: [
        HeadersMiddleware { ["Client-ID": tokens.clientID, "Authorization": "Bearer \(try await tokens.token())"] }
      ]
    )
  }

  func barcode(_ query: BarcodeQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] { [] }

  func search(_ query: SupplierQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    guard !query.title.isEmpty else { return [] }
    let games = try await games(
      "search \"\(Self.escape(query.title))\"; fields \(Self.fields); limit \(min(20, query.limit * 2));"
    )
    let platform = VideoGamePlatforms.platform(subtype: query.subtype)
    var candidates: [Components.Schemas.Candidate] = []
    for game in games {
      for release in Self.releases(game) {
        if let platform, release.subtype != platform.subtype { continue }
        guard VideoGamePlatforms.fits(region: release.region, asked: query.region) else { continue }
        let confidence = TextMatch.confidence(
          title: query.title,
          candidateTitle: game.name ?? "",
          subtitle: query.subtitle,
          candidateSubtitle: release.platformName,
          year: query.year,
          candidateYear: release.year
        )
        if let candidate = candidate(game, release, confidence: confidence, reason: query.reason) {
          candidates.append(candidate)
        }
      }
    }
    return candidates
  }

  func work(id: String) async throws(SupplierFailure) -> Components.Schemas.Work? {
    let prefix = "igdb:game:"
    guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number > 0 else { return nil }
    guard let game = try await games("fields \(Self.fields); where id = \(number); limit 1;").first,
      let title = TextMatch.clean(game.name)
    else { return nil }
    let series = ((game.franchises ?? []) + (game.collections ?? [])).compactMap { TextMatch.clean($0.name) }
    return .init(
      workID: id,
      title: title,
      series: series.isEmpty ? nil : Array(Set(series)).sorted(),
      releases: Self.releases(game).map { release in
        .init(
          releaseID: Self.releaseID(game, release),
          typeID: typeID,
          subtype: release.subtype,
          title: title,
          year: release.year,
          region: release.region
        )
      }
    )
  }

  // MARK: - requests

  private func games(_ query: String) async throws(SupplierFailure) -> [Game] {
    var retried = false
    while true {
      do throws(SupplierFailure) {
        let output = try await connection.call { try await client.games(body: .plainText(HTTPBody(query))) }
        switch output {
        case .ok(let ok): return try await connection.decoded { try ok.body.json }
        case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
        }
      } catch .unauthorized where !retried {
        // The token expired early or was revoked: fetch a new one, once.
        await tokens.invalidate()
        retried = true
      }
    }
  }

  // MARK: - mapping

  struct Release: Hashable {
    var platformID: Int?
    var platformName: String?
    var subtype: String?
    var region: String?
    var year: Int?
  }

  static func releaseID(_ game: Game, _ release: Release) -> String {
    "igdb:game:\(game.id):\(release.platformID.map(String.init) ?? "any"):\(release.region ?? "any")"
  }

  /// The platform's name: the type file's preset when the platform is a subtype, IGDB's own otherwise.
  static func platformName(_ name: String?) -> String? {
    VideoGamePlatforms.platform(subtype: VideoGamePlatforms.subtype(igdbName: name))?.name ?? TextMatch.clean(name)
  }

  /// One per platform and region the game was released in, or one with neither if IGDB lists none.
  static func releases(_ game: Game) -> [Release] {
    var seen = Set<Release>()
    var releases: [Release] = []
    for date in game.releaseDates ?? [] {
      let release = Release(
        platformID: date.platform?.id,
        platformName: platformName(date.platform?.name),
        subtype: VideoGamePlatforms.subtype(igdbName: date.platform?.name),
        region: VideoGamePlatforms.region(date.releaseRegion?.region ?? date.region.map(String.init)),
        year: date.y.flatMap { TextMatch.years.contains($0) ? $0 : nil }
      )
      if seen.insert(release).inserted { releases.append(release) }
    }
    if releases.isEmpty {
      for platform in game.platforms ?? [] {
        releases.append(
          .init(
            platformID: platform.id,
            platformName: platformName(platform.name),
            subtype: VideoGamePlatforms.subtype(igdbName: platform.name),
            year: game.firstReleaseDate.flatMap(Self.year)
          )
        )
      }
    }
    if releases.isEmpty { releases.append(.init(year: game.firstReleaseDate.flatMap(Self.year))) }
    return Array(releases.prefix(12))
  }

  private func candidate(
    _ game: Game,
    _ release: Release,
    confidence: Double,
    reason: Components.Schemas.Reason.KindPayload
  ) -> Components.Schemas.Candidate? {
    guard let title = TextMatch.clean(game.name) else { return nil }
    var fields: [String: Components.Schemas.FieldValue] = [:]
    if let platform = release.platformName { fields["platform"] = .case1(platform) }
    if let publisher = TextMatch.clean(game.involvedCompanies?.first(where: { $0.publisher == true })?.company?.name) {
      fields["publisher"] = .case1(publisher)
    }
    if let region = release.region { fields["region"] = .case1(region) }
    var reasons: [Components.Schemas.Reason] = [.init(kind: reason)]
    if release.subtype != nil { reasons.append(.init(kind: .subtype)) }
    let cover = game.cover?.imageId.flatMap { id -> String? in
      guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), id.count <= 64 else { return nil }
      return allowedImageURL("https://images.igdb.com/igdb/image/upload/t_cover_big/\(id).jpg", hosts: Self.imageHosts)
    }
    return .init(
      releaseID: Self.releaseID(game, release),
      workID: "igdb:game:\(game.id)",
      typeID: typeID,
      subtype: release.subtype,
      title: title,
      subtitle: release.platformName,
      year: release.year,
      region: release.region,
      fields: fields.isEmpty ? nil : .init(additionalProperties: fields),
      images: cover.map { [.init(role: .front, url: $0)] },
      confidence: confidence,
      reasons: reasons,
      sources: [Self.source],
      externalIDs: .init(additionalProperties: ["igdb": String(game.id)])
    )
  }

  /// The UTC year of a Unix timestamp, within the years a candidate can carry.
  static func year(_ timestamp: Int) -> Int? {
    guard abs(timestamp) < 10_000_000_000 else { return nil }
    let year = Calendar(identifier: .gregorian).dateComponents(
      in: TimeZone(identifier: "UTC")!,
      from: Date(timeIntervalSince1970: TimeInterval(timestamp))
    ).year
    return year.flatMap { TextMatch.years.contains($0) ? $0 : nil }
  }

  /// IGDB's query language quotes strings with `"`; quotes, backslashes, semicolons and control characters are
  /// dropped from the words, so they can't end the string and add a clause (D-22).
  static func escape(_ text: String) -> String {
    String(
      text.prefix(200).unicodeScalars
        .filter { $0 != "\"" && $0 != "\\" && $0 != ";" && !CharacterSet.controlCharacters.contains($0) }
        .map(Character.init)
    )
  }
}

/// Twitch's client-credentials token for IGDB, through the client generated from `api/sources/twitch.openapi.yaml`:
/// fetched on first use and again before it expires. The secret goes in the form body, never in a URL (D-22).
/// Callers that arrive while a fetch is in flight wait for that fetch instead of starting their own.
actor TwitchTokens {
  nonisolated let clientID: String
  private let clientSecret: String
  private let connection: SupplierConnection
  private let client: TwitchAPI.Client
  private var current: (token: String, expires: ContinuousClock.Instant)?
  private var inFlight: Task<String, any Error>?

  init(clientID: String, clientSecret: String, connection: SupplierConnection) {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.connection = connection
    self.client = TwitchAPI.Client(
      serverURL: try! TwitchAPI.Servers.Server1.url(),
      transport: SupplierTransport(connection: connection)
    )
  }

  func token() async throws(SupplierFailure) -> String {
    if let current, current.expires > .now { return current.token }
    let task: Task<String, any Error>
    if let inFlight {
      task = inFlight
    } else {
      task = Task { try await self.fetch() }
      inFlight = task
    }
    do {
      let token = try await task.value
      inFlight = nil
      return token
    } catch {
      inFlight = nil
      throw error as? SupplierFailure ?? .failed("token")
    }
  }

  private func fetch() async throws(SupplierFailure) -> String {
    let (client, clientID, clientSecret) = (self.client, self.clientID, self.clientSecret)
    let output = try await connection.call {
      try await client.token(
        body: .urlEncodedForm(.init(clientId: clientID, clientSecret: clientSecret, grantType: .clientCredentials))
      )
    }
    guard case .ok(let ok) = output else { throw .unauthorized }
    let answer = try await connection.decoded { try ok.body.json }
    guard !answer.accessToken.isEmpty else { throw .unauthorized }
    // Renew a minute early, and at least every day.
    let lifetime = min(max(answer.expiresIn - 60, 60), 24 * 3600)
    current = (answer.accessToken, .now + .seconds(lifetime))
    return answer.accessToken
  }

  func invalidate() {
    current = nil
  }
}
