public import Crypto
public import Foundation

/// What an assertion signs, per the contract's `appAttestAssertion` scheme:
///
///     SHA-256(method + "\n" + path-with-query + "\n" + X-Tegola-Timestamp + "\n" + hex(SHA-256(body)))
///
/// - `method` is upper case (`GET`, `POST`).
/// - `path-with-query` is the request target exactly as sent on the wire, base path included
///   (`/v1/types/music/barcodes/0602547817327?symbology=ean13`). No re-encoding, no sorting.
/// - `hex(SHA-256(body))` is lower-case hex; an absent body hashes as empty
///   (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
///
/// The contract leaves the body hash's text form open; lower-case hex is this repo's reading (DECISIONS D-6), and the
/// app's `AppAttestMiddleware` must build the same bytes.
public enum RequestSignature {
  public static func clientData(method: String, pathWithQuery: String, timestamp: String, body: some DataProtocol)
    -> Data
  {
    let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    return Data("\(method)\n\(pathWithQuery)\n\(timestamp)\n\(bodyHash)".utf8)
  }

  public static func clientDataHash(method: String, pathWithQuery: String, timestamp: String, body: some DataProtocol)
    -> [UInt8]
  {
    Array(SHA256.hash(data: clientData(method: method, pathWithQuery: pathWithQuery, timestamp: timestamp, body: body)))
  }
}
