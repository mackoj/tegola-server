public import AppAttest
public import Foundation
public import Hummingbird
public import Logging
import OpenAPIHummingbird
import OpenAPIRuntime
import PostgresNIO
import ServiceLifecycle

/// Builds the application: one router, the edge middleware in front of everything, the contract's routes under
/// `/v1` with the App Attest middleware, and nothing else. There is no route outside the contract (DECISIONS D-10).
///
/// With a database (D-17), the Postgres client runs as a service of the application, and the schema is migrated
/// before the server binds its port: a database that can't be reached or migrated stops the server.
public func buildApplication(
  configuration: ServerConfiguration,
  logger: Logger
) throws -> some ApplicationProtocol {
  let verifier = try AppAttestVerifier(
    appID: configuration.appID,
    allowedEnvironments: configuration.allowedAttestEnvironments
  )
  var dependencies = ServerDependencies(configuration: configuration, verifier: verifier, now: { Date() })
  var services: [any Service] = []
  var migrate: (@Sendable () async throws -> Void)?
  if let database = configuration.database {
    var databaseLogger = logger
    databaseLogger[metadataKey: "component"] = "database"
    let client = PostgresClient(configuration: try database.clientConfiguration(), backgroundLogger: databaseLogger)
    let store = PostgresStore(
      client: client,
      logger: databaseLogger,
      challengeLifetime: configuration.limits.challengeLifetime,
      challengeCapacity: configuration.limits.maximumOutstandingChallenges
    )
    dependencies.keys = store
    dependencies.challenges = store
    dependencies.storeHealth = { await store.isHealthy() }
    services.append(client)
    migrate = { try await store.migrate() }
  }
  if !configuration.sources.isEmpty {
    dependencies.lookups = makeLookupService(configuration.sources, transport: AsyncHTTPTransport(), logger: logger)
  }
  let router = try buildRouter(dependencies: dependencies, logger: logger)
  var app = Application(
    router: router,
    server: .http1(configuration: .init(idleTimeout: configuration.limits.idleTimeout)),
    configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: nil),
    services: services,
    logger: logger
  )
  if let migrate {
    app.beforeServerStarts {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await migrate() }
        group.addTask {
          try await Task.sleep(for: .seconds(60))
          throw DatabaseStartupTimeout()
        }
        try await group.next()
        group.cancelAll()
      }
    }
  }
  return app
}

struct DatabaseStartupTimeout: Error, CustomStringConvertible {
  var description: String { "the database didn't answer within 60 seconds" }
}

/// What the routes run on. Tests replace the verifier (a fake CA), the clock, the stores and the lookup service.
public struct ServerDependencies: Sendable {
  public var configuration: ServerConfiguration
  public var verifier: AppAttestVerifier
  public var keys: any AttestKeyStore
  public var challenges: any ChallengeStore
  /// Whether the stores answer; `/health` is `degraded` when they don't.
  public var storeHealth: @Sendable () async -> Bool
  public var now: @Sendable () -> Date
  package var lookups: any LookupService

  public init(
    configuration: ServerConfiguration,
    verifier: AppAttestVerifier,
    keys: any AttestKeyStore = InMemoryAttestKeyStore(),
    challenges: (any ChallengeStore)? = nil,
    now: @escaping @Sendable () -> Date
  ) {
    self.configuration = configuration
    self.verifier = verifier
    self.keys = keys
    self.challenges =
      challenges
      ?? InMemoryChallengeStore(
        lifetime: configuration.limits.challengeLifetime,
        capacity: configuration.limits.maximumOutstandingChallenges,
        now: now
      )
    self.storeHealth = { true }
    self.now = now
    self.lookups = NoSourcesLookupService()
  }
}

public func buildRouter(dependencies: ServerDependencies, logger: Logger) throws -> Router<TegolaRequestContext> {
  let configuration = dependencies.configuration
  let router = Router(context: TegolaRequestContext.self)
  router.add(
    middleware: EdgeMiddleware(
      configuration: configuration,
      perIP: RateLimiter(limit: configuration.limits.perIP, now: dependencies.now)
    )
  )
  // Shared by the middleware (one token per call) and `matchBatch` (one more per extra row, D-19).
  let perKey = RateLimiter(limit: configuration.limits.perKey, now: dependencies.now)
  let api = LookupAPI(
    configuration: configuration,
    lookups: dependencies.lookups,
    verifier: dependencies.verifier,
    keys: dependencies.keys,
    challenges: dependencies.challenges,
    storeHealth: dependencies.storeHealth,
    perKey: perKey,
    logger: logger
  )
  let attest = AppAttestMiddleware(
    configuration: configuration,
    verifier: dependencies.verifier,
    keys: dependencies.keys,
    perKey: perKey,
    registrationPerClient: RateLimiter(limit: configuration.limits.registrationPerIP, now: dependencies.now),
    logger: logger,
    now: dependencies.now
  )
  // Compact, sorted JSON with unescaped slashes: smaller responses, the same bytes for the same answer.
  try api.registerHandlers(
    on: router,
    serverURL: URL(string: "/v1")!,
    configuration: .init(jsonEncodingOptions: [.sortedKeys, .withoutEscapingSlashes]),
    middlewares: [attest, CachePolicyMiddleware()]
  )
  return router
}
