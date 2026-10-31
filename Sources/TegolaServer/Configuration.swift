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
  public var limits: Limits

  public struct Limits: Sendable {
    /// Request bodies above this answer 413 before they're decoded.
    public var maximumBodyBytes = 256 * 1024
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
  }

  public init(
    environment: Environment,
    appID: String,
    host: String = "127.0.0.1",
    port: Int = 8080,
    debugToken: String? = nil,
    trustedProxyHops: Int = 0,
    limits: Limits = Limits()
  ) throws(ConfigurationError) {
    self.environment = environment
    self.appID = appID
    self.host = host
    self.port = port
    self.debugToken = debugToken
    self.trustedProxyHops = trustedProxyHops
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
    return try ServerConfiguration(
      environment: environment,
      appID: appID,
      host: env["TEGOLA_HOST"] ?? "127.0.0.1",
      port: port ?? 8080,
      debugToken: env["TEGOLA_DEBUG_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
      trustedProxyHops: hops ?? 0
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
  }

  var allowedAttestEnvironments: Set<AppAttestEnvironment> {
    switch environment {
    case .production: [.production]
    case .development: [.production, .development]
    }
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
