// The WebAuthn authenticator data inside an App Attest attestation or assertion.
//
//   rpIdHash (32) | flags (1) | signCount (4, big-endian) | [aaguid (16) | credentialIdLength (2) | credentialId | …]
//
// The attested-credential part is present only in an attestation (flag 0x40). The COSE key after the credential id
// isn't read: the public key comes from the certificate the chain check verified.

public struct AuthenticatorData: Equatable, Sendable {
  public var relyingPartyIDHash: [UInt8]
  public var flags: UInt8
  public var counter: UInt32
  public var aaguid: [UInt8]?
  public var credentialID: [UInt8]?

  public enum ParseError: Error, Equatable, Sendable {
    case truncated
    case missingAttestedCredential
  }

  static let attestedCredentialFlag: UInt8 = 0x40

  public init(_ bytes: [UInt8], requireAttestedCredential: Bool) throws(ParseError) {
    guard bytes.count >= 37 else { throw .truncated }
    relyingPartyIDHash = Array(bytes[0..<32])
    flags = bytes[32]
    counter = bytes[33..<37].reduce(0) { $0 << 8 | UInt32($1) }
    guard flags & Self.attestedCredentialFlag != 0 else {
      if requireAttestedCredential { throw .missingAttestedCredential }
      return
    }
    guard bytes.count >= 55 else { throw .truncated }
    aaguid = Array(bytes[37..<53])
    let length = Int(bytes[53]) << 8 | Int(bytes[54])
    guard bytes.count >= 55 + length else { throw .truncated }
    credentialID = Array(bytes[55..<(55 + length)])
  }
}
