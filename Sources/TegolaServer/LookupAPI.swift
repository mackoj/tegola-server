import AppAttest
import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime

/// The contract's operations. Authentication has already happened (`AppAttestMiddleware`) by the time a secured
/// handler runs; each handler validates its input, asks the `LookupService`, and maps the answer to the contract's
/// responses. Logs carry the operation and outcome only, never what was looked up (PLAN §2.7).
struct LookupAPI: APIProtocol {
  let configuration: ServerConfiguration
  let lookups: any LookupService
  let verifier: AppAttestVerifier
  let keys: any AttestKeyStore
  let challenges: any ChallengeStore
  let storeHealth: @Sendable () async -> Bool
  let perKey: RateLimiter
  let logger: Logger

  // MARK: - lookup

  func lookupBarcode(_ input: Operations.LookupBarcode.Input) async throws -> Operations.LookupBarcode.Output {
    do {
      try Validation.typeID(input.path.typeID)
      try Validation.barcode(input.path.code)
      try Validation.subtype(input.query.subtype)
      try Validation.region(input.query.region)
    } catch {
      return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: error.field))))
    }
    let query = BarcodeQuery(
      typeID: input.path.typeID,
      code: input.path.code,
      symbology: input.query.symbology,
      subtype: input.query.subtype,
      region: input.query.region
    )
    do {
      let candidates = try await lookups.barcode(query)
      // Cache-Control is set by CachePolicyMiddleware (DECISIONS D-14).
      return .ok(.init(body: .json(.init(candidates: Self.best(candidates, limit: 10)))))
    } catch let unavailable as SourceUnavailable {
      return .serviceUnavailable(Self.unavailable(unavailable))
    }
  }

  /// Words, a barcode and a photo, in any combination (D-24). The photo is read up to its cap, checked to be a JPEG,
  /// and dropped: no source matches images yet, so it goes nowhere, and it's never logged, cached or stored.
  func identifyObject(_ input: Operations.IdentifyObject.Input) async throws -> Operations.IdentifyObject.Output {
    let hints: Components.Schemas.IdentifyHints
    switch input.body {
    case .json(let body):
      do {
        try Validation.typeID(input.path.typeID)
        try Validation.identify(body, requireQuery: true)
      } catch {
        return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: error.field))))
      }
      hints = body
    case .multipartForm(let parts):
      var photo: [UInt8]?
      var found: Components.Schemas.IdentifyHints?
      do {
        for try await part in parts {
          switch part {
          case .image(let image):
            guard photo == nil else { return Self.badIdentify("image") }
            do {
              photo = try await [UInt8](collecting: image.payload.body, upTo: configuration.limits.maximumImageBytes)
            } catch {
              return .contentTooLarge(
                .init(body: .applicationProblemJson(ProblemKind.payloadTooLarge.schema(detail: "image")))
              )
            }
          case .hints(let part):
            guard found == nil else { return Self.badIdentify("hints") }
            found = part.payload.body
          }
        }
      } catch {
        // A part with another type than the contract's, a repeated or a malformed part: the runtime refuses it.
        return Self.badIdentify(nil)
      }
      if let photo, !Validation.isJPEG(photo) {
        return .unsupportedMediaType(
          .init(body: .applicationProblemJson(ProblemKind.unsupportedMediaType.schema(detail: "image")))
        )
      }
      do {
        try Validation.typeID(input.path.typeID)
        try Validation.identify(found ?? .init(), requireQuery: photo == nil)
      } catch {
        return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: error.field))))
      }
      hints = found ?? .init()
    }
    // A photo alone, or beside hints that hold nothing to look up: no source reads images yet, so no match.
    guard Validation.hasQuery(hints) else { return .ok(.init(body: .json(.init(candidates: [])))) }
    do {
      let candidates = try await lookups.identify(typeID: input.path.typeID, hints)
      return .ok(.init(body: .json(.init(candidates: Self.best(candidates, limit: hints.limit ?? 5)))))
    } catch let unavailable as SourceUnavailable {
      return .serviceUnavailable(Self.unavailable(unavailable))
    }
  }

  private static func badIdentify(_ detail: String?) -> Operations.IdentifyObject.Output {
    .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: detail))))
  }

  // MARK: - match

  func matchBatch(_ input: Operations.MatchBatch.Input) async throws -> Operations.MatchBatch.Output {
    guard case .json(let request) = input.body else { throw ServerInputError.unsupportedBody }
    guard request.items.count <= Validation.maximumMatchItems else {
      return .contentTooLarge(.init(body: .applicationProblemJson(ProblemKind.payloadTooLarge.schema(detail: "items"))))
    }
    do {
      try Validation.typeID(input.path.typeID)
      try Validation.match(request)
    } catch {
      return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: error.field))))
    }
    // Each row is a lookup against a source's quota: the call paid one token in the middleware, the other rows pay
    // here (D-19). A debug-token call has no key and no per-key bucket.
    if let key = RequestScope.keyID, request.items.count > 1,
      case .limited(let retryAfter) = await perKey.take(key, cost: Double(request.items.count - 1))
    {
      return .tooManyRequests(
        .init(
          headers: .init(retryAfter: retryAfter),
          body: .applicationProblemJson(ProblemKind.tooManyRequests.schema())
        )
      )
    }
    do {
      var results: [Components.Schemas.MatchResult.ResultsPayloadPayload] = []
      // A batch stops after 20 s: rows run one after another, each against a supplier's shared pace, so a long one
      // would hold the request open and spend everyone's pace. The rows it reached are cached, so the app's retry
      // after `Retry-After` goes further (D-22).
      let deadline = ContinuousClock.now + .seconds(20)
      for item in request.items {
        guard ContinuousClock.now < deadline else { throw SourceUnavailable(retryAfter: 5) }
        let candidates = try await lookups.match(typeID: input.path.typeID, item)
        let (bucket, kept) = Self.bucket(candidates)
        results.append(.init(ref: item.ref, bucket: bucket, candidates: kept))
      }
      return .ok(.init(body: .json(.init(results: results))))
    } catch let unavailable as SourceUnavailable {
      return .serviceUnavailable(Self.unavailable(unavailable))
    }
  }

  // MARK: - works

  func getWork(_ input: Operations.GetWork.Input) async throws -> Operations.GetWork.Output {
    do {
      try Validation.workID(input.path.workID)
    } catch {
      // The contract declares no 400 here; an id that can't exist is a work that doesn't.
      return .notFound(.init(body: .applicationProblemJson(ProblemKind.notFound.schema())))
    }
    do {
      guard let work = try await lookups.work(id: input.path.workID) else {
        return .notFound(.init(body: .applicationProblemJson(ProblemKind.notFound.schema())))
      }
      return .ok(.init(body: .json(work)))
    } catch let unavailable as SourceUnavailable {
      throw ServiceUnavailable(retryAfter: unavailable.retryAfter)
    }
  }

  // MARK: - security

  func getAttestChallenge(_ input: Operations.GetAttestChallenge.Input) async throws
    -> Operations.GetAttestChallenge.Output
  {
    let issued: (challenge: String, expiresAt: Date)?
    do { issued = try await challenges.issue() } catch {
      logger.error("store unavailable", metadata: ["operation": "getAttestChallenge"])
      throw ServiceUnavailable(retryAfter: 5)
    }
    guard let issued else {
      logger.warning("challenge store full")
      throw ServiceUnavailable(retryAfter: 60)
    }
    return .ok(.init(body: .json(.init(challenge: issued.challenge, expiresAt: issued.expiresAt))))
  }

  func registerAttestKey(_ input: Operations.RegisterAttestKey.Input) async throws
    -> Operations.RegisterAttestKey.Output
  {
    guard case .json(let request) = input.body else { throw ServerInputError.unsupportedBody }
    do {
      try Validation.registration(request)
    } catch {
      return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: error.field))))
    }
    // The challenge is spent whatever happens next, so a failed attempt can't be retried with it.
    let challengeValid: Bool
    do { challengeValid = try await challenges.consume(request.challenge) } catch {
      logger.error("store unavailable", metadata: ["operation": "registerAttestKey"])
      throw ServiceUnavailable(retryAfter: 5)
    }
    guard
      let keyID = Data(base64Encoded: request.keyID),
      let attestation = Data(base64Encoded: request.attestation)
    else {
      return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: "base64"))))
    }
    guard challengeValid else {
      logger.notice("attestation rejected", metadata: ["reason": "challenge"])
      return Self.attestationRejected
    }
    let key: AttestedKey
    do {
      key = try await verifier.verifyAttestation(
        attestationObject: Array(attestation),
        keyID: Array(keyID),
        challenge: Array(request.challenge.utf8)
      )
    } catch {
      logger.notice("attestation rejected", metadata: ["reason": "\(error)"])
      return Self.attestationRejected
    }
    do {
      if let existing = try await keys.key(id: key.keyID), existing.revoked {
        logger.notice("attestation rejected", metadata: ["reason": "revoked"])
        return Self.attestationRejected
      }
      try await keys.register(key)
    } catch {
      logger.error("store unavailable", metadata: ["operation": "registerAttestKey"])
      throw ServiceUnavailable(retryAfter: 5)
    }
    logger.info("key registered", metadata: ["environment": "\(key.environment.rawValue)"])
    return .created(.init())
  }

  // MARK: - service

  /// `degraded` when the key store doesn't answer: lookups would fail authentication with 503 until it does.
  func health(_ input: Operations.Health.Input) async throws -> Operations.Health.Output {
    let status: Operations.Health.Output.Ok.Body.JsonPayload.StatusPayload = await storeHealth() ? .ok : .degraded
    return .ok(.init(body: .json(.init(status: status, types: lookups.supportedTypes.sorted()))))
  }

  // MARK: - helpers

  static let attestationRejected = Operations.RegisterAttestKey.Output.forbidden(
    .init(body: .applicationProblemJson(ProblemKind.attestationRejected.schema()))
  )

  static func unavailable(_ error: SourceUnavailable) -> Components.Responses.Unavailable {
    .init(
      headers: .init(retryAfter: max(1, error.retryAfter)),
      body: .applicationProblemJson(ProblemKind.unavailable.schema())
    )
  }

  /// Best first, at most `limit`, confidence kept within 0…1 whatever a source says.
  static func best(_ candidates: [Components.Schemas.Candidate], limit: Int) -> [Components.Schemas.Candidate] {
    candidates
      .map { candidate in
        var candidate = candidate
        candidate.confidence = min(1, max(0, candidate.confidence.isFinite ? candidate.confidence : 0))
        return candidate
      }
      .sorted { $0.confidence > $1.confidence }
      .prefix(max(0, limit))
      .map(\.self)
  }

  /// The import's buckets (DECISIONS D-13): none is `unknown`; one candidate, or a best one at least 0.8 and 0.25
  /// ahead of the next, is `matched` with that one; otherwise `ambiguous` with the best two or three.
  static func bucket(_ candidates: [Components.Schemas.Candidate])
    -> (Components.Schemas.MatchResult.ResultsPayloadPayload.BucketPayload, [Components.Schemas.Candidate])
  {
    let ranked = best(candidates, limit: 3)
    guard let first = ranked.first else { return (.unknown, []) }
    if ranked.count == 1 || (first.confidence >= 0.8 && first.confidence - ranked[1].confidence >= 0.25) {
      return (.matched, [first])
    }
    return (.ambiguous, ranked)
  }
}

/// A 503 for an operation whose contract declares none. Handlers throw it, and `EdgeMiddleware` answers with the
/// problem document and `Retry-After`: the generated server drops the headers and body of an `undocumented` response
/// (it writes only the status), so a handler can't return one (D-18).
struct ServiceUnavailable: Error {
  var retryAfter: Int
}

enum ServerInputError: Error, HTTPResponseConvertible {
  case unsupportedBody

  var httpStatus: HTTPResponse.Status { .unsupportedMediaType }
}
