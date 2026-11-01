import Foundation

/// Video games from IGDB (D-22), words only: IGDB has no barcode index. It needs a Twitch application's client id and
/// secret, exchanged for an app access token; requests carry both. IGDB allows four requests a second and requires
/// attribution. A candidate is one release date of a game: one platform in one region.
/// Works are `igdb:game:<id>`, releases `igdb:game:<id>:<platform id>:<region or any>`.
struct IGDBSource: CatalogueSource {
  let connection: SourceConnection
  let tokens: TwitchTokens
  let base = URL(string: "https://api.igdb.com/v4/")!

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

  func barcode(_ query: BarcodeQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] { [] }

  func search(_ query: SourceQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] {
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

  func work(id: String) async throws(SourceFailure) -> Components.Schemas.Work? {
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
          releaseID: "igdb:game:\(game.id):\(release.platformID.map(String.init) ?? "any"):\(release.region ?? "any")",
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

  private func games(_ query: String) async throws(SourceFailure) -> [Game] {
    var retried = false
    while true {
      let token = try await tokens.token()
      let request = OutboundRequest(
        method: .post,
        url: base.appendingPathComponent("games"),
        headers: [
          "Client-ID": tokens.clientID, "Authorization": "Bearer \(token)", "Accept": "application/json",
          "Content-Type": "text/plain",
        ],
        body: Data(query.utf8)
      )
      do {
        guard let data = try await connection.send(request) else { return [] }
        return try connection.decode([Game].self, from: data)
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

  /// One per platform and region the game was released in, or one with neither if IGDB lists none.
  static func releases(_ game: Game) -> [Release] {
    var seen = Set<Release>()
    var releases: [Release] = []
    for date in game.releaseDates ?? [] {
      let release = Release(
        platformID: date.platform?.id,
        platformName: TextMatch.clean(date.platform?.name),
        subtype: VideoGamePlatforms.subtype(igdbName: date.platform?.name),
        region: VideoGamePlatforms.region(date.releaseRegion?.region ?? date.region.map(String.init)),
        year: date.y
      )
      if seen.insert(release).inserted { releases.append(release) }
    }
    if releases.isEmpty {
      for platform in game.platforms ?? [] {
        releases.append(
          .init(
            platformID: platform.id,
            platformName: TextMatch.clean(platform.name),
            subtype: VideoGamePlatforms.subtype(igdbName: platform.name),
            year: game.firstReleaseDate.map(Self.year)
          )
        )
      }
    }
    if releases.isEmpty { releases.append(.init(year: game.firstReleaseDate.map(Self.year))) }
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
    let cover = game.cover?.imageID.flatMap { id -> String? in
      guard id.allSatisfy({ $0.isLetter || $0.isNumber }), id.count <= 64 else { return nil }
      return allowedImageURL("https://images.igdb.com/igdb/image/upload/t_cover_big/\(id).jpg", hosts: Self.imageHosts)
    }
    return .init(
      releaseID: "igdb:game:\(game.id):\(release.platformID.map(String.init) ?? "any"):\(release.region ?? "any")",
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

  static func year(_ timestamp: Int) -> Int {
    Calendar(identifier: .gregorian).dateComponents(
      in: TimeZone(identifier: "UTC")!,
      from: Date(timeIntervalSince1970: TimeInterval(timestamp))
    ).year ?? 0
  }

  /// IGDB's query language quotes strings with `"`; quotes, backslashes and control characters are dropped from the
  /// words, so they can't end the string and add a clause (D-22).
  static func escape(_ text: String) -> String {
    String(
      text.prefix(200).unicodeScalars
        .filter { $0 != "\"" && $0 != "\\" && $0 != ";" && !CharacterSet.controlCharacters.contains($0) }
        .map(Character.init)
    )
  }

  // MARK: - wire

  struct Game: Decodable {
    var id: Int
    var name: String?
    var firstReleaseDate: Int?
    var cover: Cover?
    var franchises: [Named]?
    var collections: [Named]?
    var involvedCompanies: [InvolvedCompany]?
    var releaseDates: [ReleaseDate]?
    var platforms: [Platform]?

    enum CodingKeys: String, CodingKey {
      case id, name, cover, franchises, collections, platforms
      case firstReleaseDate = "first_release_date"
      case involvedCompanies = "involved_companies"
      case releaseDates = "release_dates"
    }
  }

  struct Cover: Decodable {
    var imageID: String?

    enum CodingKeys: String, CodingKey { case imageID = "image_id" }
  }

  struct Named: Decodable {
    var name: String?
  }

  struct InvolvedCompany: Decodable {
    var company: Named?
    var publisher: Bool?
  }

  struct ReleaseDate: Decodable {
    var y: Int?
    var region: Int?
    var releaseRegion: ReleaseRegion?
    var platform: Platform?

    enum CodingKeys: String, CodingKey {
      case y, region, platform
      case releaseRegion = "release_region"
    }
  }

  struct ReleaseRegion: Decodable {
    var region: String?
  }

  struct Platform: Decodable {
    var id: Int?
    var name: String?
  }
}

/// Twitch's client-credentials token for IGDB, fetched on first use and again before it expires. The secret goes in
/// the POST body, never in a URL (D-22).
actor TwitchTokens {
  nonisolated let clientID: String
  private let clientSecret: String
  private let connection: SourceConnection
  private var current: (token: String, expires: ContinuousClock.Instant)?

  init(clientID: String, clientSecret: String, connection: SourceConnection) {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.connection = connection
  }

  func token() async throws(SourceFailure) -> String {
    if let current, current.expires > .now { return current.token }
    var form = URLComponents()
    form.queryItems = [
      .init(name: "client_id", value: clientID), .init(name: "client_secret", value: clientSecret),
      .init(name: "grant_type", value: "client_credentials"),
    ]
    let request = OutboundRequest(
      method: .post,
      url: URL(string: "https://id.twitch.tv/oauth2/token")!,
      headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
      body: Data((form.percentEncodedQuery ?? "").utf8)
    )
    guard let data = try await connection.send(request) else { throw .unauthorized }
    let answer = try connection.decode(TokenAnswer.self, from: data)
    guard !answer.accessToken.isEmpty else { throw .unauthorized }
    // Renew a minute early, and at least every day.
    let lifetime = min(max(answer.expiresIn - 60, 60), 24 * 3600)
    current = (answer.accessToken, .now + .seconds(lifetime))
    return answer.accessToken
  }

  func invalidate() {
    current = nil
  }

  struct TokenAnswer: Decodable {
    var accessToken: String
    var expiresIn: Int

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case expiresIn = "expires_in"
    }
  }
}
