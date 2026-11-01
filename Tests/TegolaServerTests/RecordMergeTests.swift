import Foundation
import Testing

@testable import TegolaServer

// The router's half of D-27: providers hand in records, the router scores them one way and merges the ones that
// certainly name the same release.

/// A video game's release as a provider would hand it in.
func game(
  _ id: String,
  typeID: String = "video-game",
  title: String = "Super Mario 64",
  subtype: String? = "n64",
  region: String? = "eu",
  year: Int? = 1997,
  fields: [String: String] = [:],
  ids: [String: String] = [:],
  identifying: Set<String> = []
) -> ProviderRecord {
  let provider = String(id.prefix { $0 != ":" })
  return ProviderRecord(
    provider: provider,
    releaseID: id,
    typeID: typeID,
    subtype: subtype,
    title: title,
    year: year,
    region: region,
    fields: fields.mapValues { .case1($0) },
    externalIDs: ids.isEmpty ? [provider: String(id.drop { $0 != ":" }.dropFirst())] : ids,
    identifying: identifying,
    source: .init(name: provider)
  )
}

func scored(_ record: ProviderRecord, _ confidence: Double = 0.8) -> ScoredRecord {
  ScoredRecord(record: record, confidence: confidence, reasons: [.title])
}

@Suite struct RecordMergeTests {
  let order = ["igdb", "screenscraper", "wikidata"]

  @Test func oneReleaseFromTwoProvidersIsOneCandidate() throws {
    let candidates = RecordMerge.candidates(
      [
        scored(game("screenscraper:7:eu", fields: ["publisher": "Nintendo", "platform": "N64"]), 0.9),
        scored(game("igdb:1", fields: ["platform": "Nintendo 64"]), 0.7),
      ],
      order: order
    )
    let candidate = try #require(candidates.first)
    #expect(candidates.count == 1)
    // The configured order leads, whoever answered first or scored higher.
    #expect(candidate.releaseID == "igdb:1")
    #expect(candidate.confidence == 0.9)
    #expect(candidate.sources.map(\.name) == ["igdb", "screenscraper"])
    #expect(field(candidate, "platform") == .case1("Nintendo 64"))
    #expect(field(candidate, "publisher") == .case1("Nintendo"))
    #expect(candidate.externalIDs?.additionalProperties == ["igdb": "1", "screenscraper": "7:eu"])
  }

  @Test func aSimilarTitleIsNeverEnough() {
    let candidates = RecordMerge.candidates(
      [scored(game("igdb:1")), scored(game("screenscraper:7", title: "Super Mario 64 DS"))],
      order: order
    )
    #expect(candidates.count == 2)
  }

  @Test(arguments: [
    game("screenscraper:7", region: nil), game("screenscraper:7", year: nil), game("screenscraper:7", subtype: nil),
    game("screenscraper:7", region: "jp"), game("screenscraper:7", year: 1996),
  ])
  func theEditionKeyNeedsEveryPartAndAllOfThemEqual(other: ProviderRecord) {
    #expect(RecordMerge.candidates([scored(game("igdb:1")), scored(other)], order: order).count == 2)
  }

  @Test func aSharedReleaseIDMergesWhateverTheTitles() throws {
    let candidates = RecordMerge.candidates(
      [
        scored(game("igdb:1", title: "Mario 64", year: nil, ids: ["igdb": "1", "r": "7"], identifying: ["r"])),
        scored(game("wikidata:Q1", subtype: nil, ids: ["wikidata": "Q1", "r": "7"], identifying: ["r"])),
      ],
      order: order
    )
    #expect(candidates.count == 1)
    #expect(
      try #require(candidates.first).externalIDs?.additionalProperties == ["igdb": "1", "r": "7", "wikidata": "Q1"]
    )
  }

  /// IGDB's id names the game, which every platform's release shares: an item carrying it isn't this release.
  @Test func aWorkLevelIDIsntProofOfARelease() {
    let candidates = RecordMerge.candidates(
      [
        scored(game("igdb:1", ids: ["igdb": "1"])),
        scored(game("wikidata:Q1", title: "Mario 64", ids: ["wikidata": "Q1", "igdb": "1"])),
      ],
      order: order
    )
    #expect(candidates.count == 2)
  }

  @Test func recordsThatDisagreeOnAnIDAreTwoReleases() {
    let candidates = RecordMerge.candidates(
      [
        scored(game("igdb:1", ids: ["igdb": "1"])),
        scored(game("wikidata:Q1", ids: ["wikidata": "Q1", "igdb": "2"])),
      ],
      order: order
    )
    #expect(candidates.count == 2)
  }

  /// A record that could be either of two records of another provider stays on its own.
  @Test func aLinkMustBeOneToOne() {
    let candidates = RecordMerge.candidates(
      [
        scored(game("igdb:1:n64", ids: ["igdb": "1", "r": "1"], identifying: ["r"])),
        scored(game("igdb:1:ds", subtype: "ds", ids: ["igdb": "1", "r": "1"], identifying: ["r"])),
        scored(game("wikidata:Q1", subtype: nil, ids: ["wikidata": "Q1", "r": "1"], identifying: ["r"])),
      ],
      order: order
    )
    #expect(candidates.count == 3)
  }

  @Test func oneProvidersRecordsNeverMerge() {
    let candidates = RecordMerge.candidates(
      [scored(game("igdb:1", ids: ["igdb": "1"])), scored(game("igdb:2", ids: ["igdb": "2"]))],
      order: order
    )
    #expect(candidates.count == 2)
  }

  /// Merging is transitive only while a candidate holds one record per provider.
  @Test func aCandidateNeverHoldsTwoRecordsOfOneProvider() throws {
    // A chain of one-to-one links, igdb:1 – screenscraper:7 – wikidata:Q1 – igdb:2, by ids only (no edition key:
    // the titles differ and there's no year). The last link would put two igdb records together, so it's refused.
    let chain: Set<String> = ["x", "y", "z"]
    let candidates = RecordMerge.candidates(
      [
        scored(game("igdb:1", title: "A", year: nil, ids: ["igdb": "1", "x": "a"], identifying: chain)),
        scored(
          game(
            "screenscraper:7",
            title: "B",
            year: nil,
            ids: ["screenscraper": "7", "x": "a", "y": "b"],
            identifying: chain
          )
        ),
        scored(
          game("wikidata:Q1", title: "C", year: nil, ids: ["wikidata": "Q1", "y": "b", "z": "c"], identifying: chain)
        ),
        scored(game("igdb:2", title: "D", year: nil, ids: ["igdb": "2", "z": "c"], identifying: chain)),
      ],
      order: order
    )
    #expect(candidates.count == 2)
    let merged = try #require(candidates.first { $0.sources.count > 1 })
    #expect(merged.releaseID == "igdb:1")
    #expect(merged.sources.map(\.name) == ["igdb", "screenscraper", "wikidata"])
  }

  /// Links are checked in pairs; a chain still never joins two records that disagree on an id.
  @Test func aChainNeverJoinsRecordsThatDisagreeOnAnID() throws {
    let candidates = RecordMerge.candidates(
      [
        scored(game("igdb:1", title: "A", year: nil, ids: ["igdb": "1", "x": "a"], identifying: ["x"])),
        scored(game("screenscraper:7", title: "B", year: nil, ids: ["x": "a", "y": "b"], identifying: ["x", "y"])),
        scored(game("wikidata:Q1", title: "C", year: nil, ids: ["y": "b", "igdb": "9"], identifying: ["y"])),
      ],
      order: order
    )
    #expect(candidates.count == 2)
    let alone = try #require(candidates.first { $0.releaseID == "wikidata:Q1" })
    #expect(alone.externalIDs?.additionalProperties["igdb"] == "9")
  }

  @Test func theSameRecordFoundTwiceIsOneWithBothReasons() throws {
    let byCode = ScoredRecord(record: game("igdb:1"), confidence: 0.95, reasons: [.barcode])
    let byWords = ScoredRecord(record: game("igdb:1"), confidence: 0.6, reasons: [.title, .subtype])
    let candidate = try #require(RecordMerge.candidates([byCode, byWords], order: order).first)
    #expect(candidate.confidence == 0.95)
    #expect(candidate.reasons.map(\.kind) == [.barcode, .title, .subtype])
  }

  @Test func candidatesComeBestFirst() {
    let candidates = RecordMerge.candidates(
      [scored(game("igdb:1", year: 1990), 0.4), scored(game("igdb:2", year: 1991), 0.9)],
      order: order
    )
    #expect(candidates.map(\.releaseID) == ["igdb:2", "igdb:1"])
  }

  /// The fix the merge brings to imports (D-13): one release from two providers is `matched`, not `ambiguous`.
  @Test func anImportRowTwoProvidersFoundIsMatched() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("igdb", typeID: "video-game", answer: [game("igdb:1")]),
      ScriptedProvider("screenscraper", typeID: "video-game", answer: [game("screenscraper:7")]),
    ])
    let candidates = try await service.match(typeID: "video-game", .init(ref: "r", title: "Super Mario 64"))
    #expect(candidates.count == 1)
    #expect(candidates.first?.sources.map(\.name) == ["igdb", "screenscraper"])
    #expect(LookupAPI.bucket(candidates).0 == .matched)
  }

  /// A provider speaks only for itself and its type: a record naming another is dropped.
  @Test func aRecordForAnotherProviderOrTypeIsDropped() async throws {
    let service = LookupRouter(sources: [
      ScriptedProvider("igdb", typeID: "video-game", answer: [game("screenscraper:7"), game("igdb:1")]),
      ScriptedProvider("a", answer: [record("a:1", typeID: "video-game"), record("a:2")]),
    ])
    let games = try await service.match(typeID: "video-game", .init(ref: "r", title: "Super Mario 64"))
    #expect(games.map(\.releaseID) == ["igdb:1"])
    let music = try await service.match(typeID: "music", .init(ref: "r", title: "a:2"))
    #expect(music.map(\.releaseID) == ["a:2"])
  }
}

/// The router's side of the merge.
@Suite struct RouterMergeTests {
  @Test func theConfiguredFirstLeadsWhoeverAnswersFirst() async throws {
    let igdb = ScriptedProvider("igdb", typeID: "video-game", answer: [game("igdb:1")])
    igdb.delay = .milliseconds(200)
    let service = LookupRouter(sources: [
      igdb, ScriptedProvider("screenscraper", typeID: "video-game", answer: [game("screenscraper:7")]),
    ])
    let candidates = try await service.match(typeID: "video-game", .init(ref: "r", title: "Super Mario 64"))
    #expect(candidates.map(\.releaseID) == ["igdb:1"])
  }

  /// Identify asks one provider by barcode and another by words; the same release is one candidate.
  @Test func oneProvidersBarcodeAndAnothersWordsMerge() async throws {
    let service = LookupRouter(sources: [
      BarcodeOnlyProvider(answer: [game("a:1", typeID: "music")]),
      ScriptedProvider("b", answersBarcodes: false, answer: [game("b:1", typeID: "music")]),
    ])
    let candidates = try await service.identify(
      typeID: "music",
      .init(title: "Super Mario 64", barcode: .init(code: "724385522925"))
    )
    let candidate = try #require(candidates.first)
    #expect(candidates.count == 1)
    #expect(candidate.releaseID == "a:1")
    #expect(candidate.reasons.map(\.kind) == [.barcode, .title])
    #expect(candidate.sources.map(\.name) == ["a", "b"])
  }

  /// A provider speaks only for itself: a record with another provider's id prefix, or another type, is dropped.
  @Test func aBarcodeRecordWithAnotherPrefixOrTypeIsDropped() async throws {
    var foreign = record("a:9")
    foreign.releaseID = "zzz:1"
    let service = LookupRouter(sources: [
      ScriptedProvider("a", answer: [record("a:1"), record("a:2", typeID: "video-game"), foreign])
    ])
    #expect(try await service.barcode(.init(typeID: "music", code: "724385522925")).map(\.releaseID) == ["a:1"])
  }

  /// Words that fold to nothing are ranked as words, no words by the source's relevance: two answers, two keys.
  @Test func noWordsAndWordsThatFoldToNothingAreCachedApart() {
    let blank = SearchQuery(title: "", catalogueNumber: "CDP 7243", limit: 5, reason: .title)
    var punctuation = blank
    punctuation.title = "?"
    #expect(blank.cacheKey != punctuation.cacheKey)
  }
}

@Suite struct RankingTests {
  let query = SearchQuery(title: "Agricola", subtitle: "Lookout Games", limit: 5, reason: .title)

  @Test func everyProviderIsScoredByTheSameWords() {
    let exact = Ranking.words(record("a:1", title: "Agricola"), query: .init(title: "agricola", limit: 5, reason: .ocr))
    #expect(exact.confidence == 1)
    #expect(exact.reasons == [.ocr])
    let weighted = Ranking.words(
      record("a:1", title: "Agricola"),
      query: .init(title: "agricola", limit: 5, reason: .title),
      weights: .init(words: 0.8)
    )
    #expect(weighted.confidence == 0.8)
  }

  @Test func aSubtitleMatchesTheClosestOfTheRecordsNames() {
    var game = record("bgg:1", title: "Agricola")
    game.subtitle = "Z-Man Games"
    game.otherSubtitles = ["Lookout Games", "Filosofia"]
    #expect(Ranking.words(game, query: query, weights: .init()).confidence == 1)
    game.otherSubtitles = []
    #expect(Ranking.words(game, query: query, weights: .init()).confidence < 1)
  }

  @Test func withoutWordsTheSourcesRelevanceCountsUpTo0_9() {
    var release = record("mb:1")
    release.relevance = 1
    let byNumber = SearchQuery(title: "", catalogueNumber: "CDP 7243", limit: 5, reason: .title)
    #expect(Ranking.words(release, query: byNumber, weights: .init()).confidence == 0.9)
    release.relevance = nil
    #expect(Ranking.words(release, query: byNumber, weights: .init()).confidence == 0)
    release.matched = [.catalogueNumber]
    let matched = Ranking.words(release, query: byNumber, weights: .init())
    #expect(matched.confidence == 0.9)
    #expect(matched.reasons == [.title, .catalogueNumber])
  }

  @Test func aBarcodeMatchIsTheProvidersBarcodeWeight() {
    #expect(Ranking.barcode(record("a:1"), weights: .init()).confidence == 0.95)
    #expect(Ranking.barcode(record("a:1"), weights: .init(barcode: 0.9)).confidence == 0.9)
    #expect(Ranking.barcode(record("a:1"), weights: .init(barcode: .nan)).confidence == 0)
    #expect(Ranking.barcode(record("a:1"), weights: .init()).reasons == [.barcode])
  }
}

extension Ranking {
  static func words(_ record: ProviderRecord, query: SearchQuery) -> ScoredRecord {
    words(record, query: query, weights: ProviderWeights())
  }
}
