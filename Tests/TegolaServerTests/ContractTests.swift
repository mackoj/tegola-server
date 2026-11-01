import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import TegolaServer

/// The contract's validation rules, on a development server with the debug token so each test is about one rule.
@Suite("Contract")
struct ContractTests {
  static var debugHeaders: HTTPFields {
    var headers = json(ip("1.1.1.1"))
    headers[.tegolaDebugToken] = debugToken
    return headers
  }

  func post(_ uri: String, _ body: String, lookups: (any LookupService)? = nil) async throws -> (
    HTTPResponse.Status, String
  ) {
    let server = try TestServer(environment: .development, lookups: lookups)
    nonisolated(unsafe) var result: (HTTPResponse.Status, String) = (.ok, "")
    try await server.run { client in
      try await client.execute(
        uri: uri,
        method: .post,
        headers: Self.debugHeaders,
        body: ByteBuffer(string: body)
      ) { response in
        result = (response.status, String(buffer: response.body))
      }
    }
    return result
  }

  func get(_ uri: String, lookups: (any LookupService)? = nil) async throws -> (HTTPResponse.Status, String) {
    let server = try TestServer(environment: .development, lookups: lookups)
    nonisolated(unsafe) var result: (HTTPResponse.Status, String) = (.ok, "")
    try await server.run { client in
      try await client.execute(uri: uri, method: .get, headers: Self.debugHeaders) { response in
        result = (response.status, String(buffer: response.body))
      }
    }
    return result
  }

  @Test(arguments: [
    #"{}"#,
    #"{"title":"   "}"#,
    #"{"title":"x","limit":11}"#,
    #"{"title":"x","year":1700}"#,
    #"{"title":"x","subtype":"SNES"}"#,
    #"{"title":"x","region":"PAL-PAL-PAL-PAL-PAL"}"#,
    #"{"title":"x","unexpected":true}"#,
    #"{"title":"x","#,
    #"{"title":42}"#,
  ])
  func identifyRefusesWhatTheContractForbids(_ body: String) async throws {
    let (status, text) = try await post("/v1/types/video-game/identify", body)
    #expect(status == .badRequest, "\(body) → \(text)")
    #expect(text.contains("/problems/bad-request"))
    #expect(!text.contains("DecodingError"))
  }

  @Test func identifyTitleLengthCountsCharacters() async throws {
    let ok = try await post(
      "/v1/types/video-game/identify",
      #"{"title":""# + String(repeating: "é", count: 300) + #""}"#
    )
    #expect(ok.0 == .ok)
    let tooLong = try await post(
      "/v1/types/video-game/identify",
      #"{"title":""# + String(repeating: "é", count: 301) + #""}"#
    )
    #expect(tooLong.0 == .badRequest)
  }

  @Test(arguments: [
    "/v1/types/video-game/barcodes/12345",  // too short
    "/v1/types/video-game/barcodes/0602547817327%20",
    "/v1/types/Video_Game/barcodes/0602547817327",
    "/v1/types/video-game/barcodes/0602547817327?subtype=-snes",
    "/v1/types/video-game/barcodes/0602547817327?symbology=morse",
  ])
  func barcodeRefusesWhatTheContractForbids(_ uri: String) async throws {
    let (status, _) = try await get(uri)
    #expect(status == .badRequest, "\(uri)")
  }

  @Test func barcodeAnswersBestFirstWithinBounds() async throws {
    let lookups = CannedLookups(candidates: [
      candidate("low", confidence: 0.2), candidate("high", confidence: 7), candidate("mid", confidence: 0.5),
    ])
    let (status, text) = try await get("/v1/types/video-game/barcodes/0602547817327", lookups: lookups)
    #expect(status == .ok)
    let ids = try JSONDecoder().decode(Components.Schemas.LookupResult.self, from: Data(text.utf8)).candidates
    #expect(ids.map(\.releaseID) == ["high", "mid", "low"])
    #expect(ids.first?.confidence == 1)
  }

  @Test func aSourceOutageIs503WithRetryAfter() async throws {
    let server = try TestServer(environment: .development, lookups: CannedLookups(unavailable: true))
    try await server.run { client in
      try await client.execute(
        uri: "/v1/types/video-game/barcodes/0602547817327",
        method: .get,
        headers: Self.debugHeaders
      ) { response in
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "30")
      }
    }
  }

  /// `getWork` declares no 503, and the generated server would drop an `undocumented` answer's headers and body
  /// (D-18): the outage still arrives as a problem document with `Retry-After`.
  @Test func aSourceOutageOnAWorkIs503WithRetryAfterAndAProblem() async throws {
    let server = try TestServer(environment: .development, lookups: CannedLookups(unavailable: true))
    try await server.run { client in
      try await client.execute(uri: "/v1/works/w1", method: .get, headers: Self.debugHeaders) { response in
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "30")
        #expect(problemType(response) == "/problems/unavailable")
      }
    }
  }

  @Test func matchAnswersInRequestOrderWithBuckets() async throws {
    let lookups = CannedLookups(candidates: [candidate("gb", confidence: 0.6), candidate("nes", confidence: 0.55)])
    let (status, text) = try await post(
      "/v1/types/video-game/match",
      #"{"items":[{"ref":"r1","title":"Donckey Kong Country 2"},{"ref":"r2","title":"Tetris","subtype":"gb"}]}"#,
      lookups: lookups
    )
    #expect(status == .ok)
    let results = try JSONDecoder().decode(Components.Schemas.MatchResult.self, from: Data(text.utf8)).results
    #expect(results.map(\.ref) == ["r1", "r2"])
    #expect(results.map(\.bucket) == [.unknown, .ambiguous])
    #expect(results[1].candidates.count == 2)
  }

  @Test func matchOver50ItemsIs413() async throws {
    let items = (0..<51).map { #"{"ref":"r\#($0)","title":"t"}"# }.joined(separator: ",")
    let (status, text) = try await post("/v1/types/video-game/match", #"{"items":[\#(items)]}"#)
    #expect(status == .contentTooLarge)
    #expect(text.contains("/problems/payload-too-large"))
  }

  @Test(arguments: [
    #"{"items":[]}"#,
    #"{"items":[{"ref":"r1"}]}"#,
    #"{"items":[{"ref":"r1","title":"t","condition":"mint"}]}"#,
  ])
  func matchRefusesWhatTheContractForbids(_ body: String) async throws {
    let (status, _) = try await post("/v1/types/video-game/match", body)
    #expect(status == .badRequest, "\(body)")
  }

  @Test func healthListsTheTypesWithASource() async throws {
    let (status, text) = try await get("/v1/health", lookups: CannedLookups())
    #expect(status == .ok)
    #expect(text == #"{"status":"ok","types":["music","video-game"]}"#)
  }

  @Test func noSourcesMeansNoCandidatesAndNoTypes() async throws {
    #expect(try await get("/v1/health").1 == #"{"status":"ok","types":[]}"#)
    #expect(try await get("/v1/types/music/barcodes/0602547817327").1 == #"{"candidates":[]}"#)
    #expect(try await get("/v1/works/w1").0 == .notFound)
  }

  @Test func buckets() {
    #expect(LookupAPI.bucket([]).0 == .unknown)
    #expect(LookupAPI.bucket([candidate("a", confidence: 0.3)]).1.map(\.releaseID) == ["a"])
    let clear = LookupAPI.bucket([candidate("a", confidence: 0.9), candidate("b", confidence: 0.6)])
    #expect(clear.0 == .matched && clear.1.map(\.releaseID) == ["a"])
    let close = LookupAPI.bucket([
      candidate("a", confidence: 0.9), candidate("b", confidence: 0.8), candidate("c", confidence: 0.7),
      candidate("d", confidence: 0.6),
    ])
    #expect(close.0 == .ambiguous && close.1.map(\.releaseID) == ["a", "b", "c"])
  }
}
