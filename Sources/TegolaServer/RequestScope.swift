/// What the outer middlewares learned about a request, for the inner ones (D-19). `EdgeMiddleware` sets the client's
/// rate-limit key; `AppAttestMiddleware` sets the authenticated key id. Both live only for the request's task.
enum RequestScope {
  /// `RateLimitKey.client` of the caller, as the edge saw it.
  @TaskLocal static var client: String?
  /// The base64 App Attest key id that signed the request, once verified.
  @TaskLocal static var keyID: String?
}
