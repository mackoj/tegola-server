import AppAttest
import AppAttestTestSupport
import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import TegolaServer

let appID = "ABCDE12345.fr.macko.tegola"
// TEGOLA-TEST-SENTINEL: a fake debug token for tests.
let debugToken = "test-debug-token-0123456789abcdef0123456789"

/// A server on the fake CA and a fixed clock, with an in-memory key store the test can look into.
struct TestServer {
  let ca: FakeAppAttestCA
  let dependencies: ServerDependencies
  let keys: InMemoryAttestKeyStore

  init(
    environment: ServerConfiguration.Environment = .production,
    limits: (inout ServerConfiguration.Limits) -> Void = { _ in },
    lookups: (any LookupService)? = nil
  ) throws {
    ca = try FakeAppAttestCA()
    var configuredLimits = ServerConfiguration.Limits()
    limits(&configuredLimits)
    let configuration = try ServerConfiguration(
      environment: environment,
      appID: appID,
      debugToken: environment == .development ? debugToken : nil,
      trustedProxyHops: 1,
      limits: configuredLimits
    )
    keys = InMemoryAttestKeyStore()
    let now = ca.now
    var dependencies = ServerDependencies(
      configuration: configuration,
      verifier: try ca.verifier(appID: appID, environments: configuration.allowedAttestEnvironments),
      keys: keys,
      now: { now }
    )
    if let lookups { dependencies.lookups = lookups }
    self.dependencies = dependencies
  }

  var timestamp: String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: ca.now)
  }

  func run(_ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
    var logger = Logger(label: "test")
    logger.logLevel = .critical
    let router = try buildRouter(dependencies: dependencies, logger: logger)
    let app = Application(router: router, logger: logger)
    try await app.test(.router, body)
  }

  /// Registers `device` through the real endpoints and returns nothing; fails the test if it isn't 201.
  func register(_ device: FakeDevice, client: some TestClientProtocol, environment: AppAttestEnvironment = .production)
    async throws
  {
    let challenge = try await client.execute(uri: "/v1/app-attest/challenge", method: .get, headers: ip("10.0.0.1")) {
      response in
      #expect(response.status == .ok)
      return try JSONDecoder().decode(ChallengeBody.self, from: Data(response.body.readableBytesView)).challenge
    }
    let attestation = try ca.attestation(
      for: device,
      challenge: Array(challenge.utf8),
      appID: appID,
      environment: environment
    )
    let body = try JSONEncoder().encode([
      "keyID": device.keyID.base64EncodedString(),
      "attestation": Data(attestation).base64EncodedString(),
      "challenge": challenge,
    ])
    try await client.execute(
      uri: "/v1/app-attest/keys",
      method: .post,
      headers: json(ip("10.0.0.1")),
      body: ByteBuffer(bytes: body)
    ) { response in
      #expect(response.status == .created)
    }
  }

  /// Headers for a request signed by `device` with `counter`.
  func signed(
    _ device: FakeDevice,
    counter: UInt32,
    method: HTTPRequest.Method,
    path: String,
    body: [UInt8] = [],
    timestamp: String? = nil
  ) throws -> HTTPFields {
    let timestamp = timestamp ?? self.timestamp
    let hash = RequestSignature.clientDataHash(
      method: method.rawValue,
      pathWithQuery: path,
      timestamp: timestamp,
      body: body
    )
    var fields = ip("10.0.0.2")
    fields[.tegolaKeyID] = device.keyID.base64EncodedString()
    fields[.tegolaTimestamp] = timestamp
    fields[.tegolaAssertion] = Data(try device.assertion(clientDataHash: hash, counter: counter, appID: appID))
      .base64EncodedString()
    return fields
  }
}

struct ChallengeBody: Decodable {
  var challenge: String
  var expiresAt: String
}

func ip(_ address: String) -> HTTPFields {
  var fields = HTTPFields()
  fields[.forwardedFor] = address
  return fields
}

func json(_ fields: HTTPFields = [:]) -> HTTPFields {
  var fields = fields
  fields[.contentType] = "application/json"
  return fields
}

func problemType(_ response: TestResponse) -> String? {
  #expect(response.headers[.contentType]?.hasPrefix("application/problem+json") == true)
  return try? JSONDecoder().decode(ProblemDocument.self, from: Data(response.body.readableBytesView)).type
}

/// A lookup service with canned answers.
struct CannedLookups: LookupService {
  var candidates: [Components.Schemas.Candidate] = []
  var unavailable = false

  var supportedTypes: [String] { ["video-game", "music"] }

  func barcode(_ query: BarcodeQuery) async throws -> [Components.Schemas.Candidate] {
    if unavailable { throw SourceUnavailable(retryAfter: 30) }
    return candidates
  }

  func search(typeID: String, _ request: Components.Schemas.SearchRequest) async throws
    -> [Components.Schemas.Candidate]
  { candidates }

  func match(typeID: String, _ item: Components.Schemas.MatchItem) async throws -> [Components.Schemas.Candidate] {
    item.title == "Tetris" ? candidates : []
  }

  func work(id: String) async throws -> Components.Schemas.Work? { nil }
}

func candidate(_ id: String, confidence: Double) -> Components.Schemas.Candidate {
  .init(
    releaseID: id,
    typeID: "video-game",
    title: id,
    confidence: confidence,
    reasons: [.init(kind: .title)],
    sources: [.init(name: "Test")]
  )
}
