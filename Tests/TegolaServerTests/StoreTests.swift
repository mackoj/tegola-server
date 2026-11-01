import AppAttest
import AppAttestTestSupport
import Foundation
import Logging
import PostgresNIO
import Testing

@testable import TegolaServer

/// The store rules, run against both stores: the in-memory ones always, and Postgres when
/// `TEGOLA_TEST_DATABASE_URL` points at a database (CI's service, or `scripts/test.sh` with one running locally). Each
/// Postgres test gets a schema of its own, migrated from scratch and dropped afterwards.
@Suite("Stores")
struct StoreTests {
  enum Kind: String, CaseIterable, CustomTestStringConvertible {
    case memory
    case postgres

    var testDescription: String { rawValue }
  }

  static var databaseURL: String? {
    ProcessInfo.processInfo.environment["TEGOLA_TEST_DATABASE_URL"].flatMap { $0.isEmpty ? nil : $0 }
  }

  static var kinds: [Kind] { databaseURL == nil ? [.memory] : Kind.allCases }

  /// A clock the test moves.
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
  }

  struct Stores {
    var keys: any AttestKeyStore
    var challenges: any ChallengeStore
    var clock: Clock
  }

  static func withStores(
    _ kind: Kind,
    capacity: Int = 100,
    _ body: (Stores) async throws -> Void
  ) async throws {
    let clock = Clock()
    switch kind {
    case .memory:
      try await body(
        Stores(
          keys: InMemoryAttestKeyStore(),
          challenges: InMemoryChallengeStore(lifetime: 300, capacity: capacity, now: { clock.now }),
          clock: clock
        )
      )
    case .postgres:
      try await withPostgres { (client: PostgresClient, logger: Logger) async throws in
        let store = PostgresStore(
          client: client,
          logger: logger,
          challengeLifetime: 300,
          challengeCapacity: capacity,
          now: { clock.now }
        )
        try await store.migrate()
        try await body(Stores(keys: store, challenges: store, clock: clock))
      }
    }
  }

  /// A client on a fresh schema, running for the duration of `body`; the schema is dropped afterwards.
  static func withPostgres(_ body: (PostgresClient, Logger) async throws -> Void) async throws {
    let settings = try DatabaseSettings.parse(try #require(databaseURL))
    var logger = Logger(label: "store-tests")
    logger.logLevel = .error
    let schema = "test_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    let admin = PostgresClient(configuration: try settings.clientConfiguration(), backgroundLogger: logger)
    let client = PostgresClient(
      configuration: try settings.clientConfiguration(searchPath: schema),
      backgroundLogger: logger
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await admin.run() }
      group.addTask { await client.run() }
      try await admin.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"), logger: logger)
      do {
        try await body(client, logger)
      } catch {
        try? await admin.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"), logger: logger)
        group.cancelAll()
        throw error
      }
      try await admin.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"), logger: logger)
      group.cancelAll()
    }
  }

  // MARK: keys

  @Test(arguments: kinds)
  func registersAndFindsAKey(_ kind: Kind) async throws {
    try await Self.withStores(kind) { (stores: Stores) async throws in
      let device = FakeDevice()
      #expect(try await stores.keys.key(id: device.keyID) == nil)
      try await stores.keys.register(device.attestedKey)
      #expect(try await stores.keys.key(id: device.keyID) == AttestKeyRecord(key: device.attestedKey, revoked: false))
    }
  }

  @Test(arguments: kinds)
  func theCounterOnlyMovesForward(_ kind: Kind) async throws {
    try await Self.withStores(kind) { (stores: Stores) async throws in
      let device = FakeDevice()
      try await stores.keys.register(device.attestedKey)
      #expect(try await stores.keys.advanceCounter(id: device.keyID, to: 3))
      #expect(try await !stores.keys.advanceCounter(id: device.keyID, to: 3))
      #expect(try await !stores.keys.advanceCounter(id: device.keyID, to: 2))
      #expect(try await stores.keys.advanceCounter(id: device.keyID, to: UInt32.max))
      #expect(try await stores.keys.key(id: device.keyID)?.key.counter == UInt32.max)
      #expect(try await !stores.keys.advanceCounter(id: FakeDevice().keyID, to: 1))
    }
  }

  /// Twenty concurrent uses of one assertion: exactly one passes.
  @Test(arguments: kinds)
  func concurrentReplaysPassOnce(_ kind: Kind) async throws {
    try await Self.withStores(kind) { (stores: Stores) async throws in
      let device = FakeDevice()
      try await stores.keys.register(device.attestedKey)
      let keys = stores.keys
      let keyID = device.keyID
      let passed = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<20 { group.addTask { try await keys.advanceCounter(id: keyID, to: 7) } }
        return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
      }
      #expect(passed == 1)
    }
  }

  @Test(arguments: kinds)
  func reRegisteringKeepsTheCounterAndTheRevocation(_ kind: Kind) async throws {
    try await Self.withStores(kind) { (stores: Stores) async throws in
      let device = FakeDevice()
      try await stores.keys.register(device.attestedKey)
      #expect(try await stores.keys.advanceCounter(id: device.keyID, to: 9))
      try await stores.keys.revoke(id: device.keyID)
      try await stores.keys.register(device.attestedKey)
      let record = try await stores.keys.key(id: device.keyID)
      #expect(record?.key.counter == 9)
      #expect(record?.revoked == true)
    }
  }

  // MARK: challenges

  @Test(arguments: kinds)
  func aChallengeIsSingleUse(_ kind: Kind) async throws {
    try await Self.withStores(kind) { (stores: Stores) async throws in
      let issued = try #require(try await stores.challenges.issue())
      #expect(Data(base64Encoded: issued.challenge)?.count == 32)
      #expect(issued.expiresAt == stores.clock.now.addingTimeInterval(300))
      #expect(try await stores.challenges.consume(issued.challenge))
      #expect(try await !stores.challenges.consume(issued.challenge))
      #expect(try await !stores.challenges.consume("never-issued"))
    }
  }

  @Test(arguments: kinds)
  func anExpiredChallengeIsRefused(_ kind: Kind) async throws {
    try await Self.withStores(kind) { (stores: Stores) async throws in
      let issued = try #require(try await stores.challenges.issue())
      stores.clock.advance(301)
      #expect(try await !stores.challenges.consume(issued.challenge))
    }
  }

  @Test(arguments: kinds)
  func theChallengeStoreIsBounded(_ kind: Kind) async throws {
    try await Self.withStores(kind, capacity: 3) { (stores: Stores) async throws in
      for _ in 0..<3 { #expect(try await stores.challenges.issue() != nil) }
      #expect(try await stores.challenges.issue() == nil)
      // Expired challenges make room again.
      stores.clock.advance(301)
      #expect(try await stores.challenges.issue() != nil)
    }
  }

  /// Twenty concurrent issues against a cap of five: exactly five challenges (D-19).
  @Test(arguments: kinds)
  func theChallengeCapHoldsUnderConcurrency(_ kind: Kind) async throws {
    try await Self.withStores(kind, capacity: 5) { (stores: Stores) async throws in
      let challenges = stores.challenges
      let issued = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<20 { group.addTask { try await challenges.issue() != nil } }
        return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
      }
      #expect(issued == 5)
    }
  }

  // MARK: Postgres only

  @Test(.enabled(if: databaseURL != nil))
  func migrationsAreIdempotentAndConcurrent() async throws {
    try await Self.withPostgres { (client: PostgresClient, logger: Logger) async throws in
      let store = PostgresStore(client: client, logger: logger, challengeLifetime: 300, challengeCapacity: 10)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 { group.addTask { try await store.migrate() } }
        try await group.waitForAll()
      }
      try await store.migrate()
      let rows = try await client.query("SELECT count(*) FROM tegola_schema_migrations", logger: logger)
      var versions: Int64 = -1
      for try await count in rows.decode(Int64.self) { versions = count }
      #expect(versions == Int64(PostgresStore.migrations.count))
      #expect(await store.isHealthy())
    }
  }

  /// The table refuses what the code would never write, as a last line of defence.
  @Test(.enabled(if: databaseURL != nil))
  func theSchemaRefusesMalformedKeys() async throws {
    try await Self.withPostgres { (client: PostgresClient, logger: Logger) async throws in
      let store = PostgresStore(client: client, logger: logger, challengeLifetime: 300, challengeCapacity: 10)
      try await store.migrate()
      var key = FakeDevice().attestedKey
      key.keyID = Data([1, 2, 3])
      await #expect(throws: (any Error).self) { try await store.register(key) }
    }
  }
}
