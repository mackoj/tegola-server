import AppAttest
import Crypto
import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime

/// The OpenAPI middleware every operation goes through (DECISIONS D-5, D-6, D-10). It knows the operation id, so the
/// list of public operations is explicit and anything else is secured: a new operation is secured until it's added
/// to `publicOperations`, never the other way round.
///
/// 1. Reads the body up to the cap (413 beyond), so the assertion can cover it and the decoder never sees more.
/// 2. Public operations pass.
/// 3. Development servers accept `X-Tegola-Debug-Token` when it matches (compared in constant time). Production never
///    gets here with one: `EdgeMiddleware` has already answered 403.
/// 4. Otherwise: key id, timestamp within the tolerance, assertion over the request, counter strictly increasing.
///    Every failure is the same 401, except an unknown key (401 `…/unknown-key`, so the app registers again) and a
///    revoked key (403).
/// 5. The per-key rate limit.
struct AppAttestMiddleware: ServerMiddleware {
  static let publicOperations: Set<String> = ["getAttestChallenge", "registerAttestKey", "health"]

  let configuration: ServerConfiguration
  let verifier: AppAttestVerifier
  let keys: any AttestKeyStore
  let perKey: RateLimiter
  let logger: Logger
  let now: @Sendable () -> Date

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    metadata: ServerRequestMetadata,
    operationID: String,
    next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let bytes: [UInt8]
    do {
      if let body {
        bytes = try await [UInt8](collecting: body, upTo: configuration.limits.maximumBodyBytes)
      } else {
        bytes = []
      }
    } catch {
      return ProblemEncoding.openAPIResponse(.payloadTooLarge)
    }
    let replayableBody: HTTPBody? = body == nil ? nil : HTTPBody(bytes)

    if Self.publicOperations.contains(operationID) {
      return try await next(request, replayableBody, metadata)
    }

    if let presented = request.headerFields[.tegolaDebugToken] {
      guard
        configuration.environment == .development,
        let expected = configuration.debugToken,
        Self.constantTimeEquals(Array(presented.utf8), Array(expected.utf8))
      else {
        logger.notice("auth failed", metadata: ["operation": "\(operationID)", "reason": "debugToken"])
        return ProblemEncoding.openAPIResponse(.unauthorized)
      }
      return try await next(request, replayableBody, metadata)
    }

    switch await authenticate(request, body: bytes) {
    case .success(let keyID):
      if case .limited(let retryAfter) = await perKey.take(keyID.base64EncodedString()) {
        return ProblemEncoding.openAPIResponse(.tooManyRequests, retryAfter: retryAfter)
      }
      return try await next(request, replayableBody, metadata)
    case .failure(let failure):
      logger.notice("auth failed", metadata: ["operation": "\(operationID)", "reason": "\(failure.reason)"])
      return ProblemEncoding.openAPIResponse(failure.problem)
    }
  }

  struct AuthFailure: Error {
    var problem: ProblemKind
    var reason: String
  }

  func authenticate(_ request: HTTPRequest, body: [UInt8]) async -> Result<Data, AuthFailure> {
    func fail(_ reason: String, _ problem: ProblemKind = .unauthorized) -> Result<Data, AuthFailure> {
      .failure(AuthFailure(problem: problem, reason: reason))
    }
    guard
      let keyIDHeader = request.headerFields[.tegolaKeyID],
      keyIDHeader.utf8.count <= 128,
      let keyID = Data(base64Encoded: keyIDHeader),
      keyID.count == 32
    else { return fail("keyID") }
    guard
      let assertionHeader = request.headerFields[.tegolaAssertion],
      assertionHeader.utf8.count <= 4096,
      let assertion = Data(base64Encoded: assertionHeader)
    else { return fail("assertionHeader") }
    guard
      let timestamp = request.headerFields[.tegolaTimestamp],
      timestamp.utf8.count <= 64,
      let date = Self.parseTimestamp(timestamp),
      abs(date.timeIntervalSince(now())) <= configuration.limits.timestampTolerance
    else { return fail("timestamp") }
    guard let path = request.path else { return fail("path") }

    guard let record = await keys.key(id: keyID) else { return fail("unknownKey", .unknownKey) }
    guard !record.revoked else { return fail("revoked", .forbidden) }
    guard configuration.allowedAttestEnvironments.contains(record.key.environment) else {
      return fail("environment", .forbidden)
    }

    let clientDataHash = RequestSignature.clientDataHash(
      method: request.method.rawValue,
      pathWithQuery: path,
      timestamp: timestamp,
      body: body
    )
    let counter: UInt32
    do {
      counter = try verifier.verifyAssertion(Array(assertion), clientDataHash: clientDataHash, key: record.key)
    } catch {
      return fail("\(error)")
    }
    guard await keys.advanceCounter(id: keyID, to: counter) else { return fail("replay") }
    return .success(keyID)
  }

  static func parseTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    // Compare digests, so neither the length nor the first differing byte shows in the timing.
    let left = SHA256.hash(data: lhs)
    let right = SHA256.hash(data: rhs)
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
