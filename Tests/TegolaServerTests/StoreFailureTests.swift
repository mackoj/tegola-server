import AppAttest
import AppAttestTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import TegolaServer

/// A store that can't answer (the database is down) is the server's problem: 503 with `Retry-After`, never a 401
/// that would make the app throw its key away, and never a pass (D-17).
@Suite("Store failures")
struct StoreFailureTests {
  struct Down: Error {}

  struct DownStore: AttestKeyStore, ChallengeStore {
    func register(_ key: AttestedKey) async throws { throw Down() }
    func key(id: Data) async throws -> AttestKeyRecord? { throw Down() }
    func advanceCounter(id: Data, to counter: UInt32) async throws -> Bool { throw Down() }
    func revoke(id: Data) async throws { throw Down() }
    func issue() async throws -> (challenge: String, expiresAt: Date)? { throw Down() }
    func consume(_ challenge: String) async throws -> Bool { throw Down() }
  }

  /// Answers lookups of registered keys, then fails when the counter is advanced.
  actor FailsOnAdvance: AttestKeyStore {
    let inner = InMemoryAttestKeyStore()
    func register(_ key: AttestedKey) async throws { await inner.register(key) }
    func key(id: Data) async throws -> AttestKeyRecord? { await inner.key(id: id) }
    func advanceCounter(id: Data, to counter: UInt32) async throws -> Bool { throw Down() }
    func revoke(id: Data) async throws { await inner.revoke(id: id) }
  }

  @Test func aSignedCallIs503WhenTheKeyStoreIsDown() async throws {
    var server = try TestServer()
    server.dependencies.keys = DownStore()
    let path = "/v1/works/w1"
    let headers = try server.signed(FakeDevice(), counter: 1, method: .get, path: path)
    try await server.run { client in
      try await client.execute(uri: path, method: .get, headers: headers) { response in
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "5")
        #expect(problemType(response) == "/problems/unavailable")
      }
    }
  }

  @Test func aStoreThatFailsWhileAdvancingNeverLetsTheCallThrough() async throws {
    var server = try TestServer()
    let store = FailsOnAdvance()
    let device = FakeDevice()
    try await store.register(device.attestedKey)
    server.dependencies.keys = store
    let path = "/v1/works/w1"
    let headers = try server.signed(device, counter: 1, method: .get, path: path)
    try await server.run { client in
      try await client.execute(uri: path, method: .get, headers: headers) { response in
        #expect(response.status == .serviceUnavailable)
      }
    }
  }

  @Test func registrationIs503WhenTheStoresAreDown() async throws {
    var server = try TestServer()
    server.dependencies.keys = DownStore()
    server.dependencies.challenges = DownStore()
    try await server.run { client in
      try await client.execute(uri: "/v1/app-attest/challenge", method: .get, headers: ip("10.0.0.1")) { response in
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "5")
        #expect(problemType(response) == "/problems/unavailable")
      }
      let body = try JSONEncoder().encode([
        "keyID": FakeDevice().keyID.base64EncodedString(),
        "attestation": Data([1, 2, 3]).base64EncodedString(),
        "challenge": "c",
      ])
      try await client.execute(
        uri: "/v1/app-attest/keys",
        method: .post,
        headers: json(ip("10.0.0.1")),
        body: ByteBuffer(bytes: body)
      ) { response in
        #expect(response.status == .serviceUnavailable)
      }
    }
  }

  @Test func healthIsDegradedWhenTheStoresDontAnswer() async throws {
    var server = try TestServer()
    server.dependencies.storeHealth = { false }
    try await server.run { client in
      try await client.execute(uri: "/v1/health", method: .get, headers: ip("1.1.1.1")) { response in
        #expect(response.status == .ok)
        #expect(String(buffer: response.body) == #"{"status":"degraded","types":[]}"#)
      }
    }
  }
}
