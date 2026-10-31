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
  let challenges: ChallengeStore
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

  func searchObjects(_ input: Operations.SearchObjects.Input) async throws -> Operations.SearchObjects.Output {
    guard case .json(let request) = input.body else { throw ServerInputError.unsupportedBody }
    do {
      try Validation.typeID(input.path.typeID)
      try Validation.search(request)
    } catch {
      return .badRequest(.init(body: .applicationProblemJson(ProblemKind.badRequest.schema(detail: error.field))))
    }
    do {
      let candidates = try await lookups.search(typeID: input.path.typeID, request)
      return .ok(.init(body: .json(.init(candidates: Self.best(candidates, limit: request.limit ?? 5)))))
    } catch let unavailable as SourceUnavailable {
      return .serviceUnavailable(Self.unavailable(unavailable))
    }
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
    do {
      var results: [Components.Schemas.MatchResult.ResultsPayloadPayload] = []
      for item in request.items {
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
      let (response, body) = ProblemEncoding.openAPIResponse(.unavailable, retryAfter: unavailable.retryAfter)
      return .undocumented(statusCode: 503, .init(headerFields: response.headerFields, body: body))
    }
  }

  // MARK: - security

  func getAttestChallenge(_ input: Operations.GetAttestChallenge.Input) async throws
    -> Operations.GetAttestChallenge.Output
  {
    guard let issued = await challenges.issue() else {
      logger.warning("challenge store full")
      let (response, body) = ProblemEncoding.openAPIResponse(.unavailable, retryAfter: 60)
      return .undocumented(statusCode: 503, .init(headerFields: response.headerFields, body: body))
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
    let challengeValid = await challenges.consume(request.challenge)
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
    do {
      let key = try await verifier.verifyAttestation(
        attestationObject: Array(attestation),
        keyID: Array(keyID),
        challenge: Array(request.challenge.utf8)
      )
      if let existing = await keys.key(id: key.keyID), existing.revoked {
        logger.notice("attestation rejected", metadata: ["reason": "revoked"])
        return Self.attestationRejected
      }
      await keys.register(key)
      logger.info("key registered", metadata: ["environment": "\(key.environment.rawValue)"])
      return .created(.init())
    } catch {
      logger.notice("attestation rejected", metadata: ["reason": "\(error)"])
      return Self.attestationRejected
    }
  }

  // MARK: - service

  func health(_ input: Operations.Health.Input) async throws -> Operations.Health.Output {
    .ok(.init(body: .json(.init(status: .ok, types: lookups.supportedTypes.sorted()))))
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

enum ServerInputError: Error, HTTPResponseConvertible {
  case unsupportedBody

  var httpStatus: HTTPResponse.Status { .unsupportedMediaType }
}
