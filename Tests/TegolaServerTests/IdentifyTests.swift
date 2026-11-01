import AppAttestTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import TegolaServer

/// `identifyObject` (contract 0.2.0, D-24): hints as JSON, or a photo and hints as multipart.
@Suite("Identify")
struct IdentifyTests {
  static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x42, count: 60) + [0xFF, 0xD9]
  static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 32)
  static let boundary = "tegola-test-boundary"

  enum Part {
    case image([UInt8], contentType: String = "image/jpeg")
    case hints(String)
  }

  static func multipart(_ parts: [Part]) -> [UInt8] {
    var body: [UInt8] = []
    func line(_ text: String) { body += Array((text + "\r\n").utf8) }
    for part in parts {
      line("--\(boundary)")
      switch part {
      case .image(let bytes, let contentType):
        line(#"Content-Disposition: form-data; name="image"; filename="shot.jpg""#)
        line("Content-Type: \(contentType)")
        line("")
        body += bytes
        line("")
      case .hints(let json):
        line(#"Content-Disposition: form-data; name="hints""#)
        line("Content-Type: application/json")
        line("")
        line(json)
      }
    }
    line("--\(boundary)--")
    return body
  }

  static var multipartHeaders: HTTPFields {
    var headers = ip("1.1.1.1")
    headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
    headers[.tegolaDebugToken] = debugToken
    return headers
  }

  struct Answer {
    var status: HTTPResponse.Status
    var problem: String?
    var candidates: Int?
  }

  func send(
    _ body: [UInt8],
    headers: HTTPFields = multipartHeaders,
    uri: String = "/v1/types/video-game/identify",
    limits: @escaping (inout ServerConfiguration.Limits) -> Void = { _ in },
    lookups: (any LookupService)? = CannedLookups(candidates: [candidate("r1", confidence: 0.9)])
  ) async throws -> Answer {
    let server = try TestServer(environment: .development, limits: limits, lookups: lookups)
    nonisolated(unsafe) var answer = Answer(status: .ok)
    try await server.run { client in
      try await client.execute(uri: uri, method: .post, headers: headers, body: ByteBuffer(bytes: body)) { response in
        let object = try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
        answer = Answer(
          status: response.status,
          problem: object?["type"] as? String,
          candidates: (object?["candidates"] as? [Any])?.count
        )
      }
    }
    return answer
  }

  // MARK: JSON

  @Test func aBarcodeAloneIsAQuery() async throws {
    var headers = ContractTests.debugHeaders
    headers[.contentType] = "application/json"
    let answer = try await send(
      Array(#"{"barcode":{"code":"0602547817327","symbology":"ean13"}}"#.utf8),
      headers: headers
    )
    #expect(answer.status == .ok)
    #expect(answer.candidates == 1)
  }

  @Test(arguments: [
    #"{"barcode":{"code":"12 34"}}"#,
    #"{"barcode":{"code":"12345"}}"#,
    #"{"barcode":{}}"#,
    #"{"barcode":{"code":"0602547817327","extra":1}}"#,
    #"{"subtype":"ps1"}"#,
  ])
  func jsonHintsRefuseWhatTheContractForbids(_ body: String) async throws {
    let answer = try await send(Array(body.utf8), headers: ContractTests.debugHeaders)
    #expect(answer.status == .badRequest, "\(body)")
    #expect(answer.problem == "/problems/bad-request")
  }

  // MARK: multipart

  @Test func aPhotoWithHintsAnswersFromTheHints() async throws {
    let answer = try await send(Self.multipart([.image(Self.jpeg), .hints(#"{"title":"Ridge Racer"}"#)]))
    #expect(answer.status == .ok)
    #expect(answer.candidates == 1)
  }

  @Test func hintsAloneInMultipartWork() async throws {
    let answer = try await send(Self.multipart([.hints(#"{"title":"Ridge Racer","limit":3}"#)]))
    #expect(answer.status == .ok)
    #expect(answer.candidates == 1)
  }

  /// No source reads images yet: a photo alone is "no match", and the lookup service is never asked.
  @Test func aPhotoAloneIsNoMatchAndAsksNoSource() async throws {
    let answer = try await send(Self.multipart([.image(Self.jpeg)]))
    #expect(answer.status == .ok)
    #expect(answer.candidates == 0)
    let withEmptyHints = try await send(Self.multipart([.image(Self.jpeg), .hints("{}")]))
    #expect(withEmptyHints.status == .ok)
    #expect(withEmptyHints.candidates == 0)
  }

  @Test func anImageThatIsntAJPEGIs415() async throws {
    // Labelled as a JPEG, but a PNG: the bytes decide.
    let answer = try await send(Self.multipart([.image(Self.png), .hints(#"{"title":"x"}"#)]))
    #expect(answer.status == .unsupportedMediaType)
    #expect(answer.problem == "/problems/unsupported-media-type")
  }

  @Test func anImagePartOfAnotherTypeIsRefused() async throws {
    let answer = try await send(Self.multipart([.image(Self.jpeg, contentType: "image/png")]))
    #expect(answer.status == .badRequest || answer.status == .unsupportedMediaType)
    #expect(answer.candidates == nil)
  }

  @Test func anImageOverItsCapIs413() async throws {
    let big = Self.jpeg + [UInt8](repeating: 0x42, count: 2048)
    let answer = try await send(Self.multipart([.image(big)])) { $0.maximumImageBytes = 1024 }
    #expect(answer.status == .contentTooLarge)
    #expect(answer.problem == "/problems/payload-too-large")
  }

  @Test func aBodyOverIdentifysCapIs413() async throws {
    let big = Self.jpeg + [UInt8](repeating: 0x42, count: 8192)
    let answer = try await send(Self.multipart([.image(big)])) {
      $0.maximumIdentifyBodyBytes = 4096
      $0.maximumImageBytes = 16384
    }
    #expect(answer.status == .contentTooLarge)
  }

  /// Identify's larger cap is identify's alone: the same body to another operation is 413.
  @Test func onlyIdentifyTakesTheLargerCap() async throws {
    let limits: (inout ServerConfiguration.Limits) -> Void = { $0.maximumBodyBytes = 1024 }
    let photo = Self.jpeg + [UInt8](repeating: 0x42, count: 2048)
    let identify = try await send(Self.multipart([.image(photo), .hints(#"{"title":"x"}"#)]), limits: limits)
    #expect(identify.status == .ok)
    let items = (0..<40).map { #"{"ref":"r\#($0)","title":"\#(String(repeating: "t", count: 40))"}"# }
    let match = try await send(
      Array(#"{"items":[\#(items.joined(separator: ","))]}"#.utf8),
      headers: ContractTests.debugHeaders,
      uri: "/v1/types/video-game/match",
      limits: limits
    )
    #expect(match.status == .contentTooLarge)
  }

  @Test(arguments: [
    [Part.image(jpeg), .image(jpeg)],
    [Part.hints(#"{"title":"x"}"#), .hints(#"{"title":"y"}"#)],
    [Part.hints("{}")],
    [Part.hints(#"{"title":"   "}"#)],
    [Part.hints(#"{"title":"x","limit":11}"#)],
    [Part.hints(#"{"title":"x","unexpected":true}"#)],
    [Part.hints(#"{"title":"#)],
    [],
  ])
  func multipartRefusesWhatTheContractForbids(_ parts: [Part]) async throws {
    let answer = try await send(Self.multipart(parts))
    #expect(answer.status == .badRequest)
    #expect(answer.problem == "/problems/bad-request")
  }

  // MARK: App Attest over multipart

  @Test func theAssertionCoversTheWholeMultipartBody() async throws {
    let server = try TestServer(lookups: CannedLookups(candidates: [candidate("r1", confidence: 0.9)]))
    let device = FakeDevice()
    let path = "/v1/types/video-game/identify"
    let body = Self.multipart([.image(Self.jpeg), .hints(#"{"title":"Ridge Racer"}"#)])
    let tampered = {
      var bytes = body
      bytes[bytes.firstIndex(of: 0x42)!] = 0x43  // one byte of the photo
      return bytes
    }()
    try await server.run { client in
      try await server.register(device, client: client)
      for (counter, sent, expected) in [
        (UInt32(1), tampered, HTTPResponse.Status.unauthorized), (2, body, .ok),
      ] {
        var headers = try server.signed(device, counter: counter, method: .post, path: path, body: body)
        headers[.contentType] = "multipart/form-data; boundary=\(Self.boundary)"
        try await client.execute(uri: path, method: .post, headers: headers, body: ByteBuffer(bytes: sent)) {
          response in
          #expect(response.status == expected)
        }
      }
    }
  }

  /// Without a registered key, an identify body isn't read: the answer is 401, not 413, whatever its size.
  @Test func anUnsignedLargeBodyIsRefusedBeforeItsRead() async throws {
    let server = try TestServer { $0.maximumIdentifyBodyBytes = 4096 }
    try await server.run { client in
      var headers = ip("1.1.1.1")
      headers[.contentType] = "multipart/form-data; boundary=\(Self.boundary)"
      let body = Self.multipart([.image(Self.jpeg + [UInt8](repeating: 0x42, count: 2048))])
      try await client.execute(
        uri: "/v1/types/video-game/identify",
        method: .post,
        headers: headers,
        body: ByteBuffer(bytes: body)
      ) { response in
        #expect(response.status == .unauthorized)
      }
    }
  }
}

/// Answers a barcode with one list and words with another.
struct SplitProvider: DataProvider {
  let name = "split"
  let typeID = "music"
  let idPrefix = "split:"
  let answersBarcodes = true
  var byBarcode: Result<[Components.Schemas.Candidate], ProviderFailure>
  var byWords: Result<[Components.Schemas.Candidate], ProviderFailure>

  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [Components.Schemas.Candidate] {
    try byBarcode.get()
  }
  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [Components.Schemas.Candidate] {
    try byWords.get()
  }
  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work? { nil }
}

@Suite struct IdentifyServiceTests {
  static func found(_ id: String, _ confidence: Double, _ kind: Components.Schemas.Reason.KindPayload)
    -> Components.Schemas.Candidate
  {
    var candidate = candidate(id, confidence: confidence)
    candidate.reasons = [.init(kind: kind)]
    return candidate
  }

  let hints = Components.Schemas.IdentifyHints(title: "OK Computer", barcode: .init(code: "724385522925"))

  @Test func aReleaseFoundByBarcodeAndWordsIsOneCandidateWithBothReasons() async throws {
    let service = LookupRouter(sources: [
      SplitProvider(
        byBarcode: .success([Self.found("split:1", 0.95, .barcode)]),
        byWords: .success([Self.found("split:1", 0.6, .title), Self.found("split:2", 0.5, .title)])
      )
    ])
    let candidates = try await service.identify(typeID: "music", hints)
    #expect(candidates.map(\.releaseID).sorted() == ["split:1", "split:2"])
    let both = try #require(candidates.first { $0.releaseID == "split:1" })
    #expect(both.confidence == 0.95)
    #expect(both.reasons.map(\.kind) == [.barcode, .title])
  }

  @Test func oneHalfFailingDoesntHideTheOther() async throws {
    let service = LookupRouter(sources: [
      SplitProvider(byBarcode: .failure(.busy(retryAfter: 30)), byWords: .success([Self.found("split:2", 0.5, .title)]))
    ])
    #expect(try await service.identify(typeID: "music", hints).map(\.releaseID) == ["split:2"])
  }

  @Test func aFailureBesideNothingFoundIsUnavailable() async throws {
    let service = LookupRouter(sources: [
      SplitProvider(byBarcode: .failure(.busy(retryAfter: 30)), byWords: .success([]))
    ])
    await #expect(throws: SourceUnavailable.self) { try await service.identify(typeID: "music", hints) }
  }

  @Test func aBarcodeHintIsAskedAsABarcode() async throws {
    let service = LookupRouter(sources: [
      SplitProvider(byBarcode: .success([Self.found("split:1", 0.95, .barcode)]), byWords: .success([]))
    ])
    let barcodeOnly = Components.Schemas.IdentifyHints(barcode: .init(code: "724385522925"))
    #expect(try await service.identify(typeID: "music", barcodeOnly).map(\.releaseID) == ["split:1"])
  }
}
