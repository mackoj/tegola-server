import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import TegolaServer

// The lookup sources (D-22), against replayed answers: what each one asks, what it makes of the answer, and the
// attacks it refuses.

func field(_ candidate: Components.Schemas.Candidate, _ key: String) -> Components.Schemas.FieldValue? {
  candidate.fields?.additionalProperties[key]
}

extension DataProvider {
  /// What the router makes of this provider's records for words, one candidate each, in the provider's order.
  func candidates(_ query: SearchQuery) async throws(ProviderFailure) -> [Components.Schemas.Candidate] {
    try await search(query).map { RecordMerge.candidate([Ranking.words($0, query: query, weights: weights)]) }
  }

  /// What the router makes of this provider's records for a barcode, one candidate each, in the provider's order.
  func candidates(_ query: BarcodeQuery) async throws(ProviderFailure) -> [Components.Schemas.Candidate] {
    try await barcode(query).map { RecordMerge.candidate([Ranking.barcode($0, weights: weights)]) }
  }
}

/// A record from a scripted provider: its id is `<provider>:<n>`, its title the id unless given.
func record(
  _ id: String,
  title: String? = nil,
  typeID: String = "music",
  externalIDs: [String: String] = [:]
) -> ProviderRecord {
  ProviderRecord(
    provider: String(id.prefix { $0 != ":" }),
    releaseID: id,
    typeID: typeID,
    title: title ?? id,
    externalIDs: externalIDs,
    source: .init(name: String(id.prefix { $0 != ":" }))
  )
}

func query(_ request: OutboundRequest, _ name: String) -> String? {
  URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Suite struct MusicBrainzTests {
  func source(_ transport: ReplayTransport) -> MusicBrainzProvider {
    MusicBrainzProvider(
      connection: testConnection("musicbrainz", transport),
      userAgent: "tegola-server/1.0 ( ops@example.com )"
    )
  }

  @Test func aBarcodeKeepsOnlyExactHitsAndFillsTheTypeFields() async throws {
    let transport = ReplayTransport([("musicbrainz.org/ws/2/release", ok(Fixture.musicBrainzBarcode))])
    let candidates = try await source(transport).candidates(
      .init(typeID: "music", code: "724385522925", symbology: .ean13)
    )
    #expect(candidates.count == 1)
    let candidate = try #require(candidates.first)
    #expect(candidate.releaseID == "musicbrainz:release:\(Fixture.mbRelease)")
    #expect(candidate.workID == "musicbrainz:release-group:\(Fixture.mbGroup)")
    #expect(candidate.title == "OK Computer")
    #expect(candidate.subtitle == "Radiohead")
    #expect(candidate.year == 1997)
    #expect(candidate.subtype == "vinyl")
    #expect(candidate.confidence == 0.95)
    #expect(candidate.reasons.map(\.kind) == [.barcode])
    #expect(candidate.sources.first?.name == "MusicBrainz")
    #expect(field(candidate, "medium") == .case1("Vinyl"))
    #expect(field(candidate, "format") == .case1("2×LP"))
    #expect(field(candidate, "label") == .case1("Parlophone"))
    #expect(field(candidate, "catalogNumber") == .case1("NODATA 02"))
    #expect(field(candidate, "country") == .case1("GB"))
    let cover = "https://coverartarchive.org/release/\(Fixture.mbRelease)/front"
    #expect(candidate.images?.map(\.role) == [.front, .thumbnail])
    #expect(candidate.images?.map(\.url) == ["\(cover)-500", "\(cover)-250"])

    let request = try #require(transport.sent.first)
    #expect(query(request, "query") == "barcode:724385522925")
    #expect(request.headers["User-Agent"] == "tegola-server/1.0 ( ops@example.com )")
  }

  @Test func aSubtypeFiltersBarcodeHits() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzBarcode))])
    let candidates = try await source(transport).candidates(.init(typeID: "music", code: "724385522925", subtype: "cd"))
    #expect(candidates.isEmpty)
  }

  @Test func searchRanksByTitleArtistAndYear() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzSearch))])
    let candidates = try await source(transport).candidates(
      .init(title: "ok computer", subtitle: "Radiohead", year: 1997, limit: 5, reason: .title)
    )
    #expect(candidates.count == 2)
    #expect(candidates[0].confidence == 1)
    #expect(candidates[1].confidence < candidates[0].confidence)
    #expect(field(candidates[1], "format") == .case1("2×CD"))
    // A cover is listed only when the archive says the release has a front: no art, or only a back, is none.
    #expect(candidates.allSatisfy { $0.images == nil })
    let lucene = try #require(transport.sent.first.flatMap { query($0, "query") })
    #expect(lucene == "release:(ok computer) AND artist:(Radiohead)")
  }

  /// Words from the app stay words: Lucene's syntax is escaped and AND/OR/NOT lose their meaning (D-22).
  @Test func searchWordsCantChangeTheQuery() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(#"{"releases":[]}"#))])
    _ = try await source(transport).search(
      .init(title: #"AC/DC") OR barcode:* AND "x"#, limit: 5, reason: .title)
    )
    let lucene = try #require(transport.sent.first.flatMap { query($0, "query") })
    #expect(lucene == #"release:(AC\/DC\"\) or barcode\:\* and \"x)"#)
  }

  @Test func aWorkIsTheReleaseGroupsReleases() async throws {
    let transport = ReplayTransport([("musicbrainz.org/ws/2/release", ok(Fixture.musicBrainzWork))])
    let work = try #require(try await source(transport).work(id: "musicbrainz:release-group:\(Fixture.mbGroup)"))
    #expect(work.title == "OK Computer")
    #expect(work.releases.map(\.subtype) == ["vinyl", "cd"])
    #expect(work.releases.map(\.year) == [1997, 2009])
    #expect(transport.sent.first.flatMap { query($0, "release-group") } == Fixture.mbGroup)
  }

  /// A work id that isn't a UUID never reaches MusicBrainz: no path or query can be smuggled in.
  @Test func aMalformedWorkIDSendsNothing() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzWork))])
    for id in ["musicbrainz:release-group:../../artist", "musicbrainz:release-group:x?inc=all", "musicbrainz:"] {
      #expect(try await source(transport).work(id: id) == nil)
    }
    #expect(transport.sent.isEmpty)
  }
}

@Suite struct IGDBTests {
  func source(_ transport: ReplayTransport) -> IGDBProvider {
    IGDBProvider(
      connection: testConnection("igdb", transport),
      tokens: TwitchTokens(
        clientID: "client-id",
        clientSecret: "TEGOLA-TEST-SENTINEL-secret",
        connection: testConnection("twitch", transport)
      )
    )
  }

  @Test func searchMakesOneCandidatePerPlatformAndRegion() async throws {
    let transport = ReplayTransport([
      ("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com/v4/games", ok(Fixture.igdbGames)),
    ])
    let candidates = try await source(transport).candidates(
      .init(title: "Ocarina of Time", subtitle: "Nintendo 64", limit: 5, reason: .title)
    )
    #expect(candidates.map(\.region) == ["NTSC-J", "NTSC-U", "PAL"])
    #expect(candidates.map(\.subtype) == ["n64", "n64", nil])
    let n64 = candidates[0]
    #expect(n64.releaseID == "igdb:game:1026:4:NTSC-J")
    #expect(n64.workID == "igdb:game:1026")
    #expect(n64.subtitle == "Nintendo 64")
    #expect(field(n64, "publisher") == .case1("Nintendo"))
    #expect(field(n64, "platform") == .case1("Nintendo 64"))
    #expect(n64.images?.first?.url == "https://images.igdb.com/igdb/image/upload/t_cover_big/co3nnx.jpg")
    #expect(n64.sources.first?.attribution == "Data from IGDB.com")
    #expect(n64.confidence > candidates[2].confidence)
  }

  @Test func aSubtypeAndARegionFilterTheReleases() async throws {
    let transport = ReplayTransport([
      ("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", ok(Fixture.igdbGames)),
    ])
    let candidates = try await source(transport).candidates(
      .init(title: "Ocarina of Time", subtype: "n64", region: "NTSC-U", limit: 5, reason: .title)
    )
    #expect(candidates.map(\.releaseID) == ["igdb:game:1026:4:NTSC-U"])
  }

  /// The secret travels in the token request's body, never in a URL; the token is fetched once and reused.
  @Test func theSecretStaysOutOfURLsAndTheTokenIsReused() async throws {
    let transport = ReplayTransport([
      ("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", ok(Fixture.igdbGames)),
    ])
    let igdb = source(transport)
    _ = try await igdb.search(.init(title: "zelda", limit: 5, reason: .title))
    _ = try await igdb.search(.init(title: "mario", limit: 5, reason: .title))
    let sent = transport.sent
    #expect(sent.filter { $0.url.host == "id.twitch.tv" }.count == 1)
    #expect(sent.allSatisfy { !$0.url.absoluteString.contains("TEGOLA-TEST-SENTINEL-secret") })
    let tokenBody = String(decoding: try #require(sent.first?.body), as: UTF8.self)
    #expect(tokenBody.contains("client_secret=TEGOLA-TEST-SENTINEL-secret"))
    let games = sent.filter { $0.url.host == "api.igdb.com" }
    #expect(games.allSatisfy { $0.headers["Authorization"] == "Bearer TEGOLA-TEST-SENTINEL-token" })
    #expect(games.allSatisfy { $0.headers["Client-ID"] == "client-id" })
  }

  /// Words can't close IGDB's quoted string and add a clause (D-22).
  @Test func searchWordsCantAddAClause() async throws {
    let transport = ReplayTransport([("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", ok("[]"))])
    _ = try await source(transport).search(.init(title: #"zelda"; where id = 1; fields *;"#, limit: 5, reason: .title))
    let body = String(decoding: try #require(transport.sent.last?.body), as: UTF8.self)
    #expect(body.hasPrefix(#"search "zelda where id = 1 fields *"; fields "#))
  }

  /// An older token that IGDB refuses (expired early, revoked) is renewed, once.
  @Test func aRefusedTokenIsRenewedOnce() async throws {
    let transport = ReplayTransport([
      ("id.twitch.tv", [ok(Fixture.twitchToken)]), ("api.igdb.com", [status(401), ok(Fixture.igdbGames)]),
    ])
    // A token old enough to have expired early: minimumAge zero stands for "older than a minute".
    let igdb = IGDBProvider(
      connection: testConnection("igdb", transport),
      tokens: TwitchTokens(
        clientID: "client-id",
        clientSecret: "TEGOLA-TEST-SENTINEL-secret",
        connection: testConnection("twitch", transport),
        minimumAge: .zero
      )
    )
    let candidates = try await igdb.candidates(.init(title: "Ocarina of Time", limit: 5, reason: .title))
    #expect(!candidates.isEmpty)
    #expect(transport.sent.filter { $0.url.host == "id.twitch.tv" }.count == 2)
  }

  /// A cover id that isn't an id never becomes a path in an image URL.
  @Test func aCoverIDThatIsntAnIDIsDropped() async throws {
    let games = Fixture.igdbGames.replacingOccurrences(of: "co3nnx", with: "../../evil?x=1")
    let transport = ReplayTransport([("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", ok(games))])
    let candidates = try await source(transport).candidates(.init(title: "Ocarina of Time", limit: 5, reason: .title))
    #expect(!candidates.isEmpty)
    #expect(candidates.allSatisfy { $0.images == nil })
  }

  @Test func aWorkListsTheReleasesAndTheSeries() async throws {
    let transport = ReplayTransport([
      ("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", ok(Fixture.igdbGames)),
    ])
    let work = try #require(try await source(transport).work(id: "igdb:game:1026"))
    #expect(work.series == ["The Legend of Zelda"])
    #expect(work.releases.count == 3)
    let body = String(decoding: try #require(transport.sent.last?.body), as: UTF8.self)
    #expect(body.contains("where id = 1026;"))
    #expect(try await source(transport).work(id: "igdb:game:1026; fields *") == nil)
  }
}

@Suite struct ScreenScraperTests {
  func source(_ transport: ReplayTransport) -> ScreenScraperProvider {
    ScreenScraperProvider(
      connection: testConnection("screenscraper", transport),
      credentials: .init(developerID: "dev", developerPassword: "TEGOLA-TEST-SENTINEL-dev")
    )
  }

  @Test func searchMakesOneCandidatePerRegionWithoutImages() async throws {
    let transport = ReplayTransport([("api.screenscraper.fr/api2/jeuRecherche.php", ok(Fixture.screenScraperSearch))])
    let candidates = try await source(transport).candidates(
      .init(title: "Sonic the Hedgehog", limit: 5, reason: .title)
    )
    #expect(candidates.map(\.region) == ["NTSC-U", "NTSC-J", "PAL"])
    #expect(candidates.map(\.title) == ["Sonic The Hedgehog", "Sonic The Hedgehog (JP)", "Sonic The Hedgehog"])
    #expect(candidates[0].releaseID == "screenscraper:game:3:NTSC-U")
    #expect(candidates[0].subtitle == "Megadrive")
    #expect(field(candidates[0], "publisher") == .case1("SEGA"))
    // ScreenScraper's media URLs carry the developer's credentials: none reaches the app.
    #expect(candidates.allSatisfy { $0.images == nil })
    let encoded = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
    #expect(!encoded.contains("TEGOLA-TEST-SENTINEL"))
    let request = try #require(transport.sent.first)
    #expect(query(request, "devid") == "dev")
    #expect(query(request, "output") == "json")
    #expect(query(request, "recherche") == "Sonic the Hedgehog")
  }

  @Test func aSubtypeAsksForItsSystem() async throws {
    let transport = ReplayTransport([("api.screenscraper.fr", ok(Fixture.screenScraperEmpty))])
    let candidates = try await source(transport).candidates(
      .init(title: "Mario", subtype: "n64", limit: 5, reason: .title)
    )
    #expect(candidates.isEmpty)
    #expect(transport.sent.first.flatMap { query($0, "systemeid") } == "14")
  }

  @Test func theDailyQuotaIsABusySourceForAnHour() async throws {
    let transport = ReplayTransport([("api.screenscraper.fr", status(430))])
    await #expect(throws: ProviderFailure.busy(retryAfter: 3600)) {
      _ = try await source(transport).search(.init(title: "Sonic", limit: 5, reason: .title))
    }
  }
}

@Suite struct BoardGameGeekTests {
  func source(_ transport: ReplayTransport) -> BoardGameGeekProvider {
    BoardGameGeekProvider(connection: testConnection("boardgamegeek", transport), token: "TEGOLA-TEST-SENTINEL-bgg")
  }

  @Test func searchReadsTheBestGamesDetails() async throws {
    let transport = ReplayTransport([
      ("xmlapi2/search", xml(Fixture.bggSearch)), ("xmlapi2/thing", xml(Fixture.bggThing)),
    ])
    let candidates = try await source(transport).candidates(
      .init(title: "Agricola", subtitle: "Z-Man Games", year: 2007, limit: 5, reason: .title)
    )
    #expect(candidates.count == 1)  // the expansion in the answer is not a board game
    let game = try #require(candidates.first)
    #expect(game.releaseID == "boardgamegeek:31260")
    #expect(game.title == "Agricola")
    #expect(game.subtitle == "Lookout Games")
    #expect(game.year == 2007)
    #expect(game.confidence == 1)
    #expect(field(game, "designer") == .case1("Uwe Rosenberg"))
    #expect(field(game, "players") == .case1("1–5"))
    #expect(field(game, "playTime") == .case2(150))
    #expect(field(game, "minAge") == .case2(12))
    #expect(field(game, "weight") == .case2(3.6))
    // Only BGG's image host: the foreign image is dropped, the thumbnail kept.
    #expect(game.images?.map(\.role) == [.thumbnail])
    #expect(game.sources.first?.attribution == "Powered by BoardGameGeek")

    let sent = transport.sent
    #expect(sent.count == 2)
    #expect(sent.allSatisfy { $0.headers["Authorization"] == "Bearer TEGOLA-TEST-SENTINEL-bgg" })
    #expect(query(sent[1], "id") == "31260,200680,12345")
  }

  /// Popular games list dozens of publishers: the asked one counts wherever it is in the list.
  @Test func theAskedPublisherCountsDeepInALongList() async throws {
    let lookout = #"<link type="boardgamepublisher" id="2" value="Lookout Games"/>"#
    let fillers = (0..<40).map { #"<link type="boardgamepublisher" id="\#(100 + $0)" value="Edition \#($0)"/>"# }
    let thing = Fixture.bggThing.replacingOccurrences(of: lookout, with: fillers.joined(separator: "\n") + lookout)
    let transport = ReplayTransport([("xmlapi2/search", xml(Fixture.bggSearch)), ("xmlapi2/thing", xml(thing))])
    let game = try #require(
      try await source(transport).candidates(
        .init(title: "Agricola", subtitle: "Z-Man Games", year: 2007, limit: 5, reason: .title)
      ).first
    )
    #expect(game.subtitle == "Edition 0")
    #expect(game.confidence == 1)
  }

  @Test func playersReadsLikeTheTypeFile() {
    #expect(BoardGameGeekProvider.players(minimum: 2, maximum: 4) == "2–4")
    #expect(BoardGameGeekProvider.players(minimum: 2, maximum: 2) == "2")
    #expect(BoardGameGeekProvider.players(minimum: 0, maximum: 0) == nil)
  }
}

/// A source that answers or fails as told, and counts its calls.
final class ScriptedProvider: DataProvider, @unchecked Sendable {
  let name: String
  let typeID: String
  let idPrefix: String
  let answersBarcodes: Bool
  let tier: ProviderTier
  var weights = ProviderWeights()
  var delay: Duration?
  var failure: ProviderFailure?
  var answer: [ProviderRecord]
  private let lock = NSLock()
  private var count = 0

  init(
    _ name: String,
    typeID: String = "music",
    tier: ProviderTier = .primary,
    answersBarcodes: Bool = true,
    answer: [ProviderRecord] = [],
    failure: ProviderFailure? = nil
  ) {
    self.answersBarcodes = answersBarcodes
    self.name = name
    self.typeID = typeID
    self.tier = tier
    self.idPrefix = "\(name):"
    self.answer = answer
    self.failure = failure
  }

  var calls: Int { lock.withLock { count } }

  func respond() throws(ProviderFailure) -> [ProviderRecord] {
    lock.withLock { count += 1 }
    if let failure { throw failure }
    return answer
  }

  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [ProviderRecord] {
    if let delay { try? await Task.sleep(for: delay) }
    return try respond()
  }
  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [ProviderRecord] {
    if let delay { try? await Task.sleep(for: delay) }
    return try respond()
  }
  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work? {
    _ = try respond()
    return .init(workID: id, title: "w", releases: [])
  }
}

@Suite struct LookupRouterTests {
  let barcodeQuery = BarcodeQuery(typeID: "music", code: "724385522925")

  @Test func aFailingSourceDoesntHideTheOthers() async throws {
    let good = ScriptedProvider("a", answer: [record("a:1")])
    let bad = ScriptedProvider("b", failure: .failed("network"))
    let service = LookupRouter(sources: [good, bad])
    let candidates = try await service.barcode(barcodeQuery)
    #expect(candidates.map(\.releaseID) == ["a:1"])
  }

  @Test func whenEverySourceFailsTheLookupIsUnavailableWithTheSoonestRetry() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("a", failure: .busy(retryAfter: 90)),
      ScriptedProvider("b", failure: .circuitOpen(retryAfter: 12)),
    ])
    do {
      _ = try await service.barcode(barcodeQuery)
      Issue.record("expected SourceUnavailable")
    } catch let unavailable as SourceUnavailable {
      #expect(unavailable.retryAfter == 12)
    }
  }

  @Test func answersAreCachedAndFailuresAreNot() async throws {
    let source = ScriptedProvider("a", answer: [record("a:1")])
    let service = LookupRouter(sources: [source])
    _ = try await service.barcode(barcodeQuery)
    _ = try await service.barcode(barcodeQuery)
    #expect(source.calls == 1)

    let failing = ScriptedProvider("b", failure: .failed("network"))
    let other = LookupRouter(sources: [failing])
    _ = try? await other.barcode(barcodeQuery)
    _ = try? await other.barcode(barcodeQuery)
    #expect(failing.calls == 2)
  }

  @Test func aTypeWithoutSourcesAnswersNothingAndIsntListed() async throws {
    let service = LookupRouter(sources: [ScriptedProvider("a")])
    #expect(service.supportedTypes == ["music"])
    #expect(try await service.barcode(.init(typeID: "thing", code: "12345678")).isEmpty)
  }

  @Test func aWorkGoesToTheSourceOwningItsPrefix() async throws {
    let a = ScriptedProvider("a")
    let service = LookupRouter(sources: [a, ScriptedProvider("b", typeID: "video-game")])
    #expect(try await service.work(id: "a:42")?.workID == "a:42")
    #expect(try await service.work(id: "zzz:42") == nil)
    _ = try await service.work(id: "a:42")
    #expect(a.calls == 1)  // cached
  }

  @Test func identifyWithOCRTextSaysSo() async throws {
    let source = RecordingProvider()
    let service = LookupRouter(sources: [source])
    _ = try await service.identify(typeID: "music", .init(text: "\n  OK COMPUTER \nRADIOHEAD\nparlophone\nextra"))
    let asked = try #require(source.queries.first)
    #expect(asked.title == "OK COMPUTER RADIOHEAD parlophone")
    #expect(asked.reason == .ocr)
  }
}

final class RecordingProvider: DataProvider, @unchecked Sendable {
  let name = "rec"
  let typeID = "music"
  let idPrefix = "rec:"
  let answersBarcodes = true
  private let lock = NSLock()
  private var asked: [SearchQuery] = []
  var queries: [SearchQuery] { lock.withLock { asked } }

  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [ProviderRecord] { [] }
  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [ProviderRecord] {
    lock.withLock { asked.append(query) }
    return []
  }
  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work? { nil }
}

@Suite struct ProviderConnectionTests {
  @Test func aProviderSaying429IsBusyWithItsRetryAfter() async throws {
    let connection = testConnection("x", ReplayTransport([("example", status(429, headers: ["retry-after": "17"]))]))
    await #expect(throws: ProviderFailure.busy(retryAfter: 17)) {
      _ = try await connection.exchange(.init(url: URL(string: "https://example.org")!))
    }
  }

  @Test func theBreakerOpensAfterFiveFailuresInARow() async throws {
    let transport = ReplayTransport([("example", status(500))])
    let connection = testConnection("x", transport)
    for _ in 0..<5 { _ = try? await connection.exchange(.init(url: URL(string: "https://example.org")!)) }
    do {
      _ = try await connection.exchange(.init(url: URL(string: "https://example.org")!))
      Issue.record("expected the breaker to be open")
    } catch {
      guard case .circuitOpen = error else { Issue.record("\(error)"); return }
    }
    #expect(transport.sent.count == 5)
  }

  @Test func thePacerRefusesInsteadOfQueueingTooLong() async throws {
    let pacer = Pacer(interval: .seconds(60), maximumWait: .seconds(1))
    try await pacer.acquire()
    await #expect(throws: ProviderFailure.self) { try await pacer.acquire() }
  }

  /// A failure logs the source and a reason code; never the URL, the query or a credential.
  @Test func aFailureLogsNoContent() async throws {
    let capture = LogCapture()
    let transport = ReplayTransport([("example", status(500))])
    let connection = testConnection("screenscraper", transport, logger: capture.logger)
    _ = try? await connection.exchange(
      .init(url: URL(string: "https://example.org/x?recherche=secret+words&devpassword=TEGOLA-TEST-SENTINEL")!)
    )
    let text = capture.text
    #expect(text.contains("screenscraper"))
    #expect(text.contains("http-5xx"))
    #expect(!text.contains("secret"))
    #expect(!text.contains("TEGOLA-TEST-SENTINEL"))
    #expect(!text.contains("example.org"))
  }

  @Test func onlyHTTPSImagesOnExpectedHostsAreKept() {
    let hosts: Set<String> = ["cf.geekdo-images.com"]
    #expect(allowedImageURL("https://cf.geekdo-images.com/a.jpg", hosts: hosts) != nil)
    #expect(allowedImageURL("//cf.geekdo-images.com/a.jpg", hosts: hosts) == "https://cf.geekdo-images.com/a.jpg")
    #expect(allowedImageURL("http://cf.geekdo-images.com/a.jpg", hosts: hosts) == nil)
    #expect(allowedImageURL("https://evil.com/a.jpg", hosts: hosts) == nil)
    #expect(allowedImageURL("https://user:pw@cf.geekdo-images.com/a.jpg", hosts: hosts) == nil)
    #expect(allowedImageURL("https://cf.geekdo-images.com/a.jpg?token=x", hosts: hosts) == nil)
    #expect(allowedImageURL("javascript:alert(1)", hosts: hosts) == nil)
  }
}

@Suite struct TextMatchTests {
  @Test func titlesCompareWithoutCaseAccentsPunctuationOrArticles() {
    #expect(TextMatch.similarity("The Legend of Zelda", "legend of zelda") == 1)
    #expect(TextMatch.similarity("Pokémon Red", "POKEMON red!") == 1)
    #expect(TextMatch.similarity("Simon & Garfunkel", "simon and garfunkel") == 1)
    #expect(TextMatch.similarity("Agricola", "Catan") < 0.3)
    #expect(TextMatch.similarity("Ocarina of Tme", "Ocarina of Time") > 0.8)
  }

  @Test func confidenceCountsOnlyWhatTheQueryGives() {
    #expect(
      TextMatch.confidence(
        title: "x",
        candidateTitle: "x",
        subtitle: nil,
        candidateSubtitle: nil,
        year: nil,
        candidateYear: nil
      ) == 1
    )
    let wrongYear = TextMatch.confidence(
      title: "x",
      candidateTitle: "x",
      subtitle: nil,
      candidateSubtitle: nil,
      year: 1990,
      candidateYear: 2000
    )
    #expect(abs(wrongYear - 0.875) < 0.0001)
  }

  @Test func providerStringsAreCleanedAndCapped() {
    #expect(TextMatch.clean("  a\u{0}b\nc ") == "abc")
    #expect(TextMatch.clean(String(repeating: "x", count: 500))?.count == 300)
    #expect(TextMatch.clean("   ") == nil)
  }
}

@Suite struct SourceSettingsTests {
  @Test func noVariablesMeansNoSources() throws {
    #expect(try SourceSettings.load(from: [:]).isEmpty)
  }

  @Test func eachSourceTurnsOnWithItsVariables() throws {
    let settings = try SourceSettings.load(from: [
      "TEGOLA_MUSICBRAINZ_CONTACT": "https://example.org/contact",
      "TEGOLA_IGDB_CLIENT_ID": "id", "TEGOLA_IGDB_CLIENT_SECRET": "TEGOLA-TEST-SENTINEL",
      "TEGOLA_SCREENSCRAPER_DEV_ID": "dev", "TEGOLA_SCREENSCRAPER_DEV_PASSWORD": "TEGOLA-TEST-SENTINEL",
      "TEGOLA_BGG_TOKEN": "TEGOLA-TEST-SENTINEL",
      "TEGOLA_WIKIDATA_CONTACT": "ops@example.org",
    ])
    #expect(settings.enabled == ["musicbrainz", "igdb", "screenscraper", "boardgamegeek", "wikidata"])
    #expect(!settings.description.contains("TEGOLA-TEST-SENTINEL"))
  }

  @Test(arguments: [
    ["TEGOLA_IGDB_CLIENT_ID": "id"],
    ["TEGOLA_IGDB_CLIENT_SECRET": "secret"],
    ["TEGOLA_SCREENSCRAPER_DEV_ID": "dev"],
    ["TEGOLA_SCREENSCRAPER_USER": "u", "TEGOLA_SCREENSCRAPER_PASSWORD": "p"],
    ["TEGOLA_BGG_TOKEN": "has space"],
    ["TEGOLA_MUSICBRAINZ_CONTACT": "line\nbreak"],
    ["TEGOLA_WIKIDATA_CONTACT": "two words"],
    ["TEGOLA_BGG_TOKEN": String(repeating: "x", count: 257)],
  ])
  func aHalfSetOrUnsafeValueStopsTheServer(_ env: [String: String]) {
    #expect(throws: ConfigurationError.self) { try SourceSettings.load(from: env) }
  }
}

/// The sources behind the real routes: an attested barcode lookup reaches MusicBrainz and answers its candidates.
@Suite struct ProviderRouteTests {
  @Test func aBarcodeLookupAnswersMusicBrainzsCandidates() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzBarcode))])
    let lookups = makeLookupService(
      SourceSettings(musicBrainzContact: "ops@example.com"),
      transport: transport,
      logger: quietLogger
    )
    let server = try TestServer(environment: .development, lookups: lookups)
    try await server.run { client in
      try await client.execute(uri: "/v1/health", method: .get) { response in
        #expect(String(buffer: response.body).contains(#""types":["music"]"#))
      }
      try await client.execute(
        uri: "/v1/types/music/barcodes/724385522925",
        method: .get,
        headers: [.tegolaDebugToken: debugToken]
      ) { response in
        #expect(response.status == .ok)
        let body = String(buffer: response.body)
        #expect(body.contains(#""releaseID":"musicbrainz:release:\#(Fixture.mbRelease)""#))
        #expect(body.contains(#""attribution":"Data from MusicBrainz (CC0)""#))
      }
    }
  }
}

// MARK: - the review's findings (tasks/M3-review.md), each sent as the attack or failure it describes

@Suite struct ProviderReviewTests {
  /// Finding 1: an import row's year can't overflow the ranking. The contract gives it no range, so the row is
  /// answered and its year dropped, not refused (second review).
  @Test func anExtremeYearIsDroppedAndCantOverflowTheRanking() async throws {
    let contract = ContractTests()
    for year in ["-9223372036854775808", "9223372036854775807", "0"] {
      let (status, _) = try await contract.post(
        "/v1/types/video-game/match",
        #"{"items":[{"ref":"r","title":"Zelda","year":\#(year)}]}"#,
        lookups: CannedLookups(candidates: [candidate("x", confidence: 0.9)])
      )
      #expect(status == .ok, "year \(year)")
    }
    let recorder = RecordingProvider()
    let service = LookupRouter(sources: [recorder])
    _ = try await service.match(typeID: "music", .init(ref: "r", title: "x", year: .min))
    #expect(recorder.queries.first?.year == nil)
    let confidence = TextMatch.confidence(
      title: "x",
      candidateTitle: "x",
      subtitle: nil,
      candidateSubtitle: nil,
      year: .min,
      candidateYear: 2000
    )
    #expect(confidence == 1)
  }

  /// Finding 2: one provider failing while the other finds nothing is "try again", not "no match".
  @Test func aFailureBesideAnEmptyAnswerIsUnavailable() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("a", failure: .busy(retryAfter: 40)), ScriptedProvider("b", answer: []),
    ])
    do {
      _ = try await service.barcode(.init(typeID: "music", code: "724385522925"))
      Issue.record("expected SourceUnavailable")
    } catch let unavailable as SourceUnavailable {
      #expect(unavailable.retryAfter == 40)
    }
  }

  /// Finding 3: an error page answered with 200 is a failure, not an empty answer.
  @Test func anErrorPageIsAFailureNotNoMatch() async throws {
    let bgg = BoardGameGeekProvider(
      connection: testConnection(
        "boardgamegeek",
        ReplayTransport([("xmlapi2", ok("<html><body>Down for maintenance</body></html>", contentType: "text/html"))])
      ),
      token: "TEGOLA-TEST-SENTINEL"
    )
    await #expect(throws: ProviderFailure.failed("undecodable")) {
      _ = try await bgg.search(.init(title: "Agricola", limit: 5, reason: .title))
    }
    let screenScraper = ScreenScraperProvider(
      connection: testConnection(
        "screenscraper",
        ReplayTransport([("api.screenscraper.fr", ok(#"{"header":{"success":"false","error":"Erreur"}}"#))])
      ),
      credentials: .init(developerID: "dev", developerPassword: "TEGOLA-TEST-SENTINEL")
    )
    await #expect(throws: ProviderFailure.failed("undecodable")) {
      _ = try await screenScraper.search(.init(title: "Sonic", limit: 5, reason: .title))
    }
  }

  /// Finding 4: a DOCTYPE is refused before parsing, so no entity is ever expanded or fetched.
  @Test(arguments: [
    """
    <?xml version="1.0"?><!DOCTYPE items [<!ENTITY xxe SYSTEM "file:///etc/hostname">]>
    <items><item type="boardgame" id="1"><name type="primary" value="x"/><image>&xxe;</image></item></items>
    """,
    """
    <?xml version="1.0"?><!DOCTYPE items [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
    <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"><!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">]>
    <items><item type="boardgame" id="1"><name type="primary" value="&d;"/></item></items>
    """,
  ])
  func entityDeclarationsAreRefused(_ answer: String) async throws {
    #expect(BoardGameGeekProvider.parse(Data(answer.utf8)) == nil)
    let transport = ReplayTransport([("xmlapi2/search", xml(Fixture.bggSearch)), ("xmlapi2/thing", xml(answer))])
    let bgg = BoardGameGeekProvider(
      connection: testConnection("boardgamegeek", transport),
      token: "TEGOLA-TEST-SENTINEL"
    )
    await #expect(throws: ProviderFailure.failed("undecodable")) {
      _ = try await bgg.search(.init(title: "Agricola", limit: 5, reason: .title))
    }
  }

  /// Finding 5: a redirect is a failure, and nothing is sent to where it points.
  @Test func aRedirectIsNotFollowed() async throws {
    let transport = ReplayTransport([
      ("xmlapi2", status(302, headers: ["location": "http://attacker.example/steal"])), ("attacker", xml("<items/>")),
    ])
    let bgg = BoardGameGeekProvider(
      connection: testConnection("boardgamegeek", transport),
      token: "TEGOLA-TEST-SENTINEL"
    )
    await #expect(throws: ProviderFailure.failed("redirect")) {
      _ = try await bgg.search(.init(title: "Agricola", limit: 5, reason: .title))
    }
    #expect(transport.sent.count == 1)
    #expect(transport.sent.allSatisfy { $0.url.host == "boardgamegeek.com" })
  }

  /// Finding 6: each provider's answer is cut to its best 10 before it's cached.
  @Test func eachProvidersAnswerIsCutToItsBestTen() async throws {
    // Each record's title is a longer start of the words asked, so the later the record, the closer it is.
    let words = "abcdefghijklmnopqrstuvwxyz0123"
    let many = (0..<30).map { record("a:\($0)", title: String(words.prefix($0 + 1))) }
    let provider = ScriptedProvider("a", answer: many)
    let service = LookupRouter(sources: [provider])
    let answer = try await service.match(typeID: "music", .init(ref: "r", title: words))
    #expect(answer.count == 10)
    #expect(answer.first?.releaseID == "a:29")
    #expect(Set(answer.map(\.releaseID)) == Set((20..<30).map { "a:\($0)" }))
    let again = try await service.match(typeID: "music", .init(ref: "r", title: words))
    #expect(provider.calls == 1)  // the ten were cached
    #expect(again == answer)  // and a hit is scored as the miss was
  }

  /// Finding 8: simultaneous first requests share one token fetch.
  @Test func concurrentFirstRequestsFetchOneToken() async throws {
    // The token answers after 200 ms, so the 20 callers really arrive while its fetch is in flight.
    let transport = ReplayTransport(
      [("id.twitch.tv", [ok(Fixture.twitchToken)]), ("api.igdb.com", [ok("[]")])],
      delays: ["id.twitch.tv": .milliseconds(200)]
    )
    let igdb = IGDBProvider(
      connection: testConnection("igdb", transport),
      tokens: TwitchTokens(
        clientID: "client-id",
        clientSecret: "TEGOLA-TEST-SENTINEL-secret",
        connection: testConnection("twitch", transport)
      )
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask { _ = try await igdb.search(.init(title: "game \(index)", limit: 5, reason: .title)) }
      }
      try await group.waitForAll()
    }
    #expect(transport.sent.filter { $0.url.host == "id.twitch.tv" }.count == 1)
  }

  /// Low: any whitespace around a Lucene operator keeps it a word.
  @Test func luceneOperatorsStayWordsAcrossAnyWhitespace() {
    #expect(MusicBrainzProvider.escape("a\tOR\u{3000}b\nNOT c") == "a or b not c")
  }

  /// Low: a "+" in the words reaches the provider as "+", not as a space.
  @Test func aPlusIsEncoded() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(#"{"releases":[]}"#))])
    let provider = MusicBrainzProvider(connection: testConnection("musicbrainz", transport), userAgent: "t")
    _ = try await provider.search(.init(title: "C++", limit: 5, reason: .title))
    let raw = try #require(transport.sent.first?.url.absoluteString)
    #expect(!raw.contains("+"))
    #expect(transport.sent.first.flatMap { query($0, "query") } == #"release:(C\+\+)"#)
  }

  /// Low: a key stored again isn't evicted for its old place in the order.
  @Test func aRefreshedEntryOutlivesOlderOnes() async {
    let cache = AnswerCache<Int>(capacity: 10)
    await cache.store(0, for: "a", lifetime: .seconds(60))
    for index in 1...9 { await cache.store(index, for: "k\(index)", lifetime: .seconds(60)) }
    await cache.store(10, for: "a", lifetime: .seconds(60))
    await cache.store(11, for: "new", lifetime: .seconds(60))
    #expect(await cache.value("a") == 10)
    #expect(await cache.value("k1") == nil)
    #expect(await cache.count == 10)
  }

  /// Low: settings that hold a secret never print it.
  @Test func credentialsNeverPrintTheirSecrets() {
    let igdb = SourceSettings.ClientCredentials(id: "id", secret: "TEGOLA-TEST-SENTINEL")
    let screenScraper = SourceSettings.ScreenScraperSettings(
      developerID: "dev",
      developerPassword: "TEGOLA-TEST-SENTINEL",
      user: "u",
      password: "TEGOLA-TEST-SENTINEL"
    )
    for text in [
      "\(igdb)", "\(screenScraper)", String(describing: SourceSettings(igdb: igdb, screenScraper: screenScraper)),
    ] {
      #expect(!text.contains("TEGOLA-TEST-SENTINEL"))
    }
  }
}

// MARK: - the second review's findings

/// Throws, or answers after a while, as told.
struct StubTransport: HTTPTransport {
  var failure: (any Error)?
  var delay: Duration = .zero

  func send(_ request: OutboundRequest, timeout: Duration, maximumBytes: Int) async throws -> OutboundResponse {
    try await Task.sleep(for: delay)
    if let failure { throw failure }
    return ok("{}")
  }
}

@Suite struct ProviderSecondReviewTests {
  /// A provider that said "busy" is left alone until its Retry-After.
  @Test func aBusyProviderIsLeftAloneUntilItsRetryAfter() async throws {
    let transport = ReplayTransport([("api.screenscraper.fr", status(430))])
    let provider = ScreenScraperProvider(
      connection: testConnection("screenscraper", transport),
      credentials: .init(developerID: "dev", developerPassword: "TEGOLA-TEST-SENTINEL")
    )
    for _ in 0..<3 { _ = try? await provider.search(.init(title: "Sonic", limit: 5, reason: .title)) }
    #expect(transport.sent.count == 1)
  }

  /// One user's too-broad query doesn't close a provider for everyone.
  @Test func anAnswerTooLargeDoesntOpenTheBreaker() async throws {
    let connection = testConnection("x", StubTransport(failure: ProviderFailure.failed("too-large")))
    for _ in 0..<8 {
      await #expect(throws: ProviderFailure.failed("too-large")) {
        _ = try await connection.exchange(.init(url: URL(string: "https://example.org")!))
      }
    }
  }

  /// The whole exchange is bounded, whatever the transport does.
  @Test func aSlowAnswerTimesOut() async throws {
    let connection = ProviderConnection(
      name: "x",
      transport: StubTransport(delay: .seconds(30)),
      interval: .zero,
      timeout: .milliseconds(50),
      logger: quietLogger
    )
    await #expect(throws: ProviderFailure.failed("timeout")) {
      _ = try await connection.exchange(.init(url: URL(string: "https://example.org")!))
    }
  }

  /// After the cool-down, one request probes; the others are still refused until it answers.
  @Test func theHalfOpenBreakerLetsOneProbeThrough() async throws {
    let breaker = CircuitBreaker(threshold: 1, coolDown: .milliseconds(10))
    await breaker.failure()
    try await Task.sleep(for: .milliseconds(30))
    try await breaker.check()
    await #expect(throws: ProviderFailure.circuitOpen(retryAfter: 1)) { try await breaker.check() }
    await breaker.release()
    try await breaker.check()
    await breaker.success()
    try await breaker.check()
    try await breaker.check()
  }

  /// A DOCTYPE in UTF-16 is refused too: only UTF-8 is read.
  @Test func aUTF16AnswerIsRefused() {
    let text = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE items [<!ENTITY x "y">]><items/>"#
    let utf16 = text.data(using: .utf16)!
    #expect(BoardGameGeekProvider.parse(utf16) == nil)
    #expect(BoardGameGeekProvider.parse(Data("<items></items>".utf8))?.isEmpty == true)
  }

  /// A brand-new token that IGDB refuses means wrong credentials: no second Twitch fetch.
  @Test func aRefusedFreshTokenIsNotFetchedAgain() async throws {
    let transport = ReplayTransport([("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", status(401))])
    let igdb = IGDBProvider(
      connection: testConnection("igdb", transport),
      tokens: TwitchTokens(
        clientID: "id",
        clientSecret: "TEGOLA-TEST-SENTINEL",
        connection: testConnection("twitch", transport)
      )
    )
    await #expect(throws: ProviderFailure.unauthorized) {
      _ = try await igdb.search(.init(title: "x", limit: 5, reason: .title))
    }
    #expect(transport.sent.filter { $0.url.host == "id.twitch.tv" }.count == 1)
  }

  /// MusicBrainz's year and subtype rank and filter here, not in its index.
  @Test func musicBrainzFiltersTheSubtypeLocally() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzSearch))])
    let provider = MusicBrainzProvider(connection: testConnection("musicbrainz", transport), userAgent: "t")
    let candidates = try await provider.candidates(
      .init(title: "OK Computer", year: 1997, subtype: "cd", limit: 5, reason: .title)
    )
    #expect(candidates.count == 2)
    let lucene = try #require(transport.sent.first.flatMap { query($0, "query") })
    #expect(lucene == "release:(OK Computer)")
  }
}
