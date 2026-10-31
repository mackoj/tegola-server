import Foundation
import HTTPTypes
import Hummingbird
import OpenAPIRuntime

/// RFC 9457 problem details. Every error the server answers is one of these, with a fixed title per kind and no
/// internal detail (no stack, no underlying error text, no echo of the input), so an error says what to do without
/// saying how the server works (DECISIONS D-7).
struct ProblemDocument: Codable, Sendable, Equatable {
  var type: String
  var title: String
  var status: Int
  var detail: String?
}

enum ProblemKind: String, Sendable {
  case badRequest = "bad-request"
  case unauthorized = "unauthorized"
  case unknownKey = "unknown-key"
  case forbidden = "forbidden"
  case debugTokenRefused = "debug-token-refused"
  case attestationRejected = "attestation-rejected"
  case notFound = "not-found"
  case payloadTooLarge = "payload-too-large"
  case unsupportedMediaType = "unsupported-media-type"
  case tooManyRequests = "too-many-requests"
  case unavailable = "unavailable"
  case internalError = "internal-error"

  var status: HTTPResponse.Status {
    switch self {
    case .badRequest: .badRequest
    case .unauthorized, .unknownKey: .unauthorized
    case .forbidden, .debugTokenRefused, .attestationRejected: .forbidden
    case .notFound: .notFound
    case .payloadTooLarge: .contentTooLarge
    case .unsupportedMediaType: .unsupportedMediaType
    case .tooManyRequests: .tooManyRequests
    case .unavailable: .serviceUnavailable
    case .internalError: .internalServerError
    }
  }

  var title: String {
    switch self {
    case .badRequest: "The request doesn't match the contract."
    case .unauthorized: "The request isn't signed by a registered App Attest key."
    case .unknownKey: "This App Attest key isn't registered. Register it again."
    case .forbidden: "This key isn't allowed here."
    case .debugTokenRefused: "Debug tokens are refused by this server."
    case .attestationRejected: "The attestation didn't verify."
    case .notFound: "Not found."
    case .payloadTooLarge: "The request body is too large."
    case .unsupportedMediaType: "Unsupported content type."
    case .tooManyRequests: "Too many requests. Retry later."
    case .unavailable: "The service is unavailable. Retry later."
    case .internalError: "Something went wrong on the server."
    }
  }

  var typeURI: String { "/problems/\(rawValue)" }

  func document(detail: String? = nil) -> ProblemDocument {
    ProblemDocument(type: typeURI, title: title, status: Int(status.code), detail: detail)
  }

  /// The generated `Components.Schemas.Problem`, for handlers that return a declared error response.
  func schema(detail: String? = nil) -> Components.Schemas.Problem {
    .init(_type: typeURI, title: title, status: Int(status.code), detail: detail)
  }
}

extension HTTPField.Name {
  static let tegolaKeyID = Self("X-Tegola-Key-ID")!
  static let tegolaAssertion = Self("X-Tegola-Assertion")!
  static let tegolaTimestamp = Self("X-Tegola-Timestamp")!
  static let tegolaDebugToken = Self("X-Tegola-Debug-Token")!
  static let forwardedFor = Self("X-Forwarded-For")!
}

enum ProblemEncoding {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  static func bytes(_ kind: ProblemKind, detail: String? = nil) -> [UInt8] {
    (try? Array(encoder.encode(kind.document(detail: detail)))) ?? Array(#"{"status":500,"title":"error"}"#.utf8)
  }

  static func headers(_ kind: ProblemKind, retryAfter: Int?) -> HTTPFields {
    var fields = HTTPFields()
    fields[.contentType] = "application/problem+json"
    if let retryAfter { fields[.retryAfter] = String(retryAfter) }
    return fields
  }

  /// A Hummingbird response.
  static func response(_ kind: ProblemKind, detail: String? = nil, retryAfter: Int? = nil) -> Response {
    let body = bytes(kind, detail: detail)
    return Response(
      status: kind.status,
      headers: headers(kind, retryAfter: retryAfter),
      body: .init(byteBuffer: ByteBuffer(bytes: body))
    )
  }

  /// An OpenAPI-runtime response, for the OpenAPI middleware.
  static func openAPIResponse(_ kind: ProblemKind, detail: String? = nil, retryAfter: Int? = nil)
    -> (HTTPResponse, HTTPBody?)
  {
    (
      HTTPResponse(status: kind.status, headerFields: headers(kind, retryAfter: retryAfter)),
      HTTPBody(bytes(kind, detail: detail))
    )
  }
}
