public import Crypto
public import Foundation
import SwiftASN1
public import X509

/// Which App Attest environment a key was made in. A production server accepts only `production` keys; a development
/// server accepts both (the contract, `POST /app-attest/keys`).
public enum AppAttestEnvironment: String, Sendable, CaseIterable {
  case production
  case development

  /// The AAGUID App Attest writes in the authenticator data: "appattestdevelop", or "appattest" and seven zero bytes.
  var aaguid: [UInt8] {
    switch self {
    case .development: Array("appattestdevelop".utf8)
    case .production: Array("appattest".utf8) + [UInt8](repeating: 0, count: 7)
    }
  }
}

/// What the server keeps about an install's key, and nothing else (the contract: "stores only the key id, its public
/// key and its counter").
public struct AttestedKey: Equatable, Sendable {
  public var keyID: Data
  public var publicKey: Data  // P-256, X9.63 uncompressed
  public var counter: UInt32
  public var environment: AppAttestEnvironment

  public init(keyID: Data, publicKey: Data, counter: UInt32, environment: AppAttestEnvironment) {
    self.keyID = keyID
    self.publicKey = publicKey
    self.counter = counter
    self.environment = environment
  }
}

/// Why a check failed. The server logs the case and tells the caller only that it failed (DECISIONS D-7), so a
/// probe learns nothing about which check it got past.
public enum AppAttestError: Error, Equatable, Sendable {
  case malformed(String)
  case wrongFormat
  case certificateChainInvalid
  case nonceMismatch
  case keyIDMismatch
  case appIDMismatch
  case counterNotZero
  case environmentNotAllowed
  case credentialIDMismatch
  case badSignature
  case counterNotIncreasing
}

/// Verifies App Attest attestations and assertions, following Apple's "Validating apps that connect to your server".
public struct AppAttestVerifier: Sendable {
  /// `<TeamID>.<bundle id>`, e.g. `ABCDE12345.fr.macko.tegola`.
  public let appID: String
  public let allowedEnvironments: Set<AppAttestEnvironment>
  let rootCertificates: [Certificate]
  let now: @Sendable () -> Date

  /// The verifier the server uses: Apple's App Attest root, the real clock.
  public init(appID: String, allowedEnvironments: Set<AppAttestEnvironment>) throws {
    try self.init(
      appID: appID,
      allowedEnvironments: allowedEnvironments,
      rootCertificates: [Certificate(pemEncoded: AppleRootCA.pem)],
      now: { Date() }
    )
  }

  /// For tests: another root (a fake CA) and clock.
  public init(
    appID: String,
    allowedEnvironments: Set<AppAttestEnvironment>,
    rootCertificates: [Certificate],
    now: @escaping @Sendable () -> Date
  ) throws {
    self.appID = appID
    self.allowedEnvironments = allowedEnvironments
    self.rootCertificates = rootCertificates
    self.now = now
  }

  public static var appleRootCertificate: Certificate {
    get throws { try Certificate(pemEncoded: AppleRootCA.pem) }
  }

  /// The OID of the credential certificate's extension that carries the nonce.
  static let nonceExtensionOID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 8, 2]

  // MARK: - Attestation

  /// Checks an attestation object for `keyID`, made with `SHA-256(challenge)` as client data, and returns the key to
  /// store. Steps follow Apple's list; each failure throws before anything is kept.
  public func verifyAttestation(
    attestationObject: [UInt8],
    keyID: [UInt8],
    challenge: [UInt8]
  ) async throws(AppAttestError) -> AttestedKey {
    let object: CBOR
    do { object = try CBORReader.decode(attestationObject) } catch { throw .malformed("attestation CBOR") }
    guard object["fmt"]?.textValue == "apple-appattest" else { throw .wrongFormat }
    guard
      let statement = object["attStmt"],
      let chain = statement["x5c"]?.arrayValue?.compactMap(\.bytesValue),
      chain.count >= 2,
      let authDataBytes = object["authData"]?.bytesValue
    else { throw .malformed("attestation fields") }

    // 1. The certificate chain ends at the root.
    let leaf: Certificate
    let intermediates: [Certificate]
    do {
      leaf = try Certificate(derEncoded: chain[0])
      intermediates = try chain.dropFirst().map { try Certificate(derEncoded: $0) }
    } catch { throw .malformed("certificate") }
    let validationTime = now()
    var verifier = Verifier(rootCertificates: CertificateStore(rootCertificates)) {
      RFC5280Policy(validationTime: validationTime)
    }
    let result = await verifier.validate(leafCertificate: leaf, intermediates: CertificateStore(intermediates))
    guard case .validCertificate = result else { throw .certificateChainInvalid }

    // 2–4. nonce = SHA-256(authData ‖ SHA-256(challenge)) is the credential certificate's extension.
    let clientDataHash = Array(SHA256.hash(data: challenge))
    let nonce = Array(SHA256.hash(data: authDataBytes + clientDataHash))
    guard try Self.nonce(in: leaf) == nonce else { throw .nonceMismatch }

    // 5. The key id is SHA-256 of the credential's public key.
    guard let publicKey = try? P256.Signing.PublicKey(leaf.publicKey) else { throw .malformed("public key") }
    let publicKeyBytes = Array(publicKey.x963Representation)
    guard Array(SHA256.hash(data: publicKeyBytes)) == keyID else { throw .keyIDMismatch }

    let authData: AuthenticatorData
    do { authData = try AuthenticatorData(authDataBytes, requireAttestedCredential: true) } catch {
      throw .malformed("authenticator data")
    }
    // 6. The relying party is this app.
    guard authData.relyingPartyIDHash == Array(SHA256.hash(data: Data(appID.utf8))) else { throw .appIDMismatch }
    // 7. A new key has signed nothing yet.
    guard authData.counter == 0 else { throw .counterNotZero }
    // 8. The environment is one this server accepts.
    guard let environment = allowedEnvironments.first(where: { $0.aaguid == authData.aaguid }) else {
      throw .environmentNotAllowed
    }
    // 9. The credential is the key being registered.
    guard authData.credentialID == keyID else { throw .credentialIDMismatch }

    return AttestedKey(
      keyID: Data(keyID),
      publicKey: Data(publicKeyBytes),
      counter: 0,
      environment: environment
    )
  }

  /// The nonce in the credential certificate: `SEQUENCE { [1] EXPLICIT OCTET STRING }`.
  static func nonce(in certificate: Certificate) throws(AppAttestError) -> [UInt8] {
    guard let ext = certificate.extensions[oid: nonceExtensionOID] else { throw .nonceMismatch }
    do {
      let node = try DER.parse(Array(ext.value))
      return try DER.sequence(node, identifier: .sequence) { nodes in
        try DER.explicitlyTagged(&nodes, tagNumber: 1, tagClass: .contextSpecific) { inner in
          Array(try ASN1OctetString(derEncoded: inner).bytes)
        }
      }
    } catch {
      throw .malformed("nonce extension")
    }
  }

  // MARK: - Assertion

  /// Checks an assertion made by `key` over `clientDataHash`, and returns the counter it carries. The caller stores
  /// it only if it is still greater than the stored one at that moment (`AttestKeyStore.advanceCounter`), so two
  /// concurrent replays can't both pass.
  public func verifyAssertion(
    _ assertion: [UInt8],
    clientDataHash: [UInt8],
    key: AttestedKey
  ) throws(AppAttestError) -> UInt32 {
    let object: CBOR
    do { object = try CBORReader.decode(assertion) } catch { throw .malformed("assertion CBOR") }
    guard
      let signatureBytes = object["signature"]?.bytesValue,
      let authDataBytes = object["authenticatorData"]?.bytesValue
    else { throw .malformed("assertion fields") }

    let nonce = Array(SHA256.hash(data: authDataBytes + clientDataHash))
    guard
      let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey),
      let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureBytes),
      publicKey.isValidSignature(signature, for: nonce)
    else { throw .badSignature }

    let authData: AuthenticatorData
    do { authData = try AuthenticatorData(authDataBytes, requireAttestedCredential: false) } catch {
      throw .malformed("authenticator data")
    }
    guard authData.relyingPartyIDHash == Array(SHA256.hash(data: Data(appID.utf8))) else { throw .appIDMismatch }
    guard authData.counter > key.counter else { throw .counterNotIncreasing }
    return authData.counter
  }
}
