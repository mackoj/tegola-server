import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import TegolaServer

// Mock mode (D-28): a development server that answers from mocks/catalogue.json and made-up releases, through the
// same router as the real sources; and the debug lines that show what a lookup did.

/// The repo's catalogue, without its latency.
let mockCatalogue: MockCatalogue = {
  let path = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("mocks/catalogue.json").path
  var catalogue = try! MockCatalogue.load(path: path)
  catalogue.latencyMs = 0
  return catalogue
}()

func mockRouter(_ catalogue: MockCatalogue = mockCatalogue) -> LookupRouter {
  makeMockLookupService(catalogue, logger: quietLogger)
}

/// Writes a catalogue to a temporary file and returns its path.
func mockFile(_ json: String) throws -> String {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("mocks-\(UUID().uuidString).json")
  try Data(json.utf8).write(to: url)
  return url.path
}

@Suite struct MockCatalogueTests {
  @Test func theReposCatalogueKeepsTheRules() {
    #expect(mockCatalogue.problem() == nil)
    #expect(mockCatalogue.releases.count >= 10)
    #expect(Set(mockCatalogue.types).isSuperset(of: ["music", "video-game", "board-games", "thing"]))
    #expect(mockRouter().supportedTypes == ["board-games", "music", "thing", "video-game"])
  }

  @Test(arguments: [
    ("{", "isn't a mock catalogue"),
    (#"{"releases":[{"type":"music","title":"x"}]}"#, "at releases.0.id"),
    (#"{"releases":[{"type":"music","id":"Not A Slug","title":"x"}]}"#, "releases.0.id must be a slug"),
    (#"{"releases":[{"type":"music","id":"a","title":"x","year":3000}]}"#, "releases.0.year"),
    (#"{"releases":[{"type":"music","id":"a","title":"x","barcodes":["12"]}]}"#, "releases.0.barcodes"),
    (#"{"releases":[{"type":"music","id":"a","title":"x"},{"type":"music","id":"a","title":"y"}]}"#, "used twice"),
    (#"{"releases":[],"scenarios":[{"outcome":"nothing"}]}"#, "scenarios.0 needs a barcode or a title"),
    (#"{"releases":[],"scenarios":[{"title":"x","outcome":"explode"}]}"#, "at scenarios.0.outcome"),
    (#"{"latencyMs":-1,"releases":[]}"#, "latencyMs"),
  ])
  func aCatalogueThatBreaksARuleStopsTheServer(json: String, message: String) throws {
    let path = try mockFile(json)
    #expect {
      _ = try MockCatalogue.load(path: path)
    } throws: { error in
      "\(error)".contains(message)
    }
  }

  @Test func mocksAreRefusedInProductionBeforeTheFileIsRead() {
    let env = [
      "TEGOLA_ENVIRONMENT": "production", "TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola",
      "TEGOLA_DATABASE_URL": "postgres://u:p@localhost/db", "TEGOLA_MOCKS": "/nonexistent/catalogue.json",
    ]
    #expect {
      _ = try ServerConfiguration.load(from: env)
    } throws: { error in
      "\(error)".contains("TEGOLA_MOCKS is refused in production")
    }
  }

  @Test func mocksReplaceTheSourcesAndNeverSitBesideThem() throws {
    let path = try mockFile(#"{"releases":[]}"#)
    var env = [
      "TEGOLA_ENVIRONMENT": "development", "TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_MOCKS": path,
    ]
    let configuration = try ServerConfiguration.load(from: env)
    #expect(configuration.mocks?.summary == "mock (0 releases, 0 scenarios)")
    env["TEGOLA_MUSICBRAINZ_CONTACT"] = "ops@example.com"
    #expect {
      _ = try ServerConfiguration.load(from: env)
    } throws: { error in
      "\(error)".contains("TEGOLA_MOCKS replaces the lookup sources") && "\(error)".contains("musicbrainz")
    }
    env["TEGOLA_MUSICBRAINZ_CONTACT"] = nil
    env["TEGOLA_MOCKS"] = "/nonexistent/catalogue.json"
    #expect {
      _ = try ServerConfiguration.load(from: env)
    } throws: { error in
      "\(error)".contains("can't be read")
    }
  }
}

@Suite struct MockLookupTests {
  @Test func aCatalogueBarcodeFindsItsRelease() async throws {
    let candidate = try #require(try await mockRouter().barcode(.init(typeID: "music", code: "724385522925")).first)
    #expect(candidate.releaseID == "mock:music:ok-computer-cd-gb")
    #expect(candidate.workID == "mock:music:work:ok-computer")
    #expect(candidate.title == "OK Computer")
    #expect(candidate.subtype == "cd")
    #expect(candidate.confidence == 0.95)
    #expect(candidate.reasons.map(\.kind) == [.barcode])
    #expect(candidate.sources.map(\.name) == ["Mock"])
    #expect(field(candidate, "label") == .case1("Parlophone"))
    #expect(candidate.entries?.additionalProperties["tracklist"]?.count == 12)
    // A UPC-A scanned as its EAN-13 finds the same release.
    let ean = try await mockRouter().barcode(.init(typeID: "music", code: "0724385522925"))
    #expect(ean.first?.releaseID == "mock:music:ok-computer-cd-gb")
  }

  @Test func anUnknownBarcodeMakesUpOneReleaseTheSameEveryTime() async throws {
    let first = try await mockRouter().barcode(.init(typeID: "video-game", code: "5012345678900"))
    let again = try await mockRouter().barcode(.init(typeID: "video-game", code: "5012345678900"))
    let game = try #require(first.first)
    #expect(first.count == 1)
    #expect(first == again)
    #expect(game.releaseID.hasPrefix("mock:video-game:gen:code-5012345678900"))
    #expect(game.releaseID.count <= 128)
    if case .case1(let platform)? = field(game, "platform") { #expect(game.subtitle == platform) }
    #expect(field(game, "publisher") != nil)
    // Asked for a subtype, it's made up in that subtype.
    let n64 = try await mockRouter().barcode(.init(typeID: "video-game", code: "5012345678900", subtype: "n64"))
    #expect(n64.first?.subtype == "n64")
    #expect(field(try #require(n64.first), "platform") == .case1("Nintendo 64"))
  }

  @Test func catalogueWordsAreMatched() async throws {
    let candidates = try await mockRouter().match(typeID: "music", .init(ref: "r", title: "ok computer"))
    #expect(candidates.first?.releaseID == "mock:music:ok-computer-cd-gb")
    #expect(candidates.first?.confidence == 1)
    #expect(LookupAPI.bucket(candidates).0 == .matched)
    // The artist with the title is as good.
    let both = try await mockRouter().match(
      typeID: "music",
      .init(ref: "r", title: "Kind of Blue", subtitle: "Miles Davis")
    )
    #expect(both.first?.releaseID == "mock:music:kind-of-blue-lp-us")
  }

  /// Words the catalogue doesn't know make up a release (matched), two editions (ambiguous) or nothing (unknown),
  /// by the words, so an import gets all three and the same row always gets the same.
  @Test func unknownWordsGiveEveryImportBucketTheSameWayEachTime() async throws {
    var buckets: [String: Int] = [:]
    for index in 0..<60 {
      let item = Components.Schemas.MatchItem(ref: "r", title: "Imaginary title \(index)")
      let candidates = try await mockRouter().match(typeID: "board-games", item)
      #expect(try await mockRouter().match(typeID: "board-games", item) == candidates)
      buckets[LookupAPI.bucket(candidates).0.rawValue, default: 0] += 1
      for candidate in candidates {
        #expect(candidate.title == "Imaginary title \(index)")
        #expect(candidate.releaseID.count <= 128)
      }
    }
    #expect(buckets["matched", default: 0] > 30)
    #expect(buckets["ambiguous", default: 0] > 0)
    #expect(buckets["unknown", default: 0] > 0)
  }

  @Test func whatTheWordsAskForIsKept() async throws {
    let candidates = try await mockRouter().identify(
      typeID: "music",
      .init(title: "Imaginary album", subtitle: "Nobody Real", year: 1984, subtype: "vinyl")
    )
    for candidate in candidates {
      #expect(candidate.subtitle == "Nobody Real")
      #expect(candidate.year == 1984)
      #expect(candidate.subtype == "vinyl")
      #expect(field(candidate, "medium") == .case1("Vinyl"))
    }
  }

  @Test func aCatalogueNumberAloneFindsItsRelease() async throws {
    let candidates = try await mockRouter().identify(typeID: "music", .init(catalogueNumber: "cl 1355"))
    #expect(candidates.map(\.releaseID) == ["mock:music:kind-of-blue-lp-us"])
    #expect(candidates.first?.reasons.map(\.kind) == [.title, .catalogueNumber])
  }

  @Test func scenariosPlayTheAppsOtherPaths() async throws {
    await #expect {
      _ = try await mockRouter().barcode(.init(typeID: "music", code: "0000000000000"))
    } throws: { error in
      (error as? SourceUnavailable)?.retryAfter == 30
    }
    await #expect(throws: SourceUnavailable.self) {
      _ = try await mockRouter().match(typeID: "thing", .init(ref: "r", title: "Unavailable"))
    }
    #expect(try await mockRouter().barcode(.init(typeID: "music", code: "1111111111111")).isEmpty)
    #expect(try await mockRouter().match(typeID: "music", .init(ref: "r", title: "nothing")).isEmpty)

    var slow = mockCatalogue
    slow.scenarios = [.init(title: "slow", outcome: .slow, delayMs: 120)]
    let start = ContinuousClock.now
    let answered = try await mockRouter(slow).match(typeID: "music", .init(ref: "r", title: "Slow"))
    #expect(ContinuousClock.now - start >= .milliseconds(120))
    #expect(!answered.isEmpty)
  }

  @Test func worksComeFromTheCatalogueOrAreMadeUpAgain() async throws {
    let work = try #require(try await mockRouter().work(id: "mock:music:work:ok-computer"))
    #expect(work.title == "OK Computer")
    #expect(
      work.releases.map(\.releaseID).sorted() == [
        "mock:music:ok-computer-cd-gb", "mock:music:ok-computer-oknotok-lp-gb",
      ]
    )

    let made = try #require(
      try await mockRouter().barcode(.init(typeID: "board-games", code: "5012345678900")).first?.workID
    )
    let madeWork = try #require(try await mockRouter().work(id: made))
    #expect(madeWork.workID == made)
    #expect(madeWork.releases.count == 2)
    #expect(try await mockRouter().work(id: "mock:music:gen:Not A Slug") == nil)
    #expect(try await mockRouter().work(id: "mock:music:work:nope") == nil)
  }

  @Test func theRouteAnswersFromTheMocks() async throws {
    let server = try TestServer(environment: .development, lookups: mockRouter())
    try await server.run { client in
      try await client.execute(uri: "/v1/health", method: .get) { response in
        #expect(String(buffer: response.body).contains(#""types":["board-games","music","thing","video-game"]"#))
      }
      try await client.execute(
        uri: "/v1/types/music/barcodes/724385522925",
        method: .get,
        headers: [.tegolaDebugToken: debugToken]
      ) { response in
        #expect(response.status == .ok)
        let body = String(buffer: response.body)
        #expect(body.contains(#""releaseID":"mock:music:ok-computer-cd-gb""#))
        #expect(body.contains("Mock data from a tegola-server development build"))
      }
      try await client.execute(
        uri: "/v1/types/music/barcodes/0000000000000",
        method: .get,
        headers: [.tegolaDebugToken: debugToken]
      ) { response in
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "30")
      }
    }
  }
}

/// What a lookup writes at debug level (D-28): its shape, never its words, code or ids.
@Suite struct LookupLogTests {
  @Test func aLookupLogsWhatItAskedAndNothingItWasAsked() async throws {
    let capture = LogCapture()
    let router = makeMockLookupService(mockCatalogue, logger: capture.logger)
    _ = try await router.identify(
      typeID: "music",
      .init(title: "Sentinel words TEGOLA-TEST-SENTINEL", barcode: .init(code: "5012345678900"))
    )
    _ = try await router.barcode(.init(typeID: "music", code: "5012345678900"))
    let text = capture.text
    #expect(text.contains("lookup"))
    #expect(text.contains("source asked"))
    #expect(text.contains(#""outcome": found"#) || text.contains("outcome: found") || text.contains("found"))
    #expect(text.contains("cached"))
    #expect(!text.lowercased().contains("sentinel"))
    #expect(!text.contains("5012345678900"))
    #expect(!text.contains("mock:music"))
  }

  @Test func aSourceCallLogsItsShapeNotItsRequest() async throws {
    let capture = LogCapture()
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzBarcode))])
    let provider = MusicBrainzProvider(
      connection: testConnection("musicbrainz", transport, logger: capture.logger),
      userAgent: "tegola-server/1.0 ( ops@example.com )"
    )
    _ = try await provider.barcode(.init(typeID: "music", code: "724385522925"))
    let text = capture.text
    #expect(text.contains("source call"))
    #expect(text.contains("musicbrainz"))
    #expect(text.contains("200"))
    #expect(!text.contains("724385522925"))
    #expect(!text.contains("musicbrainz.org"))
    #expect(!text.contains("ops@example.com"))
  }
}
