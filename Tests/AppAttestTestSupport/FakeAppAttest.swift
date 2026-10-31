public import AppAttest
public import Crypto
public import Foundation
import SwiftASN1
public import X509

/// A fake App Attest authority and device, so tests run the real verification code end to end: a root CA and an
/// intermediate standing in for Apple's, and a device key that attests itself under them and signs assertions.
/// Each case builds one valid object, then breaks exactly one thing.
public struct FakeAppAttestCA: Sendable {
  public let root: Certificate
  let rootKey: P256.Signing.PrivateKey
  public let intermediate: Certificate
  let intermediateKey: P256.Signing.PrivateKey
  public let now: Date

  public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws {
    self.now = now
    rootKey = P256.Signing.PrivateKey()
    intermediateKey = P256.Signing.PrivateKey()
    let rootName = try DistinguishedName { CommonName("Fake App Attestation Root CA") }
    let intermediateName = try DistinguishedName { CommonName("Fake App Attestation CA 1") }
    root = try Certificate(
      version: .v3,
      serialNumber: .init(),
      publicKey: .init(rootKey.publicKey),
      notValidBefore: now.addingTimeInterval(-86_400),
      notValidAfter: now.addingTimeInterval(86_400 * 365),
      issuer: rootName,
      subject: rootName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
        Critical(KeyUsage(keyCertSign: true))
      },
      issuerPrivateKey: .init(rootKey)
    )
    intermediate = try Certificate(
      version: .v3,
      serialNumber: .init(),
      publicKey: .init(intermediateKey.publicKey),
      notValidBefore: now.addingTimeInterval(-86_400),
      notValidAfter: now.addingTimeInterval(86_400 * 365),
      issuer: rootName,
      subject: intermediateName,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions {
        Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
        Critical(KeyUsage(keyCertSign: true))
      },
      issuerPrivateKey: .init(rootKey)
    )
  }

  public func verifier(appID: String, environments: Set<AppAttestEnvironment>) throws -> AppAttestVerifier {
    let now = self.now
    return try AppAttestVerifier(
      appID: appID,
      allowedEnvironments: environments,
      rootCertificates: [root],
      now: { now }
    )
  }

  /// What can be broken in an attestation.
  public struct Tampering: Sendable {
    public var appID: String?
    public var environment: AppAttestEnvironment?
    public var counter: UInt32 = 0
    public var nonce: [UInt8]?
    public var credentialID: [UInt8]?
    public var format = "apple-appattest"
    public var signedByStranger = false

    public init() {}
  }

  /// An attestation object for `device`'s key, over `SHA-256(challenge)`.
  public func attestation(
    for device: FakeDevice,
    challenge: [UInt8],
    appID: String,
    environment: AppAttestEnvironment,
    tampering: Tampering = .init()
  ) throws -> [UInt8] {
    let authData = FakeDevice.authenticatorData(
      appID: tampering.appID ?? appID,
      counter: tampering.counter,
      aaguid: (tampering.environment ?? environment).fakeAAGUID,
      credentialID: tampering.credentialID ?? Array(device.keyID)
    )
    let nonce = tampering.nonce ?? Array(SHA256.hash(data: authData + Array(SHA256.hash(data: challenge))))

    var serializer = DER.Serializer()
    try serializer.appendConstructedNode(identifier: .sequence) { sequence in
      try sequence.appendConstructedNode(identifier: ASN1Identifier(tagWithNumber: 1, tagClass: .contextSpecific)) {
        try $0.serialize(ASN1OctetString(contentBytes: ArraySlice(nonce)))
      }
    }
    let nonceExtension = Certificate.Extension(
      oid: [1, 2, 840, 113635, 100, 8, 2],
      critical: false,
      value: ArraySlice(serializer.serializedBytes)
    )
    let issuerKey = tampering.signedByStranger ? P256.Signing.PrivateKey() : intermediateKey
    let leaf = try Certificate(
      version: .v3,
      serialNumber: .init(),
      publicKey: .init(device.privateKey.publicKey),
      notValidBefore: now.addingTimeInterval(-3600),
      notValidAfter: now.addingTimeInterval(86_400 * 3),
      issuer: intermediate.subject,
      subject: try DistinguishedName { CommonName(device.keyID.map { String(format: "%02x", $0) }.joined()) },
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: try Certificate.Extensions { nonceExtension },
      issuerPrivateKey: .init(issuerKey)
    )

    return CBOREncoder.encode(
      .map([
        "fmt": .text(tampering.format),
        "attStmt": .map([
          "x5c": .array([.bytes(try leaf.derBytes), .bytes(try intermediate.derBytes)]),
          "receipt": .bytes(Array("receipt".utf8)),
        ]),
        "authData": .bytes(authData),
      ])
    )
  }
}

/// An install's App Attest key.
public struct FakeDevice: Sendable {
  public let privateKey: P256.Signing.PrivateKey
  public var keyID: Data { Data(SHA256.hash(data: privateKey.publicKey.x963Representation)) }

  public init() {
    privateKey = P256.Signing.PrivateKey()
  }

  public var attestedKey: AttestedKey {
    AttestedKey(
      keyID: keyID,
      publicKey: privateKey.publicKey.x963Representation,
      counter: 0,
      environment: .production
    )
  }

  /// An assertion over `clientDataHash` with `counter`, as `generateAssertion` makes it.
  public func assertion(clientDataHash: [UInt8], counter: UInt32, appID: String) throws -> [UInt8] {
    let authData = Self.authenticatorData(appID: appID, counter: counter, aaguid: nil, credentialID: nil)
    let nonce = Array(SHA256.hash(data: authData + clientDataHash))
    let signature = try privateKey.signature(for: nonce)
    return CBOREncoder.encode(
      .map(["signature": .bytes(Array(signature.derRepresentation)), "authenticatorData": .bytes(authData)])
    )
  }

  static func authenticatorData(appID: String, counter: UInt32, aaguid: [UInt8]?, credentialID: [UInt8]?)
    -> [UInt8]
  {
    var bytes = Array(SHA256.hash(data: Data(appID.utf8)))
    bytes.append(aaguid == nil ? 0x01 : 0x41)
    bytes += withUnsafeBytes(of: counter.bigEndian, Array.init)
    if let aaguid, let credentialID {
      bytes += aaguid
      bytes += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)]
      bytes += credentialID
      bytes += [0xa1, 0x01, 0x02]  // a token COSE key; the verifier doesn't read it
    }
    return bytes
  }
}

extension AppAttestEnvironment {
  var fakeAAGUID: [UInt8] {
    switch self {
    case .development: Array("appattestdevelop".utf8)
    case .production: Array("appattest".utf8) + [UInt8](repeating: 0, count: 7)
    }
  }
}

extension Certificate {
  var derBytes: [UInt8] {
    get throws {
      var serializer = DER.Serializer()
      try serializer.serialize(self)
      return serializer.serializedBytes
    }
  }
}

/// The CBOR encoder the fakes need (definite lengths, text keys sorted by length then bytes).
public enum CBOREncoder {
  public static func encode(_ value: CBOR) -> [UInt8] {
    var out: [UInt8] = []
    write(value, into: &out)
    return out
  }

  static func head(_ major: UInt8, _ argument: UInt64, into out: inout [UInt8]) {
    let m = major << 5
    switch argument {
    case 0..<24: out.append(m | UInt8(argument))
    case 24...0xff: out += [m | 24, UInt8(argument)]
    case 0x100...0xffff: out += [m | 25] + withUnsafeBytes(of: UInt16(argument).bigEndian, Array.init)
    case 0x10000...0xffff_ffff: out += [m | 26] + withUnsafeBytes(of: UInt32(argument).bigEndian, Array.init)
    default: out += [m | 27] + withUnsafeBytes(of: argument.bigEndian, Array.init)
    }
  }

  static func write(_ value: CBOR, into out: inout [UInt8]) {
    switch value {
    case .unsigned(let n): head(0, n, into: &out)
    case .negative(let n): head(1, n, into: &out)
    case .bytes(let b):
      head(2, UInt64(b.count), into: &out)
      out += b
    case .text(let t):
      head(3, UInt64(t.utf8.count), into: &out)
      out += Array(t.utf8)
    case .array(let items):
      head(4, UInt64(items.count), into: &out)
      for item in items { write(item, into: &out) }
    case .map(let entries):
      head(5, UInt64(entries.count), into: &out)
      for key in entries.keys.sorted(by: { ($0.utf8.count, $0) < ($1.utf8.count, $1) }) {
        write(.text(key), into: &out)
        write(entries[key]!, into: &out)
      }
    }
  }
}
