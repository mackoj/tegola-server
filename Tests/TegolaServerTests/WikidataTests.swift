import Foundation
import Testing

@testable import TegolaServer

// Wikidata's answers, hand-written from the Action API's documented format (format version 1), like the other
// providers' fixtures: this environment can't reach the provider. The ids are illustrative.
extension Fixture {
  static func wdItem(_ id: String) -> String {
    #"{"mainsnak":{"snaktype":"value","datavalue":{"value":{"entity-type":"item","numeric-id":1,"id":"\#(id)"},"type":"wikibase-entityid"},"datatype":"wikibase-item"},"type":"statement","rank":"normal"}"#
  }

  static func wdTime(_ time: String, rank: String = "normal") -> String {
    #"{"mainsnak":{"snaktype":"value","datavalue":{"value":{"time":"\#(time)","timezone":0,"precision":11,"calendarmodel":"http://www.wikidata.org/entity/Q1985727"},"type":"time"}},"type":"statement","rank":"\#(rank)"}"#
  }

  static func wdString(_ value: String) -> String {
    #"{"mainsnak":{"snaktype":"value","datavalue":{"value":"\#(value)","type":"string"}},"type":"statement","rank":"normal"}"#
  }

  /// `action=wbsearchentities`: the toy, a disambiguation page of the same name, an id that's gone, and junk.
  static let wikidataSearch = """
    {"searchinfo":{"search":"tamagotchi"},"search":[
      {"id":"Q193295","title":"Q193295","label":"Tamagotchi","description":"handheld digital pet"},
      {"id":"Q4000001","label":"Tamagotchi","description":"Wikimedia disambiguation page"},
      {"id":"Q4000002","label":"Tamagotchi Angel"},
      {"id":"P31","label":"instance of"},
      {"id":"Q193295","label":"Tamagotchi"}
    ],"success":1}
    """

  /// `action=wbgetentities` with claims: a population count and a quantity the server doesn't read, a deprecated
  /// inception it must ignore.
  static let wikidataEntities = """
    {"entities":{
      "Q193295":{"type":"item","id":"Q193295",
        "labels":{"en":{"language":"en","value":"Tamagotchi"}},
        "descriptions":{"en":{"language":"en","value":"handheld digital pet"}},
        "claims":{
          "P31":[\(wdItem("Q11422"))],
          "P176":[\(wdItem("Q1047439"))],
          "P571":[\(wdTime("+1996-11-23T00:00:00Z")),\(wdTime("+1990-01-01T00:00:00Z", rank: "deprecated"))],
          "P3962":[\(wdString("4543112000013"))],
          "P2067":[{"mainsnak":{"snaktype":"value","datavalue":{"value":{"amount":"+0.05","unit":"x"},"type":"quantity"}},"rank":"normal"}],
          "P1448":[{"mainsnak":{"snaktype":"somevalue"},"rank":"normal"}]
        }},
      "Q4000001":{"type":"item","id":"Q4000001","labels":{"en":{"language":"en","value":"Tamagotchi"}},
        "claims":{"P31":[\(wdItem("Q4167410"))]}},
      "Q4000002":{"id":"Q4000002","missing":""}
    }}
    """

  /// `action=wbgetentities&props=labels`: the subtitle's item.
  static let wikidataLabels = """
    {"entities":{"Q1047439":{"type":"item","id":"Q1047439","labels":{"en":{"language":"en","value":"Bandai"}}}}}
    """

  /// `action=query&list=search` with `haswbstatement:P3962=…`.
  static let wikidataBarcodeHits = """
    {"batchcomplete":"","query":{"searchinfo":{"totalhits":1},"search":[
      {"ns":0,"title":"Q193295","pageid":186000,"size":1,"wordcount":0,"snippet":"","timestamp":"2026-01-01T00:00:00Z"}
    ]}}
    """

  /// An album, for the music profile.
  static let wikidataAlbum = """
    {"entities":{"Q213710":{"type":"item","id":"Q213710",
      "labels":{"en":{"language":"en","value":"OK Computer"}},
      "claims":{"P31":[\(wdItem("Q208569"))],"P175":[\(wdItem("Q44190"))],
        "P577":[\(wdTime("+1997-06-16T00:00:00Z")),\(wdTime("+1997-05-21T00:00:00Z"))]}}}}
    """
}

@Suite struct WikidataTests {
  func source(_ transport: ReplayTransport, _ profile: WikidataProfile = .thing) -> WikidataProvider {
    WikidataProvider(
      profile: profile,
      connection: testConnection("wikidata", transport),
      userAgent: "tegola-server/1.0 ( ops@example.com )"
    )
  }

  @Test func wordsFindItemsOfTheTypeWithTheirMakerAndYear() async throws {
    let transport = ReplayTransport([
      ("action=wbsearchentities", [ok(Fixture.wikidataSearch)]),
      ("action=wbgetentities", [ok(Fixture.wikidataEntities), ok(Fixture.wikidataLabels)]),
    ])
    let candidates = try await source(transport).candidates(
      .init(title: "Tamagotchi", subtitle: "Bandai", limit: 5, reason: .title)
    )
    // The disambiguation page isn't a thing, the missing id is gone, the property id never reaches Wikidata.
    #expect(candidates.map(\.releaseID) == ["wikidata:Q193295"])
    let candidate = try #require(candidates.first)
    #expect(candidate.typeID == "thing")
    #expect(candidate.title == "Tamagotchi")
    #expect(candidate.subtitle == "Bandai")
    #expect(candidate.year == 1996)  // the deprecated 1990 is ignored
    #expect(candidate.subtype == nil && candidate.workID == nil && candidate.images == nil)
    #expect(candidate.confidence == WikidataProfile.thing.weight)
    #expect(candidate.reasons.map(\.kind) == [.title])
    #expect(candidate.sources.first?.url == "https://www.wikidata.org/wiki/Q193295")
    #expect(candidate.sources.first?.attribution == "Data from Wikidata (CC0)")
    #expect(candidate.externalIDs?.additionalProperties == ["wikidata": "Q193295"])

    #expect(transport.sent.count == 3)
    let ids = try #require(transport.sent.dropFirst().first.flatMap { query($0, "ids") })
    #expect(ids == "Q193295|Q4000001|Q4000002")
    #expect(transport.sent.last.flatMap { query($0, "ids") } == "Q1047439")
    #expect(transport.sent.allSatisfy { $0.headers["User-Agent"] == "tegola-server/1.0 ( ops@example.com )" })
    #expect(transport.sent.allSatisfy { $0.url.host == "www.wikidata.org" })
  }

  @Test func anotherTypesProfileKeepsOnlyItsClasses() async throws {
    let transport = ReplayTransport([
      ("action=wbsearchentities", [ok(Fixture.wikidataSearch)]),
      ("action=wbgetentities", [ok(Fixture.wikidataEntities)]),
    ])
    // A toy isn't a board game: nothing comes back, and no label request is made.
    let candidates = try await source(transport, .boardGame).candidates(
      .init(title: "Tamagotchi", limit: 5, reason: .title)
    )
    #expect(candidates.isEmpty)
    #expect(transport.sent.count == 2)
  }

  @Test func musicTakesItsArtistFromThePerformerAndItsEarliestDate() async throws {
    let transport = ReplayTransport([
      ("action=wbsearchentities", [ok(#"{"search":[{"id":"Q213710","label":"OK Computer"}]}"#)]),
      (
        "action=wbgetentities",
        [
          ok(Fixture.wikidataAlbum),
          ok(#"{"entities":{"Q44190":{"id":"Q44190","labels":{"en":{"value":"Radiohead"}}}}}"#),
        ]
      ),
    ])
    let provider = source(transport, .music)
    #expect(provider.tier == .fallback)
    let candidate = try #require(
      try await provider.candidates(
        .init(title: "OK Computer", subtitle: "Radiohead", year: 1997, limit: 5, reason: .ocr)
      )
      .first
    )
    #expect(candidate.typeID == "music")
    #expect(candidate.subtitle == "Radiohead")
    #expect(candidate.year == 1997)
    #expect(candidate.confidence == WikidataProfile.music.weight)
    #expect(candidate.reasons.map(\.kind) == [.ocr])
  }

  /// Only an exact GTIN counts; a UPC-A scan is also asked as the EAN-13 it reads as with a leading zero.
  @Test func aBarcodeFindsTheItemCarryingThatGTIN() async throws {
    let transport = ReplayTransport([
      ("action=query", [ok(Fixture.wikidataBarcodeHits)]),
      ("action=wbgetentities", [ok(Fixture.wikidataEntities), ok(Fixture.wikidataLabels)]),
    ])
    let candidates = try await source(transport).candidates(.init(typeID: "thing", code: "4543112000013"))
    #expect(candidates.map(\.releaseID) == ["wikidata:Q193295"])
    #expect(candidates.first?.confidence == 0.9)
    #expect(candidates.first?.reasons.map(\.kind) == [.barcode])
    #expect(transport.sent.first.flatMap { query($0, "srsearch") } == "haswbstatement:P3962=4543112000013")

    let upc = ReplayTransport([
      ("action=query", [ok(Fixture.wikidataBarcodeHits)]),
      ("action=wbgetentities", [ok(Fixture.wikidataEntities), ok(Fixture.wikidataLabels)]),
    ])
    let byUPC = try await source(upc).candidates(.init(typeID: "thing", code: "543112000013"))
    #expect(byUPC.isEmpty)  // 0543112000013 is not 4543112000013
    #expect(upc.sent.first.flatMap { query($0, "srsearch") } == "haswbstatement:P3962=543112000013|P3962=0543112000013")
  }

  /// A code that isn't a GTIN's digits never reaches the search: nothing can be added to the query.
  @Test func aMalformedBarcodeSendsNothing() async throws {
    let transport = ReplayTransport([("wikidata.org", ok(Fixture.wikidataBarcodeHits))])
    for code in ["12345", "4543112000013 OR haswbstatement:P31=Q5", "45431120000|3", ""] {
      #expect(try await source(transport).barcode(.init(typeID: "thing", code: code)).isEmpty)
    }
    #expect(transport.sent.isEmpty)
  }

  /// The Action API answers its errors with a 200: that's a failure, not "no match".
  @Test func anAPIErrorIsAFailure() async throws {
    let transport = ReplayTransport([
      ("wikidata.org", ok(#"{"error":{"code":"maxlag","info":"Waiting for a database server"},"servedby":"mw1"}"#))
    ])
    await #expect(throws: ProviderFailure.failed("api-error")) {
      _ = try await source(transport).search(.init(title: "Tamagotchi", limit: 5, reason: .title))
    }
  }

  @Test func itemIDsAreQAndDigitsOnly() {
    #expect(WikidataProvider.itemID("Q42") == "Q42")
    for bad in ["Q", "Q0", "Q042", "P31", "q42", "Q42|Q43", "Q42&x=1", "Q1234567890123", "Q４２"] {
      #expect(WikidataProvider.itemID(bad) == nil)
    }
  }

  /// With the contact set, Wikidata answers for `thing` and backs up the other types, on one connection.
  @Test func theSettingTurnsOnEveryProfile() {
    let service = makeLookupService(
      SourceSettings(wikidataContact: "ops@example.com"),
      transport: ReplayTransport([(String, OutboundResponse)]()),
      logger: quietLogger
    )
    #expect(service.supportedTypes == ["board-games", "music", "thing", "video-game"])
    #expect(service.sources["thing"]?.map(\.tier) == [.primary])
    #expect(service.sources["music"]?.map(\.tier) == [.fallback])
  }
}

/// The tiers (D-26): a fallback is asked only when the primary providers found nothing.
@Suite struct ProviderTierTests {
  let query = BarcodeQuery(typeID: "music", code: "724385522925")

  @Test func aFallbackIsntAskedWhenAPrimaryFindsSomething() async throws {
    let primary = ScriptedProvider("a", answer: [record("a:1")])
    let fallback = ScriptedProvider("w", tier: .fallback, answer: [record("w:1")])
    let service = LookupRouter(sources: [fallback, primary])
    #expect(try await service.barcode(query).map(\.releaseID) == ["a:1"])
    #expect(try await service.match(typeID: "music", .init(ref: "r", title: "x")).map(\.releaseID) == ["a:1"])
    #expect(fallback.calls == 0)
  }

  @Test func aFallbackAnswersWhenThePrimariesFindNothing() async throws {
    let primary = ScriptedProvider("a", answer: [])
    let fallback = ScriptedProvider("w", tier: .fallback, answer: [record("w:1")])
    let service = LookupRouter(sources: [primary, fallback])
    #expect(try await service.barcode(query).map(\.releaseID) == ["w:1"])
    #expect(try await service.identify(typeID: "music", .init(title: "x")).map(\.releaseID) == ["w:1"])
  }

  @Test func aFallbackAnswersWhenThePrimariesFail() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("a", failure: .busy(retryAfter: 60)),
      ScriptedProvider("w", tier: .fallback, answer: [record("w:1")]),
    ])
    #expect(try await service.barcode(query).map(\.releaseID) == ["w:1"])
  }

  /// A fallback's "no match" can't stand for a primary that couldn't answer: that's still "try again".
  @Test func aFailedPrimaryAndAnEmptyFallbackIsUnavailable() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("a", failure: .busy(retryAfter: 60)),
      ScriptedProvider("w", tier: .fallback, answer: []),
    ])
    do {
      _ = try await service.barcode(query)
      Issue.record("expected SourceUnavailable")
    } catch let unavailable as SourceUnavailable {
      #expect(unavailable.retryAfter == 60)
    }
  }

  @Test func nothingAnywhereWithoutFailuresIsNoMatch() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("a"), ScriptedProvider("w", tier: .fallback),
    ])
    #expect(try await service.barcode(query).isEmpty)
  }

  /// Identify's two halves are one tier: a barcode the primary found keeps the fallback's words out.
  @Test func identifyStopsAtTheTierWhereEitherHalfFoundSomething() async throws {
    let primary = BarcodeOnlyProvider(answer: [record("a:1")])
    let fallback = ScriptedProvider("w", tier: .fallback, answer: [record("w:1")])
    let service = LookupRouter(sources: [primary, fallback])
    let candidates = try await service.identify(
      typeID: "music",
      .init(title: "OK Computer", barcode: .init(code: "724385522925"))
    )
    #expect(candidates.map(\.releaseID) == ["a:1"])
    #expect(fallback.calls == 0)
  }

  /// A type with only a fallback is still a type the server answers for.
  @Test func aTypeWithOnlyAFallbackIsListedAndAnswered() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("w", typeID: "board-games", tier: .fallback, answer: [record("w:1", typeID: "board-games")])
    ])
    #expect(service.supportedTypes == ["board-games"])
    #expect(try await service.match(typeID: "board-games", .init(ref: "r", title: "x")).map(\.releaseID) == ["w:1"])
  }
}

/// Finds by barcode, never by words.
final class BarcodeOnlyProvider: DataProvider, @unchecked Sendable {
  let name = "a"
  let typeID = "music"
  let idPrefix = "a:"
  let answersBarcodes = true
  let answer: [ProviderRecord]

  init(answer: [ProviderRecord]) { self.answer = answer }

  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [ProviderRecord] { answer }
  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [ProviderRecord] { [] }
  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work? { nil }
}
