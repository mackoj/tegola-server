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
/// 1. Public operations read the body up to their cap (413 beyond) and pass.
/// 2. Development servers accept `X-Tegola-Debug-Token` when it matches (compared in constant time). Production never
///    gets here with one: `EdgeMiddleware` has already answered 403.
/// 3. Otherwise: key id, timestamp within the tolerance and a known, unrevoked key, all from the headers; only then
///    the body, read up to the operation's cap (413 beyond), so a caller without a key can't make the server read an
///    identify body's 3 MiB (D-24). Then the assertion over the request and a strictly increasing counter. Every
///    failure is the same 401, except an unknown key (401 `…/unknown-key`, so the app registers again) and a revoked
///    key (403).
/// 4. The per-key rate limit. Registration calls, being public, take the stricter per-client registration bucket
///    instead, chosen here by operation id rather than by path (D-19).
struct AppAttestMiddleware: ServerMiddleware {
  static let publicOperations: Set<String> = ["getAttestChallenge", "registerAttestKey", "health"]
  /// An install calls these once; a client that calls them often is filling the challenge store.
  static let registrationOperations: Set<String> = ["getAttestChallenge", "registerAttestKey"]

  let configuration: ServerConfiguration
  let verifier: AppAttestVerifier
  let keys: any AttestKeyStore
  let perKey: RateLimiter
  let registrationPerClient: RateLimiter
  let logger: Logger
  let now: @Sendable () -> Date

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    metadata: ServerRequestMetadata,
    operationID: String,
    next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let cap = configuration.limits.maximumBodyBytes(for: operationID)
    /// The body up to the cap, or nil beyond it; replayed to the decoder from memory, so it never sees more.
    func collect() async -> [UInt8]? {
      guard let body else { return [] }
      return try? await [UInt8](collecting: body, upTo: cap)
    }
    func replay(_ bytes: [UInt8]) -> HTTPBody? { body == nil ? nil : HTTPBody(bytes) }

    if Self.publicOperations.contains(operationID) {
      if Self.registrationOperations.contains(operationID),
        case .limited(let retryAfter) = await registrationPerClient.take(RequestScope.client ?? "unknown")
      {
        return ProblemEncoding.openAPIResponse(.tooManyRequests, retryAfter: retryAfter)
      }
      guard let bytes = await collect() else { return ProblemEncoding.openAPIResponse(.payloadTooLarge) }
      return try await next(request, replay(bytes), metadata)
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
      guard let bytes = await collect() else { return ProblemEncoding.openAPIResponse(.payloadTooLarge) }
      return try await next(request, replay(bytes), metadata)
    }

    var collected: [UInt8] = []
    let outcome = await authenticate(request) {
      guard let bytes = await collect() else { return nil }
      collected = bytes
      return bytes
    }
    switch outcome {
    case .success(let keyID):
      let key = keyID.base64EncodedString()
      if case .limited(let retryAfter) = await perKey.take(key) {
        return ProblemEncoding.openAPIResponse(.tooManyRequests, retryAfter: retryAfter)
      }
      return try await RequestScope.$keyID.withValue(key) { [collected] in
        try await next(request, replay(collected), metadata)
      }
    case .failure(let failure):
      if failure.problem == .payloadTooLarge { return ProblemEncoding.openAPIResponse(.payloadTooLarge) }
      logger.notice("auth failed", metadata: ["operation": "\(operationID)", "reason": "\(failure.reason)"])
      // A store that can't answer is the server's problem, not the caller's: 503, retry shortly.
      return ProblemEncoding.openAPIResponse(failure.problem, retryAfter: failure.problem == .unavailable ? 5 : nil)
    }
  }

  struct AuthFailure: Error {
    var problem: ProblemKind
    var reason: String
  }

  /// Checks the headers and the key first, then asks `body` for the body (nil when it's over the cap: 413).
  func authenticate(_ request: HTTPRequest, body: () async -> [UInt8]?) async -> Result<Data, AuthFailure> {
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

    let found: AttestKeyRecord?
    do { found = try await keys.key(id: keyID) } catch { return fail("storeUnavailable", .unavailable) }
    guard let record = found else { return fail("unknownKey", .unknownKey) }
    guard !record.revoked else { return fail("revoked", .forbidden) }
    guard configuration.allowedAttestEnvironments.contains(record.key.environment) else {
      return fail("environment", .forbidden)
    }

    guard let body = await body() else { return fail("bodyTooLarge", .payloadTooLarge) }
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
    let advanced: Bool
    do { advanced = try await keys.advanceCounter(id: keyID, to: counter) } catch {
      return fail("storeUnavailable", .unavailable)
    }
    guard advanced else { return fail("replay") }
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
