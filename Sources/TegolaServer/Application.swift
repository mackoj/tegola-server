public import AppAttest
public import Foundation
public import Hummingbird
public import Logging
import OpenAPIHummingbird
import OpenAPIRuntime

/// Builds the application: one router, the edge middleware in front of everything, the contract's routes under
/// `/v1` with the App Attest middleware, and nothing else. There is no route outside the contract (DECISIONS D-10).
public func buildApplication(
  configuration: ServerConfiguration,
  logger: Logger
) throws -> some ApplicationProtocol {
  let router = try buildRouter(dependencies: ServerDependencies(configuration: configuration), logger: logger)
  return Application(
    router: router,
    server: .http1(configuration: .init(idleTimeout: configuration.limits.idleTimeout)),
    configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: nil),
    logger: logger
  )
}

/// What the routes run on. Tests replace the verifier (a fake CA), the clock and the lookup service.
public struct ServerDependencies: Sendable {
  public var configuration: ServerConfiguration
  public var verifier: AppAttestVerifier
  public var keys: any AttestKeyStore
  public var challenges: ChallengeStore
  public var now: @Sendable () -> Date
  package var lookups: any LookupService

  public init(configuration: ServerConfiguration) throws {
    try self.init(
      configuration: configuration,
      verifier: AppAttestVerifier(
        appID: configuration.appID,
        allowedEnvironments: configuration.allowedAttestEnvironments
      ),
      now: { Date() }
    )
  }

  public init(
    configuration: ServerConfiguration,
    verifier: AppAttestVerifier,
    keys: any AttestKeyStore = InMemoryAttestKeyStore(),
    now: @escaping @Sendable () -> Date
  ) {
    self.configuration = configuration
    self.verifier = verifier
    self.keys = keys
    self.challenges = ChallengeStore(
      lifetime: configuration.limits.challengeLifetime,
      capacity: configuration.limits.maximumOutstandingChallenges,
      now: now
    )
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
      perIP: RateLimiter(limit: configuration.limits.perIP, now: dependencies.now),
      registrationPerIP: RateLimiter(limit: configuration.limits.registrationPerIP, now: dependencies.now)
    )
  )
  let api = LookupAPI(
    configuration: configuration,
    lookups: dependencies.lookups,
    verifier: dependencies.verifier,
    keys: dependencies.keys,
    challenges: dependencies.challenges,
    logger: logger
  )
  let attest = AppAttestMiddleware(
    configuration: configuration,
    verifier: dependencies.verifier,
    keys: dependencies.keys,
    perKey: RateLimiter(limit: configuration.limits.perKey, now: dependencies.now),
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
