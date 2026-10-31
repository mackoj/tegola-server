import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import OpenAPIRuntime

/// The outermost middleware, in front of every route (DECISIONS D-7, D-9, D-10):
///
/// 1. In production, refuses any request that carries `X-Tegola-Debug-Token` (403), before anything else runs.
/// 2. Refuses a declared `Content-Length` above the body cap (413) without reading the body.
/// 3. Applies the per-IP rate limit (429 with `Retry-After`); registration calls get a stricter bucket of their own.
/// 4. Turns every thrown error into a problem document with no internal detail: a body that doesn't decode is 400,
///    an unknown route 404, anything unexpected 500.
/// 5. Adds the security headers to every response, and `Cache-Control: no-store` unless a handler chose otherwise.
/// 6. Writes one access-log line: method, route template, status, duration. Never the body, the query, the key id
///    or the client's address.
struct EdgeMiddleware<Context: RemoteAddressRequestContext>: RouterMiddleware {
  let configuration: ServerConfiguration
  let perIP: RateLimiter
  let registrationPerIP: RateLimiter

  func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response)
    async throws -> Response
  {
    let start = ContinuousClock.now
    var response = await respond(request, context: context, next: next)
    Self.addSecurityHeaders(&response)
    let duration = ContinuousClock.now - start
    let milliseconds = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    context.logger.info(
      "request",
      metadata: [
        "method": "\(request.method.rawValue)",
        "route": "\(context.endpointPath ?? "unmatched")",
        "status": "\(response.status.code)",
        "ms": "\(milliseconds)",
      ]
    )
    return response
  }

  private func respond(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async
    -> Response
  {
    if configuration.environment == .production, request.headers[.tegolaDebugToken] != nil {
      return ProblemEncoding.response(.debugTokenRefused)
    }
    if let declared = request.headers[.contentLength].flatMap(Int.init),
      declared > configuration.limits.maximumBodyBytes
    {
      return ProblemEncoding.response(.payloadTooLarge)
    }
    let client = clientAddress(request, context: context)
    let limiter = request.uri.path.hasPrefix("/v1/app-attest/") ? registrationPerIP : perIP
    if case .limited(let retryAfter) = await limiter.take(client) {
      return ProblemEncoding.response(.tooManyRequests, retryAfter: retryAfter)
    }
    do {
      return try await next(request, context)
    } catch {
      return Self.problem(for: error, logger: context.logger)
    }
  }

  /// The peer address, or with `trustedProxyHops` = n > 0 the n-th address from the right of `X-Forwarded-For`
  /// (the one the outermost trusted proxy saw). Addresses the client wrote to the left are never used.
  func clientAddress(_ request: Request, context: Context) -> String {
    if configuration.trustedProxyHops > 0, let header = request.headers[.forwardedFor] {
      let hops = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      if hops.count >= configuration.trustedProxyHops {
        return String(hops[hops.count - configuration.trustedProxyHops])
      }
    }
    return context.remoteAddress?.ipAddress ?? "unknown"
  }

  static func problem(for error: any Error, logger: Logger) -> Response {
    if let error = error as? any HTTPResponseError {
      switch error.status {
      case .notFound: return ProblemEncoding.response(.notFound)
      case .contentTooLarge: return ProblemEncoding.response(.payloadTooLarge)
      case .badRequest: return ProblemEncoding.response(.badRequest)
      case .unsupportedMediaType: return ProblemEncoding.response(.unsupportedMediaType)
      default: break
      }
    }
    if let error = error as? ServerError {
      if let unavailable = error.underlyingError as? ServiceUnavailable {
        return ProblemEncoding.response(.unavailable, retryAfter: max(1, unavailable.retryAfter))
      }
      if error.underlyingError is DecodingError { return ProblemEncoding.response(.badRequest) }
      switch error.httpStatus {
      case .badRequest: return ProblemEncoding.response(.badRequest)
      case .unsupportedMediaType, .notAcceptable: return ProblemEncoding.response(.unsupportedMediaType)
      case .notFound: return ProblemEncoding.response(.notFound)
      default: break
      }
      logger.error("unhandled server error", metadata: ["operation": "\(error.operationID)"])
    } else {
      logger.error("unhandled error", metadata: ["type": "\(String(reflecting: type(of: error)))"])
    }
    return ProblemEncoding.response(.internalError)
  }

  static func addSecurityHeaders(_ response: inout Response) {
    response.headers[.strictTransportSecurity] = "max-age=63072000; includeSubDomains"
    response.headers[.xContentTypeOptions] = "nosniff"
    response.headers[.contentSecurityPolicy] = "default-src 'none'; frame-ancestors 'none'"
    response.headers[.referrerPolicy] = "no-referrer"
    response.headers[.init("X-Frame-Options")!] = "DENY"
    response.headers[.init("Cross-Origin-Resource-Policy")!] = "same-origin"
    if response.headers[.cacheControl] == nil { response.headers[.cacheControl] = "no-store" }
  }
}

extension HTTPField.Name {
  static let referrerPolicy = Self("Referrer-Policy")!
}
