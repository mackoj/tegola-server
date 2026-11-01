import AppAttest
import AppAttestTestSupport
import Crypto
import Foundation
import SwiftASN1
import Testing
import X509

@Suite("App Attest verification")
struct AppAttestVerifierTests {
  let appID = "ABCDE12345.fr.macko.tegola"
  let challenge = Array("bm90LWEtcmVhbC1jaGFsbGVuZ2UtYnV0LWxvbmctZW5vdWdoLXRvLXBhc3M=".utf8)

  // MARK: attestation

  @Test func acceptsAValidAttestation() async throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let object = try ca.attestation(for: device, challenge: challenge, appID: appID, environment: .production)
    let key = try await ca.verifier(appID: appID, environments: [.production])
      .verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: challenge)
    #expect(key == device.attestedKey)
  }

  @Test func developmentKeysOnlyWhereAllowed() async throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let object = try ca.attestation(for: device, challenge: challenge, appID: appID, environment: .development)
    await #expect(throws: AppAttestError.environmentNotAllowed) {
      try await ca.verifier(appID: appID, environments: [.production])
        .verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: challenge)
    }
    let key = try await ca.verifier(appID: appID, environments: [.production, .development])
      .verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: challenge)
    #expect(key.environment == .development)
  }

  static let tamperings: [(String, AppAttestError, @Sendable (inout FakeAppAttestCA.Tampering) -> Void)] = [
    ("another app", .appIDMismatch, { $0.appID = "ZZZZZ99999.com.example.other" }),
    ("used key", .counterNotZero, { $0.counter = 1 }),
    ("wrong nonce", .nonceMismatch, { $0.nonce = Array(repeating: 0, count: 32) }),
    ("another credential", .credentialIDMismatch, { $0.credentialID = Array(repeating: 9, count: 32) }),
    ("another format", .wrongFormat, { $0.format = "packed" }),
    ("not Apple's chain", .certificateChainInvalid, { $0.signedByStranger = true }),
  ]

  @Test(arguments: 0..<tamperings.count)
  func refusesATamperedAttestation(_ index: Int) async throws {
    let (label, expected, tamper) = Self.tamperings[index]
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    var tampering = FakeAppAttestCA.Tampering()
    tamper(&tampering)
    let object = try ca.attestation(
      for: device,
      challenge: challenge,
      appID: appID,
      environment: .production,
      tampering: tampering
    )
    await #expect(throws: expected, "\(label)") {
      try await ca.verifier(appID: appID, environments: [.production])
        .verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: challenge)
    }
  }

  /// The credential certificate lives three days: an attestation verified after that, or before it starts, fails.
  @Test(arguments: [4 * 86_400.0, -2 * 3_600.0])
  func refusesACertificateOutsideItsValidity(_ offset: TimeInterval) async throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let object = try ca.attestation(for: device, challenge: challenge, appID: appID, environment: .production)
    let later = ca.now.addingTimeInterval(offset)
    let verifier = try AppAttestVerifier(
      appID: appID,
      allowedEnvironments: [.production],
      rootCertificates: [ca.root],
      now: { later }
    )
    await #expect(throws: AppAttestError.certificateChainInvalid) {
      try await verifier.verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: challenge)
    }
  }

  @Test func refusesAnotherChallenge() async throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let object = try ca.attestation(for: device, challenge: challenge, appID: appID, environment: .production)
    await #expect(throws: AppAttestError.nonceMismatch) {
      try await ca.verifier(appID: appID, environments: [.production])
        .verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: Array("other".utf8))
    }
  }

  @Test func refusesAKeyIDThatIsNotTheCertificatesKey() async throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let other = FakeDevice()
    var tampering = FakeAppAttestCA.Tampering()
    tampering.credentialID = Array(other.keyID)
    let object = try ca.attestation(
      for: device,
      challenge: challenge,
      appID: appID,
      environment: .production,
      tampering: tampering
    )
    await #expect(throws: AppAttestError.keyIDMismatch) {
      try await ca.verifier(appID: appID, environments: [.production])
        .verifyAttestation(attestationObject: object, keyID: Array(other.keyID), challenge: challenge)
    }
  }

  @Test func refusesTheRealRootForAFakeChain() async throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let object = try ca.attestation(for: device, challenge: challenge, appID: appID, environment: .production)
    let now = ca.now
    let verifier = try AppAttestVerifier(
      appID: appID,
      allowedEnvironments: [.production],
      rootCertificates: [AppAttestVerifier.appleRootCertificate],
      now: { now }
    )
    await #expect(throws: AppAttestError.certificateChainInvalid) {
      try await verifier.verifyAttestation(attestationObject: object, keyID: Array(device.keyID), challenge: challenge)
    }
  }

  @Test func refusesGarbage() async throws {
    let ca = try FakeAppAttestCA()
    await #expect(throws: AppAttestError.malformed("attestation CBOR")) {
      try await ca.verifier(appID: appID, environments: [.production])
        .verifyAttestation(attestationObject: [0xff, 0x00], keyID: [], challenge: challenge)
    }
  }

  // MARK: assertion

  @Test func acceptsAnAssertionAndReturnsItsCounter() throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let hash = Array(SHA256.hash(data: Data("request".utf8)))
    let assertion = try device.assertion(clientDataHash: hash, counter: 5, appID: appID)
    let counter = try ca.verifier(appID: appID, environments: [.production])
      .verifyAssertion(assertion, clientDataHash: hash, key: device.attestedKey)
    #expect(counter == 5)
  }

  @Test func refusesAnAssertionForAnotherRequest() throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let assertion = try device.assertion(
      clientDataHash: Array(SHA256.hash(data: Data("GET".utf8))),
      counter: 1,
      appID: appID
    )
    #expect(throws: AppAttestError.badSignature) {
      try ca.verifier(appID: appID, environments: [.production])
        .verifyAssertion(
          assertion,
          clientDataHash: Array(SHA256.hash(data: Data("POST".utf8))),
          key: device.attestedKey
        )
    }
  }

  @Test func refusesAnotherKeysAssertion() throws {
    let ca = try FakeAppAttestCA()
    let hash = Array(SHA256.hash(data: Data("request".utf8)))
    let assertion = try FakeDevice().assertion(clientDataHash: hash, counter: 1, appID: appID)
    #expect(throws: AppAttestError.badSignature) {
      try ca.verifier(appID: appID, environments: [.production])
        .verifyAssertion(assertion, clientDataHash: hash, key: FakeDevice().attestedKey)
    }
  }

  @Test func refusesACounterThatDidNotIncrease() throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    var key = device.attestedKey
    key.counter = 5
    let hash = Array(SHA256.hash(data: Data("request".utf8)))
    let assertion = try device.assertion(clientDataHash: hash, counter: 5, appID: appID)
    #expect(throws: AppAttestError.counterNotIncreasing) {
      try ca.verifier(appID: appID, environments: [.production])
        .verifyAssertion(assertion, clientDataHash: hash, key: key)
    }
  }

  @Test func refusesAnotherAppsAssertion() throws {
    let ca = try FakeAppAttestCA()
    let device = FakeDevice()
    let hash = Array(SHA256.hash(data: Data("request".utf8)))
    let assertion = try device.assertion(clientDataHash: hash, counter: 1, appID: "ZZZZZ99999.com.example.other")
    #expect(throws: AppAttestError.appIDMismatch) {
      try ca.verifier(appID: appID, environments: [.production])
        .verifyAssertion(assertion, clientDataHash: hash, key: device.attestedKey)
    }
  }

  // MARK: Apple's root

  /// The pinned root is Apple's: a changed byte in `AppleRootCA.swift` fails here (DECISIONS D-4).
  @Test func appleRootIsPinned() throws {
    let root = try AppAttestVerifier.appleRootCertificate
    var serializer = DER.Serializer()
    try serializer.serialize(root)
    let fingerprint = SHA256.hash(data: serializer.serializedBytes).map { String(format: "%02X", $0) }.joined()
    #expect(fingerprint == "1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932")
    #expect(root.subject.description.contains("Apple App Attestation Root CA"))
  }

  // MARK: request signature

  @Test func requestSignatureIsTheDocumentedBytes() {
    let data = RequestSignature.clientData(
      method: "GET",
      pathWithQuery: "/v1/health",
      timestamp: "2026-10-31T12:00:00Z",
      body: [UInt8]()
    )
    #expect(
      String(decoding: data, as: UTF8.self)
        == "GET\n/v1/health\n2026-10-31T12:00:00Z\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
  }
}
