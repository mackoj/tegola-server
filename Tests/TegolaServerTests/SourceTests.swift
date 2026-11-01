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

func query(_ request: OutboundRequest, _ name: String) -> String? {
  URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Suite struct MusicBrainzTests {
  func source(_ transport: ReplayTransport) -> MusicBrainzSource {
    MusicBrainzSource(
      connection: testConnection("musicbrainz", transport),
      userAgent: "tegola-server/1.0 ( ops@example.com )"
    )
  }

  @Test func aBarcodeKeepsOnlyExactHitsAndFillsTheTypeFields() async throws {
    let transport = ReplayTransport([("musicbrainz.org/ws/2/release", ok(Fixture.musicBrainzBarcode))])
    let candidates = try await source(transport).barcode(
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

    let request = try #require(transport.sent.first)
    #expect(query(request, "query") == "barcode:724385522925")
    #expect(request.headers["User-Agent"] == "tegola-server/1.0 ( ops@example.com )")
  }

  @Test func aSubtypeFiltersBarcodeHits() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzBarcode))])
    let candidates = try await source(transport).barcode(.init(typeID: "music", code: "724385522925", subtype: "cd"))
    #expect(candidates.isEmpty)
  }

  @Test func searchRanksByTitleArtistAndYear() async throws {
    let transport = ReplayTransport([("musicbrainz.org", ok(Fixture.musicBrainzSearch))])
    let candidates = try await source(transport).search(
      .init(title: "ok computer", subtitle: "Radiohead", year: 1997, limit: 5, reason: .title)
    )
    #expect(candidates.count == 2)
    #expect(candidates[0].confidence == 1)
    #expect(candidates[1].confidence < candidates[0].confidence)
    #expect(field(candidates[1], "format") == .case1("2×CD"))
    let lucene = try #require(transport.sent.first.flatMap { query($0, "query") })
    #expect(lucene == "release:(ok computer) AND artist:(Radiohead) AND date:1997")
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
  func source(_ transport: ReplayTransport) -> IGDBSource {
    IGDBSource(
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
    let candidates = try await source(transport).search(
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
    let candidates = try await source(transport).search(
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

  @Test func aRefusedTokenIsRenewedOnce() async throws {
    let transport = ReplayTransport([
      ("id.twitch.tv", [ok(Fixture.twitchToken)]), ("api.igdb.com", [status(401), ok(Fixture.igdbGames)]),
    ])
    let candidates = try await source(transport).search(.init(title: "Ocarina of Time", limit: 5, reason: .title))
    #expect(!candidates.isEmpty)
    #expect(transport.sent.filter { $0.url.host == "id.twitch.tv" }.count == 2)
  }

  /// A cover id that isn't an id never becomes a path in an image URL.
  @Test func aCoverIDThatIsntAnIDIsDropped() async throws {
    let games = Fixture.igdbGames.replacingOccurrences(of: "co3nnx", with: "../../evil?x=1")
    let transport = ReplayTransport([("id.twitch.tv", ok(Fixture.twitchToken)), ("api.igdb.com", ok(games))])
    let candidates = try await source(transport).search(.init(title: "Ocarina of Time", limit: 5, reason: .title))
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
  func source(_ transport: ReplayTransport) -> ScreenScraperSource {
    ScreenScraperSource(
      connection: testConnection("screenscraper", transport),
      credentials: .init(developerID: "dev", developerPassword: "TEGOLA-TEST-SENTINEL-dev")
    )
  }

  @Test func searchMakesOneCandidatePerRegionWithoutImages() async throws {
    let transport = ReplayTransport([("api.screenscraper.fr/api2/jeuRecherche.php", ok(Fixture.screenScraperSearch))])
    let candidates = try await source(transport).search(.init(title: "Sonic the Hedgehog", limit: 5, reason: .title))
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
    let candidates = try await source(transport).search(.init(title: "Mario", subtype: "n64", limit: 5, reason: .title))
    #expect(candidates.isEmpty)
    #expect(transport.sent.first.flatMap { query($0, "systemeid") } == "14")
  }

  @Test func theDailyQuotaIsABusySourceForAnHour() async throws {
    let transport = ReplayTransport([("api.screenscraper.fr", status(430))])
    await #expect(throws: SourceFailure.busy(retryAfter: 3600)) {
      _ = try await source(transport).search(.init(title: "Sonic", limit: 5, reason: .title))
    }
  }
}

@Suite struct BoardGameGeekTests {
  func source(_ transport: ReplayTransport) -> BoardGameGeekSource {
    BoardGameGeekSource(connection: testConnection("boardgamegeek", transport), token: "TEGOLA-TEST-SENTINEL-bgg")
  }

  @Test func searchReadsTheBestGamesDetails() async throws {
    let transport = ReplayTransport([
      ("xmlapi2/search", ok(Fixture.bggSearch)), ("xmlapi2/thing", ok(Fixture.bggThing)),
    ])
    let candidates = try await source(transport).search(
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

  /// An external entity in an answer is never resolved: no local file reaches a candidate.
  @Test func anExternalEntityIsNotResolved() async throws {
    let transport = ReplayTransport([
      ("xmlapi2/search", ok(Fixture.bggSearch)), ("xmlapi2/thing", ok(Fixture.bggExternalEntity)),
    ])
    let hostname = (try? String(contentsOfFile: "/etc/hostname", encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = try? await source(transport).search(.init(title: "Agricola", limit: 5, reason: .title))
    for candidate in candidates ?? [] {
      if let hostname, !hostname.isEmpty { #expect(!candidate.title.contains(hostname)) }
    }
  }

  @Test func playersReadsLikeTheTypeFile() {
    #expect(BoardGameGeekSource.players(minimum: 2, maximum: 4) == "2–4")
    #expect(BoardGameGeekSource.players(minimum: 2, maximum: 2) == "2")
    #expect(BoardGameGeekSource.players(minimum: 0, maximum: 0) == nil)
  }
}

/// A source that answers or fails as told, and counts its calls.
final class ScriptedSource: CatalogueSource, @unchecked Sendable {
  let name: String
  let typeID: String
  let idPrefix: String
  let answersBarcodes = true
  var failure: SourceFailure?
  var answer: [Components.Schemas.Candidate]
  private let lock = NSLock()
  private var count = 0

  init(
    _ name: String,
    typeID: String = "music",
    answer: [Components.Schemas.Candidate] = [],
    failure: SourceFailure? = nil
  ) {
    self.name = name
    self.typeID = typeID
    self.idPrefix = "\(name):"
    self.answer = answer
    self.failure = failure
  }

  var calls: Int { lock.withLock { count } }

  func respond() throws(SourceFailure) -> [Components.Schemas.Candidate] {
    lock.withLock { count += 1 }
    if let failure { throw failure }
    return answer
  }

  func barcode(_ query: BarcodeQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] { try respond() }
  func search(_ query: SourceQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] { try respond() }
  func work(id: String) async throws(SourceFailure) -> Components.Schemas.Work? {
    _ = try respond()
    return .init(workID: id, title: "w", releases: [])
  }
}

@Suite struct SourcesLookupServiceTests {
  let barcodeQuery = BarcodeQuery(typeID: "music", code: "724385522925")

  @Test func aFailingSourceDoesntHideTheOthers() async throws {
    let good = ScriptedSource("a", answer: [candidate("a:1", confidence: 0.9)])
    let bad = ScriptedSource("b", failure: .failed("network"))
    let service = SourcesLookupService(sources: [good, bad])
    let candidates = try await service.barcode(barcodeQuery)
    #expect(candidates.map(\.releaseID) == ["a:1"])
  }

  @Test func whenEverySourceFailsTheLookupIsUnavailableWithTheSoonestRetry() async throws {
    let service = SourcesLookupService(sources: [
      ScriptedSource("a", failure: .busy(retryAfter: 90)), ScriptedSource("b", failure: .circuitOpen(retryAfter: 12)),
    ])
    do {
      _ = try await service.barcode(barcodeQuery)
      Issue.record("expected SourceUnavailable")
    } catch let unavailable as SourceUnavailable {
      #expect(unavailable.retryAfter == 12)
    }
  }

  @Test func answersAreCachedAndFailuresAreNot() async throws {
    let source = ScriptedSource("a", answer: [candidate("a:1", confidence: 0.9)])
    let service = SourcesLookupService(sources: [source])
    _ = try await service.barcode(barcodeQuery)
    _ = try await service.barcode(barcodeQuery)
    #expect(source.calls == 1)

    let failing = ScriptedSource("b", failure: .failed("network"))
    let other = SourcesLookupService(sources: [failing])
    _ = try? await other.barcode(barcodeQuery)
    _ = try? await other.barcode(barcodeQuery)
    #expect(failing.calls == 2)
  }

  @Test func aTypeWithoutSourcesAnswersNothingAndIsntListed() async throws {
    let service = SourcesLookupService(sources: [ScriptedSource("a")])
    #expect(service.supportedTypes == ["music"])
    #expect(try await service.barcode(.init(typeID: "thing", code: "12345678")).isEmpty)
  }

  @Test func aWorkGoesToTheSourceOwningItsPrefix() async throws {
    let a = ScriptedSource("a")
    let service = SourcesLookupService(sources: [a, ScriptedSource("b", typeID: "video-game")])
    #expect(try await service.work(id: "a:42")?.workID == "a:42")
    #expect(try await service.work(id: "zzz:42") == nil)
    _ = try await service.work(id: "a:42")
    #expect(a.calls == 1)  // cached
  }

  @Test func searchWithOCRTextSaysSo() async throws {
    let source = RecordingSource()
    let service = SourcesLookupService(sources: [source])
    _ = try await service.search(typeID: "music", .init(text: "\n  OK COMPUTER \nRADIOHEAD\nparlophone\nextra"))
    let asked = try #require(source.queries.first)
    #expect(asked.title == "OK COMPUTER RADIOHEAD parlophone")
    #expect(asked.reason == .ocr)
  }
}

final class RecordingSource: CatalogueSource, @unchecked Sendable {
  let name = "rec"
  let typeID = "music"
  let idPrefix = "rec:"
  let answersBarcodes = true
  private let lock = NSLock()
  private var asked: [SourceQuery] = []
  var queries: [SourceQuery] { lock.withLock { asked } }

  func barcode(_ query: BarcodeQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] { [] }
  func search(_ query: SourceQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] {
    lock.withLock { asked.append(query) }
    return []
  }
  func work(id: String) async throws(SourceFailure) -> Components.Schemas.Work? { nil }
}

@Suite struct SourceConnectionTests {
  @Test func aProviderSaying429IsBusyWithItsRetryAfter() async throws {
    let connection = testConnection("x", ReplayTransport([("example", status(429, headers: ["retry-after": "17"]))]))
    await #expect(throws: SourceFailure.busy(retryAfter: 17)) {
      _ = try await connection.send(.init(url: URL(string: "https://example.org")!))
    }
  }

  @Test func theBreakerOpensAfterFiveFailuresInARow() async throws {
    let transport = ReplayTransport([("example", status(500))])
    let connection = testConnection("x", transport)
    for _ in 0..<5 { _ = try? await connection.send(.init(url: URL(string: "https://example.org")!)) }
    do {
      _ = try await connection.send(.init(url: URL(string: "https://example.org")!))
      Issue.record("expected the breaker to be open")
    } catch {
      guard case .circuitOpen = error else { Issue.record("\(error)"); return }
    }
    #expect(transport.sent.count == 5)
  }

  @Test func thePacerRefusesInsteadOfQueueingTooLong() async throws {
    let pacer = Pacer(interval: .seconds(60), maximumWait: .seconds(1))
    try await pacer.acquire()
    await #expect(throws: SourceFailure.self) { try await pacer.acquire() }
  }

  /// A failure logs the source and a reason code; never the URL, the query or a credential.
  @Test func aFailureLogsNoContent() async throws {
    let capture = LogCapture()
    let transport = ReplayTransport([("example", status(500))])
    let connection = testConnection("screenscraper", transport, logger: capture.logger)
    _ = try? await connection.send(
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
    ])
    #expect(settings.enabled == ["musicbrainz", "igdb", "screenscraper", "boardgamegeek"])
    #expect(!settings.description.contains("TEGOLA-TEST-SENTINEL"))
  }

  @Test(arguments: [
    ["TEGOLA_IGDB_CLIENT_ID": "id"],
    ["TEGOLA_IGDB_CLIENT_SECRET": "secret"],
    ["TEGOLA_SCREENSCRAPER_DEV_ID": "dev"],
    ["TEGOLA_SCREENSCRAPER_USER": "u", "TEGOLA_SCREENSCRAPER_PASSWORD": "p"],
    ["TEGOLA_BGG_TOKEN": "has space"],
    ["TEGOLA_MUSICBRAINZ_CONTACT": "line\nbreak"],
    ["TEGOLA_BGG_TOKEN": String(repeating: "x", count: 257)],
  ])
  func aHalfSetOrUnsafeValueStopsTheServer(_ env: [String: String]) {
    #expect(throws: ConfigurationError.self) { try SourceSettings.load(from: env) }
  }
}

/// The sources behind the real routes: an attested barcode lookup reaches MusicBrainz and answers its candidates.
@Suite struct SourceRouteTests {
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
