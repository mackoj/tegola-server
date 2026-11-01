import AppAttest
public import Foundation
public import NIOCore

/// Everything the server reads from its environment. Loading fails closed: a setting that is missing, malformed or
/// unsafe for the environment stops the server before it binds a port (DECISIONS D-3).
public struct ServerConfiguration: Sendable {
  public enum Environment: String, Sendable {
    /// Accepts only `production` App Attest keys; any request carrying `X-Tegola-Debug-Token` is refused with 403.
    case production
    /// Also accepts `development` keys and, when `TEGOLA_DEBUG_TOKEN` is set, the debug token.
    case development
  }

  public var environment: Environment
  /// `<TeamID>.fr.macko.tegola`.
  public var appID: String
  public var host: String
  public var port: Int
  /// Development only. At least 32 characters.
  public var debugToken: String?
  /// How many reverse proxies in front of the server append to `X-Forwarded-For`. 0 (the default) ignores the
  /// header, so a client can't choose its own rate-limit bucket.
  public var trustedProxyHops: Int
  /// Postgres, from `TEGOLA_DATABASE_URL`. Required in production (D-17); without it a development server keeps keys
  /// and challenges in memory.
  public var database: DatabaseSettings?
  /// Which lookup sources are on, with their keys (D-22). None by default: lookups answer "no match".
  public var sources: SourceSettings
  /// Mock mode (D-28), from `TEGOLA_MOCKS`: a development server answers from this catalogue and made-up releases
  /// instead of the sources. Refused in production, and beside a source's settings.
  public var mocks: MockCatalogue?
  public var limits: Limits

  public struct Limits: Sendable {
    /// Request bodies above this answer 413 before they're decoded.
    public var maximumBodyBytes = 256 * 1024
    /// `identifyObject`'s body, which may carry a photo: the contract's 3 MiB (D-24).
    public var maximumIdentifyBodyBytes = 3 * 1024 * 1024
    /// The photo in an `identifyObject` body: the contract's 2 MiB (D-24).
    public var maximumImageBytes = 2 * 1024 * 1024
    /// How far `X-Tegola-Timestamp` may be from the server's clock.
    public var timestampTolerance: TimeInterval = 5 * 60
    /// How long a challenge lives.
    public var challengeLifetime: TimeInterval = 5 * 60
    /// Outstanding challenges kept at most; beyond it, `GET /app-attest/challenge` answers 503.
    public var maximumOutstandingChallenges = 100_000
    public var perIP = RateLimit(capacity: 120, refillPerSecond: 2)
    /// `GET /app-attest/challenge` and `POST /app-attest/keys`, per IP: an install calls them once.
    public var registrationPerIP = RateLimit(capacity: 10, refillPerSecond: 10.0 / 3600)
    public var perKey = RateLimit(capacity: 60, refillPerSecond: 1)
    public var idleTimeout: TimeAmount = .seconds(30)

    public init() {}

    /// The body cap of one operation: `identifyObject` has its own.
    func maximumBodyBytes(for operationID: String) -> Int {
      operationID == "identifyObject" ? maximumIdentifyBodyBytes : maximumBodyBytes
    }

    /// The largest cap of any operation: what the edge checks a declared length against before the route is known.
    var largestBodyBytes: Int { max(maximumBodyBytes, maximumIdentifyBodyBytes) }
  }

  public init(
    environment: Environment,
    appID: String,
    host: String = "127.0.0.1",
    port: Int = 8080,
    debugToken: String? = nil,
    trustedProxyHops: Int = 0,
    database: DatabaseSettings? = nil,
    sources: SourceSettings = SourceSettings(),
    mocks: MockCatalogue? = nil,
    limits: Limits = Limits()
  ) throws(ConfigurationError) {
    self.environment = environment
    self.appID = appID
    self.host = host
    self.port = port
    self.debugToken = debugToken
    self.trustedProxyHops = trustedProxyHops
    self.database = database
    self.sources = sources
    self.mocks = mocks
    self.limits = limits
    try validate()
  }

  /// Reads `TEGOLA_*` variables. The environment defaults to production, so forgetting it is the safe mistake.
  public static func load(from env: [String: String] = ProcessInfo.processInfo.environment) throws(ConfigurationError)
    -> ServerConfiguration
  {
    let environmentName = env["TEGOLA_ENVIRONMENT"] ?? Environment.production.rawValue
    guard let environment = Environment(rawValue: environmentName) else {
      throw .invalid("TEGOLA_ENVIRONMENT must be production or development")
    }
    guard let appID = env["TEGOLA_APP_ID"] else { throw .invalid("TEGOLA_APP_ID is required (<TeamID>.<bundle id>)") }
    let port = try env["TEGOLA_PORT"].map { (raw) throws(ConfigurationError) -> Int in
      guard let value = Int(raw), (1...65_535).contains(value) else { throw .invalid("TEGOLA_PORT must be 1–65535") }
      return value
    }
    let hops = try env["TEGOLA_TRUSTED_PROXY_HOPS"].map { (raw) throws(ConfigurationError) -> Int in
      guard let value = Int(raw), (0...5).contains(value) else {
        throw .invalid("TEGOLA_TRUSTED_PROXY_HOPS must be 0–5")
      }
      return value
    }
    let database = try env["TEGOLA_DATABASE_URL"].flatMap { $0.isEmpty ? nil : $0 }.map {
      (raw) throws(ConfigurationError) in try DatabaseSettings.parse(raw)
    }
    // Mock data never reaches a production server: refused before the file is even read (D-28).
    let mocksPath = env["TEGOLA_MOCKS"].flatMap { $0.isEmpty ? nil : $0 }
    if environment == .production, mocksPath != nil {
      throw .invalid("TEGOLA_MOCKS is refused in production: unset it")
    }
    // A production server without a database would forget every key at each restart: refuse to start (D-17).
    if environment == .production, database == nil {
      throw .invalid("TEGOLA_DATABASE_URL is required in production (postgres://…)")
    }
    return try ServerConfiguration(
      environment: environment,
      appID: appID,
      host: env["TEGOLA_HOST"] ?? "127.0.0.1",
      port: port ?? 8080,
      debugToken: env["TEGOLA_DEBUG_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
      trustedProxyHops: hops ?? 0,
      database: database,
      sources: try SourceSettings.load(from: env),
      mocks: try mocksPath.map { (path) throws(ConfigurationError) in try MockCatalogue.load(path: path) }
    )
  }

  func validate() throws(ConfigurationError) {
    // Team id (10 upper-case alphanumerics), a dot, a reverse-DNS bundle id.
    guard appID.wholeMatch(of: /[A-Z0-9]{10}\.[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil else {
      throw .invalid("TEGOLA_APP_ID must look like ABCDE12345.fr.macko.tegola")
    }
    if let debugToken {
      guard environment == .development else {
        throw .invalid("TEGOLA_DEBUG_TOKEN is refused in production: unset it")
      }
      guard debugToken.count >= 32 else { throw .invalid("TEGOLA_DEBUG_TOKEN must be at least 32 characters") }
    }
    if mocks != nil {
      guard environment == .development else { throw .invalid("TEGOLA_MOCKS is refused in production: unset it") }
      guard sources.isEmpty else {
        throw .invalid(
          "TEGOLA_MOCKS replaces the lookup sources: unset their settings (\(sources.enabled.joined(separator: ", ")))"
        )
      }
    }
  }

  var allowedAttestEnvironments: Set<AppAttestEnvironment> {
    switch environment {
    case .production: [.production]
    case .development: [.production, .development]
    }
  }
}

/// The lookup sources' settings (D-22). A source is on when its variables are set; a pair set by half, or a value
/// with spaces or control characters, stops the server. Values are never logged: `description` names the sources.
public struct SourceSettings: Sendable, Equatable, CustomStringConvertible {
  /// MusicBrainz: a contact (a URL or an e-mail address) for the User-Agent its terms require. No key.
  public var musicBrainzContact: String?
  public var igdb: ClientCredentials?
  public var screenScraper: ScreenScraperSettings?
  /// BoardGameGeek's XML API bearer token.
  public var boardGameGeekToken: String?
  /// Wikidata: a contact (a URL or an e-mail address) for the User-Agent Wikimedia's policy requires. No key. On, it
  /// answers for `thing` and backs up the other types (D-26).
  public var wikidataContact: String?

  public struct ClientCredentials: Sendable, Equatable, CustomStringConvertible {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
      self.id = id
      self.secret = secret
    }

    /// Never the secret, should it ever be logged.
    public var description: String { "ClientCredentials(id, secret)" }
  }

  public struct ScreenScraperSettings: Sendable, Equatable, CustomStringConvertible {
    public var developerID: String
    public var developerPassword: String
    /// A member account raises the quota; optional, both or neither.
    public var user: String?
    public var password: String?

    public init(developerID: String, developerPassword: String, user: String? = nil, password: String? = nil) {
      self.developerID = developerID
      self.developerPassword = developerPassword
      self.user = user
      self.password = password
    }

    /// Never a password, should it ever be logged.
    public var description: String { "ScreenScraperSettings(developer, \(user == nil ? "no member" : "member"))" }
  }

  public init(
    musicBrainzContact: String? = nil,
    igdb: ClientCredentials? = nil,
    screenScraper: ScreenScraperSettings? = nil,
    boardGameGeekToken: String? = nil,
    wikidataContact: String? = nil
  ) {
    self.musicBrainzContact = musicBrainzContact
    self.igdb = igdb
    self.screenScraper = screenScraper
    self.boardGameGeekToken = boardGameGeekToken
    self.wikidataContact = wikidataContact
  }

  public var isEmpty: Bool { enabled.isEmpty }

  /// The sources that are on, by name.
  public var enabled: [String] {
    var names: [String] = []
    if musicBrainzContact != nil { names.append("musicbrainz") }
    if igdb != nil { names.append("igdb") }
    if screenScraper != nil { names.append("screenscraper") }
    if boardGameGeekToken != nil { names.append("boardgamegeek") }
    if wikidataContact != nil { names.append("wikidata") }
    return names
  }

  public var description: String { enabled.isEmpty ? "none" : enabled.joined(separator: ", ") }

  static func load(from env: [String: String]) throws(ConfigurationError) -> SourceSettings {
    func value(_ name: String) throws(ConfigurationError) -> String? {
      guard let raw = env[name], !raw.isEmpty else { return nil }
      guard raw.count <= 256, raw.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
        throw .invalid("\(name) must be 1–256 printable characters without spaces")
      }
      return raw
    }
    func pair(_ first: String, _ second: String) throws(ConfigurationError) -> (String, String)? {
      switch (try value(first), try value(second)) {
      case (nil, nil): return nil
      case (let a?, let b?): return (a, b)
      default: throw .invalid("\(first) and \(second) go together: set both or neither")
      }
    }
    var settings = SourceSettings()
    settings.musicBrainzContact = try value("TEGOLA_MUSICBRAINZ_CONTACT")
    if let (id, secret) = try pair("TEGOLA_IGDB_CLIENT_ID", "TEGOLA_IGDB_CLIENT_SECRET") {
      settings.igdb = ClientCredentials(id: id, secret: secret)
    }
    let member = try pair("TEGOLA_SCREENSCRAPER_USER", "TEGOLA_SCREENSCRAPER_PASSWORD")
    if let (id, password) = try pair("TEGOLA_SCREENSCRAPER_DEV_ID", "TEGOLA_SCREENSCRAPER_DEV_PASSWORD") {
      settings.screenScraper = ScreenScraperSettings(
        developerID: id,
        developerPassword: password,
        user: member?.0,
        password: member?.1
      )
    } else if member != nil {
      throw .invalid(
        "TEGOLA_SCREENSCRAPER_USER needs TEGOLA_SCREENSCRAPER_DEV_ID and TEGOLA_SCREENSCRAPER_DEV_PASSWORD"
      )
    }
    settings.boardGameGeekToken = try value("TEGOLA_BGG_TOKEN")
    settings.wikidataContact = try value("TEGOLA_WIKIDATA_CONTACT")
    return settings
  }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
  case invalid(String)

  public var description: String {
    switch self {
    case .invalid(let message): message
    }
  }
}

public struct RateLimit: Sendable, Equatable {
  public var capacity: Double
  public var refillPerSecond: Double

  public init(capacity: Double, refillPerSecond: Double) {
    self.capacity = capacity
    self.refillPerSecond = refillPerSecond
  }
}
