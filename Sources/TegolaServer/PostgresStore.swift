public import AppAttest
public import Foundation
public import Logging
import NIOCore
import NIOSSL
public import PostgresNIO

/// Where the database is, read from `TEGOLA_DATABASE_URL` (D-17):
/// `postgres://user:password@host:5432/database?sslmode=verify-full`.
///
/// `sslmode` is `verify-full` unless the URL says otherwise: an encrypted connection whose certificate and host name
/// are checked. `require` encrypts without checking the certificate; `disable` is for a private network only (the
/// Compose stack's `db` network). `sslrootcert=/path` trusts that CA file instead of the system's. The password
/// never appears in `description`, so the settings can't leak it into a log.
public struct DatabaseSettings: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public enum TLSMode: String, Sendable, Equatable {
    case disable
    case require
    case verifyFull = "verify-full"
  }

  public var host: String
  public var port: Int
  public var username: String
  public var password: String?
  public var database: String
  public var tls: TLSMode
  public var rootCertificatePath: String?

  public var description: String {
    "postgres://\(username)@\(host):\(port)/\(database)?sslmode=\(tls.rawValue)"
  }

  public var debugDescription: String { description }

  /// `dump` and `String(reflecting:)` see the same fields as `description`, never the password.
  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["host": host, "port": port, "username": username, "database": database, "tls": tls.rawValue],
      displayStyle: .struct
    )
  }

  public static func parse(_ raw: String) throws(ConfigurationError) -> DatabaseSettings {
    let invalid = ConfigurationError.invalid(
      "TEGOLA_DATABASE_URL must look like postgres://user:password@host:5432/database?sslmode=verify-full"
    )
    guard
      let components = URLComponents(string: raw),
      let scheme = components.scheme, ["postgres", "postgresql"].contains(scheme),
      let host = components.host, !host.isEmpty,
      // `user` and `password` are already percent-decoded: decoding again would turn a password's "%25" into "%"
      // and then fail (D-19).
      let username = components.user, !username.isEmpty
    else { throw invalid }
    let database = String(components.path.drop(while: { $0 == "/" }))
    guard !database.isEmpty, !database.contains("/") else { throw invalid }
    let port = components.port ?? 5432
    guard (1...65_535).contains(port) else { throw invalid }

    var tls = TLSMode.verifyFull
    var rootCertificatePath: String?
    for item in components.queryItems ?? [] {
      switch item.name {
      case "sslmode":
        guard let value = item.value, let mode = TLSMode(rawValue: value) else {
          throw .invalid("TEGOLA_DATABASE_URL: sslmode must be disable, require or verify-full")
        }
        tls = mode
      case "sslrootcert":
        guard let value = item.value, !value.isEmpty else { throw invalid }
        rootCertificatePath = value
      default:
        throw .invalid("TEGOLA_DATABASE_URL: unknown parameter \(item.name)")
      }
    }
    return DatabaseSettings(
      host: host,
      port: port,
      username: username,
      password: components.password,
      database: database,
      tls: tls,
      rootCertificatePath: rootCertificatePath
    )
  }

  /// The client configuration, with extra startup parameters (the tests set `search_path` to a schema of their own).
  public func clientConfiguration(searchPath: String? = nil) throws -> PostgresClient.Configuration {
    let tlsConfiguration: PostgresClient.Configuration.TLS
    switch tls {
    case .disable:
      tlsConfiguration = .disable
    case .require, .verifyFull:
      var context = TLSConfiguration.makeClientConfiguration()
      context.minimumTLSVersion = .tlsv12
      if tls == .require { context.certificateVerification = .none }
      if let rootCertificatePath { context.trustRoots = .file(rootCertificatePath) }
      tlsConfiguration = .require(context)
    }
    var configuration = PostgresClient.Configuration(
      host: host,
      port: port,
      username: username,
      password: password,
      database: database,
      tls: tlsConfiguration
    )
    if let searchPath { configuration.options.additionalStartupParameters = [("search_path", searchPath)] }
    configuration.options.connectTimeout = .seconds(10)
    return configuration
  }
}

/// Keys and challenges in Postgres (D-17). Every statement is parameterised (`PostgresQuery` interpolation binds the
/// values; nothing is spliced into SQL text). The counter rule is one conditional `UPDATE`, so of two concurrent
/// replays exactly one advances it, however many server instances run.
public final class PostgresStore: AttestKeyStore, ChallengeStore, Sendable {
  let client: PostgresClient
  let logger: Logger
  let challengeLifetime: TimeInterval
  let challengeCapacity: Int
  let now: @Sendable () -> Date

  public init(
    client: PostgresClient,
    logger: Logger,
    challengeLifetime: TimeInterval,
    challengeCapacity: Int,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.logger = logger
    self.challengeLifetime = challengeLifetime
    self.challengeCapacity = challengeCapacity
    self.now = now
  }

  // MARK: Migrations

  /// Schema versions, applied in order, each in the transaction that records it. Never edit a shipped one: add the
  /// next.
  static let migrations: [(version: Int32, statements: [String])] = [
    (
      1,
      [
        """
        CREATE TABLE attest_keys (
          key_id bytea PRIMARY KEY CHECK (octet_length(key_id) = 32),
          public_key bytea NOT NULL CHECK (octet_length(public_key) = 65),
          counter bigint NOT NULL CHECK (counter BETWEEN 0 AND 4294967295),
          environment text NOT NULL CHECK (environment IN ('production', 'development')),
          revoked boolean NOT NULL DEFAULT false,
          registered_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        """
        CREATE TABLE attest_challenges (
          challenge text PRIMARY KEY CHECK (char_length(challenge) <= 128),
          expires_at timestamptz NOT NULL
        )
        """,
        "CREATE INDEX attest_challenges_expires_at ON attest_challenges (expires_at)",
      ]
    )
  ]

  static let migrationLock: Int64 = 7_452_756_119_418_773_345
  static let challengeLock: Int64 = 7_452_756_119_418_773_346

  /// Brings the schema up to date. Safe to run from several instances at once: a transaction-scoped advisory lock
  /// serialises them, and each version is applied once.
  public func migrate() async throws {
    try await client.withTransaction(logger: logger) { connection in
      // Any constant works as long as it never changes. No digit separators: Postgres before 16 refuses them.
      try await connection.query("SELECT pg_advisory_xact_lock(\(Self.migrationLock))", logger: logger)
      try await connection.query(
        """
        CREATE TABLE IF NOT EXISTS tegola_schema_migrations (
          version integer PRIMARY KEY,
          applied_at timestamptz NOT NULL DEFAULT now()
        )
        """,
        logger: logger
      )
      var applied = Set<Int32>()
      for try await version in try await connection.query(
        "SELECT version FROM tegola_schema_migrations",
        logger: logger
      ).decode(Int32.self) {
        applied.insert(version)
      }
      for migration in Self.migrations where !applied.contains(migration.version) {
        for statement in migration.statements {
          try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
        try await connection.query(
          "INSERT INTO tegola_schema_migrations (version) VALUES (\(migration.version))",
          logger: logger
        )
        logger.info("database migrated", metadata: ["version": "\(migration.version)"])
      }
    }
  }

  /// Whether a trivial query answers within two seconds. `/health` reports `degraded` when it doesn't.
  public func isHealthy() async -> Bool {
    let client = self.client
    let logger = self.logger
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        do {
          try await client.query("SELECT 1", logger: logger)
          return true
        } catch {
          return false
        }
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  // MARK: AttestKeyStore

  public func register(_ key: AttestedKey) async throws {
    try await client.query(
      """
      INSERT INTO attest_keys (key_id, public_key, counter, environment)
      VALUES (\(ByteBuffer(bytes: key.keyID)), \(ByteBuffer(bytes: key.publicKey)), \(Int64(key.counter)), \
      \(key.environment.rawValue))
      ON CONFLICT (key_id) DO NOTHING
      """,
      logger: logger
    )
  }

  public func key(id: Data) async throws -> AttestKeyRecord? {
    let rows = try await client.query(
      "SELECT public_key, counter, environment, revoked FROM attest_keys WHERE key_id = \(ByteBuffer(bytes: id))",
      logger: logger
    )
    for try await (publicKey, counter, environment, revoked) in rows.decode((ByteBuffer, Int64, String, Bool).self) {
      guard
        let environment = AppAttestEnvironment(rawValue: environment),
        let counter = UInt32(exactly: counter)
      else { throw StoreError.corruptRow }
      return AttestKeyRecord(
        key: AttestedKey(
          keyID: id,
          publicKey: Data(publicKey.readableBytesView),
          counter: counter,
          environment: environment
        ),
        revoked: revoked
      )
    }
    return nil
  }

  public func advanceCounter(id: Data, to counter: UInt32) async throws -> Bool {
    let rows = try await client.query(
      """
      UPDATE attest_keys SET counter = \(Int64(counter))
      WHERE key_id = \(ByteBuffer(bytes: id)) AND counter < \(Int64(counter))
      RETURNING 1
      """,
      logger: logger
    )
    var updated = false
    for try await _ in rows.decode(Int32.self) { updated = true }
    return updated
  }

  public func revoke(id: Data) async throws {
    try await client.query(
      "UPDATE attest_keys SET revoked = true WHERE key_id = \(ByteBuffer(bytes: id))",
      logger: logger
    )
  }

  // MARK: ChallengeStore

  /// Issues a challenge unless the store is full. The expiry purge, the count and the insert run in one transaction
  /// under an advisory lock, so concurrent callers, on any number of instances, can't push it past the cap (D-19).
  public func issue() async throws -> (challenge: String, expiresAt: Date)? {
    let current = now()
    let challenge = ChallengeGenerator.make()
    let expiresAt = current.addingTimeInterval(challengeLifetime)
    let capacity = Int64(challengeCapacity)
    let logger = self.logger
    let issued = try await client.withTransaction(logger: logger) { connection -> Bool in
      try await connection.query("SELECT pg_advisory_xact_lock(\(Self.challengeLock))", logger: logger)
      try await connection.query("DELETE FROM attest_challenges WHERE expires_at <= \(current)", logger: logger)
      let rows = try await connection.query(
        """
        INSERT INTO attest_challenges (challenge, expires_at)
        SELECT \(challenge), \(expiresAt)
        WHERE (SELECT count(*) FROM attest_challenges) < \(capacity)
        RETURNING 1
        """,
        logger: logger
      )
      var inserted = false
      for try await _ in rows.decode(Int32.self) { inserted = true }
      return inserted
    }
    return issued ? (challenge, expiresAt) : nil
  }

  public func consume(_ challenge: String) async throws -> Bool {
    let rows = try await client.query(
      "DELETE FROM attest_challenges WHERE challenge = \(challenge) RETURNING expires_at",
      logger: logger
    )
    var valid = false
    for try await expiresAt in rows.decode(Date.self) { valid = expiresAt > now() }
    return valid
  }
}

enum StoreError: Error {
  case corruptRow
}
