import AppAttest
import AppAttestTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import OpenAPIRuntime
import Testing

@testable import TegolaServer

/// The findings of the M1–M2 review (D-19), each sent as the attack or failure it describes.
@Suite("Review fixes")
struct ReviewFixTests {
  // MARK: rate limits

  /// Hummingbird's router ignores empty path segments, so the registration bucket can't be chosen by path prefix.
  @Test(arguments: ["/v1/app-attest/challenge", "/v1//app-attest/challenge", "/v1/app-attest//challenge"])
  func noSpellingOfTheRegistrationPathAvoidsItsBucket(_ path: String) async throws {
    let server = try TestServer { $0.registrationPerIP = RateLimit(capacity: 2, refillPerSecond: 0.001) }
    try await server.run { client in
      for expected in [HTTPResponse.Status.ok, .ok, .tooManyRequests] {
        try await client.execute(uri: path, method: .get, headers: ip("3.3.3.3")) { response in
          #expect(response.status == expected, "\(path)")
        }
      }
    }
  }

  /// Every address of an IPv6 /64 counts as one client.
  @Test func anIPv6Slash64IsOneClient() async throws {
    let server = try TestServer { $0.perIP = RateLimit(capacity: 2, refillPerSecond: 0.001) }
    try await server.run { client in
      for (address, expected) in [
        ("2001:db8:1:2::1", HTTPResponse.Status.ok), ("2001:db8:1:2:ffff::9", .ok),
        ("2001:db8:1:2::abcd", .tooManyRequests),
        ("2001:db8:1:3::1", .ok),
      ] {
        try await client.execute(uri: "/v1/health", method: .get, headers: ip(address)) { response in
          #expect(response.status == expected, "\(address)")
        }
      }
    }
  }

  @Test(arguments: [
    ("203.0.113.7", "203.0.113.7"),
    ("2001:db8:1:2:3:4:5:6", "20010db800010002::/64"),
    ("2001:DB8:1:2::", "20010db800010002::/64"),
    ("::ffff:203.0.113.7", "203.0.113.7"),
    ("unknown", "unknown"),
    ("not:an:address", "not:an:address"),
  ])
  func rateLimitKeys(_ address: String, _ key: String) {
    #expect(RateLimitKey.client(address) == key)
  }

  /// A full table evicts its least recently used entries instead of refusing every new client.
  @Test func aFullLimiterTableStillServesNewClients() async {
    let limiter = RateLimiter(limit: RateLimit(capacity: 10, refillPerSecond: 0.0001), maximumKeys: 100)
    for index in 0..<100 { #expect(await limiter.take("attacker-\(index)") == .allowed) }
    #expect(await limiter.take("newcomer") == .allowed)
    #expect(await limiter.count <= 100)
  }

  @Test func aCostTakesThatManyTokens() async {
    let limiter = RateLimiter(
      limit: RateLimit(capacity: 10, refillPerSecond: 1),
      now: { Date(timeIntervalSince1970: 0) }
    )
    #expect(await limiter.take("k", cost: 9) == .allowed)
    #expect(await limiter.take("k", cost: 2) == .limited(retryAfter: 1))
    #expect(await limiter.take("k", cost: 1) == .allowed)
  }

  /// A batch of 50 rows is 50 lookups against a source's quota, so it costs 50 of the key's tokens.
  @Test func aMatchBatchCostsOneTokenPerRow() async throws {
    let server = try TestServer { $0.perKey = RateLimit(capacity: 10, refillPerSecond: 0.001) }
    let device = FakeDevice()
    let path = "/v1/types/video-game/match"
    @Sendable func body(_ rows: Int) -> [UInt8] {
      let items = (0..<rows).map { #"{"ref":"r\#($0)","title":"t"}"# }.joined(separator: ",")
      return Array(#"{"items":[\#(items)]}"#.utf8)
    }
    try await server.run { client in
      try await server.register(device, client: client)
      // 1 (middleware) + 7 (rows after the first) = 8 of 10.
      try await client.execute(
        uri: path,
        method: .post,
        headers: json(try server.signed(device, counter: 1, method: .post, path: path, body: body(8))),
        body: ByteBuffer(bytes: body(8))
      ) { response in
        #expect(response.status == .ok)
      }
      // 1 + 4 more would be 13.
      try await client.execute(
        uri: path,
        method: .post,
        headers: json(try server.signed(device, counter: 2, method: .post, path: path, body: body(5))),
        body: ByteBuffer(bytes: body(5))
      ) { response in
        #expect(response.status == .tooManyRequests)
        #expect(response.headers[.retryAfter] != nil)
        #expect(problemType(response) == "/problems/too-many-requests")
      }
    }
  }

  // MARK: body cap

  /// The edge refuses a declared Content-Length; a streamed body without one is capped while it's read. The test
  /// client always declares the length, so this calls the middleware directly with a body of unknown length.
  @Test func aStreamedBodyIsCappedWhileRead() async throws {
    let server = try TestServer { $0.maximumBodyBytes = 1024 }
    let middleware = AppAttestMiddleware(
      configuration: server.dependencies.configuration,
      verifier: server.dependencies.verifier,
      keys: server.dependencies.keys,
      perKey: RateLimiter(limit: RateLimit(capacity: 10, refillPerSecond: 1)),
      registrationPerClient: RateLimiter(limit: RateLimit(capacity: 10, refillPerSecond: 1)),
      logger: Logger(label: "test"),
      now: server.dependencies.now
    )
    let chunks = AsyncStream<ArraySlice<UInt8>> { continuation in
      for _ in 0..<4 { continuation.yield(ArraySlice([UInt8](repeating: 0x61, count: 512))) }
      continuation.finish()
    }
    let body = HTTPBody(chunks, length: .unknown, iterationBehavior: .single)
    let (response, _) = try await middleware.intercept(
      HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/v1/app-attest/keys"),
      body: body,
      metadata: .init(),
      operationID: "registerAttestKey"
    ) { _, _, _ in
      Issue.record("the handler must not run")
      return (HTTPResponse(status: .ok), nil)
    }
    #expect(response.status == .contentTooLarge)
  }

  // MARK: keys

  /// A production server that somehow holds a development key refuses it.
  @Test func aProductionServerRefusesADevelopmentKeyInItsStore() async throws {
    let server = try TestServer(environment: .production)
    let device = FakeDevice()
    var key = device.attestedKey
    key.environment = .development
    await server.keys.register(key)
    let path = "/v1/works/w1"
    let headers = try server.signed(device, counter: 1, method: .get, path: path)
    try await server.run { client in
      try await client.execute(uri: path, method: .get, headers: headers) { response in
        #expect(response.status == .forbidden)
      }
    }
  }

  // MARK: responses

  /// A client that only accepts JSON, asking for something that ends in a problem document, is told 406, not 415.
  @Test func anAcceptWithoutProblemJSONIs406() async throws {
    let server = try TestServer(environment: .development)
    var headers = json(ip("1.1.1.1"))
    headers[.tegolaDebugToken] = debugToken
    headers[.accept] = "application/json"
    let requestHeaders = headers
    try await server.run { client in
      try await client.execute(
        uri: "/v1/types/video-game/identify",
        method: .post,
        headers: requestHeaders,
        body: ByteBuffer(string: "{}")
      ) { response in
        #expect(response.status == .notAcceptable)
        #expect(problemType(response) == "/problems/not-acceptable")
      }
    }
  }

  /// The barcode answer is cacheable by a shared cache, and its titles follow Accept-Language.
  @Test func aCacheableBarcodeAnswerVariesByLanguage() async throws {
    let server = try TestServer(environment: .development)
    var headers = ip("1.1.1.1")
    headers[.tegolaDebugToken] = debugToken
    let requestHeaders = headers
    try await server.run { client in
      try await client.execute(
        uri: "/v1/types/music/barcodes/0602547817327",
        method: .get,
        headers: requestHeaders
      ) { response in
        #expect(response.headers[.cacheControl] == "public, max-age=604800")
        #expect(response.headers[.vary] == "Accept-Language")
      }
    }
  }

  // MARK: configuration

  /// `URLComponents` already decodes the user and password; decoding again broke passwords with `%`.
  @Test func aDatabasePasswordIsDecodedOnce() throws {
    #expect(try DatabaseSettings.parse("postgres://u:50%25cd@h/d").password == "50%cd")
    #expect(try DatabaseSettings.parse("postgres://u:p%2541@h/d").password == "p%41")
    #expect(try DatabaseSettings.parse("postgres://us%25er@h/d").username == "us%er")
  }
}
