import HTTPTypes
import OpenAPIRuntime

/// Sets `Cache-Control` per operation. The generated server percent-encodes a string header it writes
/// (`public%2C%20max-age%3D604800`), which no cache understands, so the handlers leave the contract's `Cache-Control`
/// header unset and this writes it as raw text (DECISIONS D-14). `EdgeMiddleware` adds `no-store` to everything else.
struct CachePolicyMiddleware: ServerMiddleware {
  /// Operations whose successful answer is the same for everyone (the contract's `lookupBarcode`).
  static let publicOperations: [String: String] = ["lookupBarcode": "public, max-age=604800"]

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    metadata: ServerRequestMetadata,
    operationID: String,
    next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var (response, responseBody) = try await next(request, body, metadata)
    if response.status == .ok, let policy = Self.publicOperations[operationID] {
      response.headerFields[.cacheControl] = policy
    } else {
      response.headerFields[.cacheControl] = "no-store"
    }
    return (response, responseBody)
  }
}
