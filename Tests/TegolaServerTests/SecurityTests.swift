import AppAttest
import AppAttestTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import TegolaServer

@Suite("Security")
struct SecurityTests {
  @Test func healthIsPublicAndCarriesTheSecurityHeaders() async throws {
    try await TestServer().run { client in
      try await client.execute(uri: "/v1/health", method: .get, headers: ip("1.1.1.1")) { response in
        #expect(response.status == .ok)
        #expect(response.headers[.strictTransportSecurity]?.hasPrefix("max-age=") == true)
        #expect(response.headers[.xContentTypeOptions] == "nosniff")
        #expect(response.headers[.contentSecurityPolicy] == "default-src 'none'; frame-ancestors 'none'")
        #expect(response.headers[.cacheControl] == "no-store")
        #expect(response.headers[.init("Server")!] == nil)
      }
    }
  }

  @Test func securedOperationsRefuseAnUnsignedRequest() async throws {
    try await TestServer().run { client in
      for (uri, method) in [
        ("/v1/types/music/barcodes/0602547817327", HTTPRequest.Method.get), ("/v1/works/w1", .get),
      ] {
        try await client.execute(uri: uri, method: method, headers: ip("1.1.1.1")) { response in
          #expect(response.status == .unauthorized)
          #expect(problemType(response) == "/problems/unauthorized")
        }
      }
      try await client.execute(
        uri: "/v1/types/music/search",
        method: .post,
        headers: json(ip("1.1.1.1")),
        body: ByteBuffer(string: #"{"title":"Ridge Racer"}"#)
      ) { response in
        #expect(response.status == .unauthorized)
      }
    }
  }

  @Test func productionRefusesAnyRequestWithADebugToken() async throws {
    try await TestServer(environment: .production).run { client in
      var headers = ip("1.1.1.1")
      headers[.tegolaDebugToken] = debugToken
      for uri in ["/v1/health", "/v1/types/music/barcodes/0602547817327", "/v1/app-attest/challenge"] {
        try await client.execute(uri: uri, method: .get, headers: headers) { response in
          #expect(response.status == .forbidden)
          #expect(problemType(response) == "/problems/debug-token-refused")
        }
      }
    }
  }

  @Test func developmentAcceptsOnlyTheRightDebugToken() async throws {
    try await TestServer(environment: .development).run { client in
      var headers = json(ip("1.1.1.1"))
      headers[.tegolaDebugToken] = debugToken
      try await client.execute(
        uri: "/v1/types/music/search",
        method: .post,
        headers: headers,
        body: ByteBuffer(string: #"{"title":"Ridge Racer"}"#)
      ) { response in
        #expect(response.status == .ok)
        #expect(String(buffer: response.body) == #"{"candidates":[]}"#)
      }
      headers[.tegolaDebugToken] = debugToken + "x"
      try await client.execute(uri: "/v1/works/w1", method: .get, headers: headers) { response in
        #expect(response.status == .unauthorized)
      }
    }
  }

  @Test func registerThenSignedLookupsWithAStrictlyIncreasingCounter() async throws {
    let server = try TestServer(lookups: CannedLookups(candidates: [candidate("r1", confidence: 0.9)]))
    let device = FakeDevice()
    try await server.run { client in
      try await server.register(device, client: client)
      let path = "/v1/types/video-game/barcodes/0602547817327?symbology=ean13"
      let first = try server.signed(device, counter: 1, method: .get, path: path)
      try await client.execute(uri: path, method: .get, headers: first) { response in
        #expect(response.status == .ok)
        #expect(response.headers[.cacheControl] == "public, max-age=604800")
      }
      // The same assertion again is a replay.
      try await client.execute(uri: path, method: .get, headers: first) { response in
        #expect(response.status == .unauthorized)
      }
      // So is an older counter.
      try await client.execute(
        uri: path,
        method: .get,
        headers: try server.signed(device, counter: 1, method: .get, path: path)
      ) { response in
        #expect(response.status == .unauthorized)
      }
      try await client.execute(
        uri: path,
        method: .get,
        headers: try server.signed(device, counter: 2, method: .get, path: path)
      ) { response in
        #expect(response.status == .ok)
      }
    }
  }

  @Test func theAssertionCoversMethodPathQueryAndBody() async throws {
    let server = try TestServer()
    let device = FakeDevice()
    try await server.run { client in
      try await server.register(device, client: client)
      // Signed for another query string.
      try await client.execute(
        uri: "/v1/types/music/barcodes/0602547817327?region=PAL",
        method: .get,
        headers: try server.signed(device, counter: 1, method: .get, path: "/v1/types/music/barcodes/0602547817327")
      ) { response in
        #expect(response.status == .unauthorized)
      }
      // Signed for another body.
      let signedBody = Array(#"{"title":"Ridge Racer"}"#.utf8)
      try await client.execute(
        uri: "/v1/types/music/search",
        method: .post,
        headers: json(
          try server.signed(device, counter: 2, method: .post, path: "/v1/types/music/search", body: signedBody)
        ),
        body: ByteBuffer(string: #"{"title":"Something else"}"#)
      ) { response in
        #expect(response.status == .unauthorized)
      }
      try await client.execute(
        uri: "/v1/types/music/search",
        method: .post,
        headers: json(
          try server.signed(device, counter: 3, method: .post, path: "/v1/types/music/search", body: signedBody)
        ),
        body: ByteBuffer(bytes: signedBody)
      ) { response in
        #expect(response.status == .ok)
      }
    }
  }

  @Test func refusesAStaleTimestamp() async throws {
    let server = try TestServer()
    let device = FakeDevice()
    try await server.run { client in
      try await server.register(device, client: client)
      let formatter = ISO8601DateFormatter()
      let stale = formatter.string(from: server.ca.now.addingTimeInterval(-301))
      let path = "/v1/works/w1"
      try await client.execute(
        uri: path,
        method: .get,
        headers: try server.signed(device, counter: 1, method: .get, path: path, timestamp: stale)
      ) { response in
        #expect(response.status == .unauthorized)
      }
    }
  }

  @Test func anUnknownKeyIsToldToRegisterAgain() async throws {
    let server = try TestServer()
    try await server.run { client in
      let path = "/v1/works/w1"
      try await client.execute(
        uri: path,
        method: .get,
        headers: try server.signed(FakeDevice(), counter: 1, method: .get, path: path)
      ) { response in
        #expect(response.status == .unauthorized)
        #expect(problemType(response) == "/problems/unknown-key")
      }
    }
  }

  @Test func aRevokedKeyIsForbidden() async throws {
    let server = try TestServer()
    let device = FakeDevice()
    try await server.run { client in
      try await server.register(device, client: client)
      await server.keys.revoke(id: device.keyID)
      let path = "/v1/works/w1"
      try await client.execute(
        uri: path,
        method: .get,
        headers: try server.signed(device, counter: 1, method: .get, path: path)
      ) { response in
        #expect(response.status == .forbidden)
      }
    }
  }

  @Test func aChallengeIsSingleUse() async throws {
    let server = try TestServer()
    let device = FakeDevice()
    try await server.run { client in
      let challenge = try await client.execute(uri: "/v1/app-attest/challenge", method: .get, headers: ip("10.0.0.1")) {
        response in
        #expect(response.headers[.cacheControl] == "no-store")
        return try JSONDecoder().decode(ChallengeBody.self, from: Data(response.body.readableBytesView)).challenge
      }
      #expect(Data(base64Encoded: challenge)?.count == 32)
      let attestation = try server.ca.attestation(
        for: device,
        challenge: Array(challenge.utf8),
        appID: appID,
        environment: .production
      )
      let body = try JSONEncoder().encode([
        "keyID": device.keyID.base64EncodedString(),
        "attestation": Data(attestation).base64EncodedString(),
        "challenge": challenge,
      ])
      for expected in [HTTPResponse.Status.created, .forbidden] {
        try await client.execute(
          uri: "/v1/app-attest/keys",
          method: .post,
          headers: json(ip("10.0.0.1")),
          body: ByteBuffer(bytes: body)
        ) { response in
          #expect(response.status == expected)
        }
      }
    }
  }

  @Test func productionRefusesADevelopmentKey() async throws {
    let server = try TestServer(environment: .production)
    try await server.run { client in
      let challenge = try await client.execute(uri: "/v1/app-attest/challenge", method: .get, headers: ip("10.0.0.1")) {
        try JSONDecoder().decode(ChallengeBody.self, from: Data($0.body.readableBytesView)).challenge
      }
      let device = FakeDevice()
      let attestation = try server.ca.attestation(
        for: device,
        challenge: Array(challenge.utf8),
        appID: appID,
        environment: .development
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
        #expect(response.status == .forbidden)
        #expect(problemType(response) == "/problems/attestation-rejected")
      }
    }
  }

  @Test func reRegisteringKeepsTheCounter() async throws {
    let server = try TestServer()
    let device = FakeDevice()
    try await server.run { client in
      try await server.register(device, client: client)
      #expect(await server.keys.advanceCounter(id: device.keyID, to: 7))
      try await server.register(device, client: client)
      #expect(await server.keys.key(id: device.keyID)?.key.counter == 7)
    }
  }

  @Test func oversizedBodiesAre413BeforeDecoding() async throws {
    let server = try TestServer(environment: .development) { $0.maximumBodyBytes = 1024 }
    try await server.run { client in
      var headers = json(ip("1.1.1.1"))
      headers[.tegolaDebugToken] = debugToken
      try await client.execute(
        uri: "/v1/types/music/search",
        method: .post,
        headers: headers,
        body: ByteBuffer(string: #"{"text":""# + String(repeating: "a", count: 2000) + #""}"#)
      ) { response in
        #expect(response.status == .contentTooLarge)
        #expect(problemType(response) == "/problems/payload-too-large")
      }
    }
  }

  @Test func perIPRateLimitAnswers429WithRetryAfter() async throws {
    let server = try TestServer { $0.perIP = RateLimit(capacity: 3, refillPerSecond: 0.5) }
    try await server.run { client in
      for _ in 0..<3 {
        try await client.execute(uri: "/v1/health", method: .get, headers: ip("9.9.9.9")) { response in
          #expect(response.status == .ok)
        }
      }
      try await client.execute(uri: "/v1/health", method: .get, headers: ip("9.9.9.9")) { response in
        #expect(response.status == .tooManyRequests)
        #expect(response.headers[.retryAfter] == "2")
      }
      // Another address has its own bucket.
      try await client.execute(uri: "/v1/health", method: .get, headers: ip("9.9.9.8")) { response in
        #expect(response.status == .ok)
      }
    }
  }

  @Test func onlyTheTrustedHopOfXForwardedForCounts() async throws {
    let server = try TestServer { $0.perIP = RateLimit(capacity: 1, refillPerSecond: 0.01) }
    try await server.run { client in
      // The client writes whatever it likes on the left; the proxy appends the real address on the right.
      for (spoofed, expected) in [("1.2.3.4", HTTPResponse.Status.ok), ("5.6.7.8", .tooManyRequests)] {
        try await client.execute(uri: "/v1/health", method: .get, headers: ip("\(spoofed), 7.7.7.7")) { response in
          #expect(response.status == expected)
        }
      }
    }
  }

  @Test func registrationHasItsOwnStricterBucket() async throws {
    let server = try TestServer { $0.registrationPerIP = RateLimit(capacity: 2, refillPerSecond: 0.001) }
    try await server.run { client in
      for expected in [HTTPResponse.Status.ok, .ok, .tooManyRequests] {
        try await client.execute(uri: "/v1/app-attest/challenge", method: .get, headers: ip("3.3.3.3")) { response in
          #expect(response.status == expected)
        }
      }
      try await client.execute(uri: "/v1/health", method: .get, headers: ip("3.3.3.3")) { response in
        #expect(response.status == .ok)
      }
    }
  }

  @Test func unknownRoutesAreAProblemNotAnEmpty404() async throws {
    try await TestServer().run { client in
      for uri in ["/", "/admin", "/v1/../etc/passwd", "/v2/health"] {
        try await client.execute(uri: uri, method: .get, headers: ip("1.1.1.1")) { response in
          #expect(response.status == .notFound)
          #expect(problemType(response) == "/problems/not-found")
        }
      }
    }
  }
}
