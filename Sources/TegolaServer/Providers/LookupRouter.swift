import Foundation
import Logging

/// Any data provider, abstractly (D-23, D-27): one database that answers for one type (PLAN §4). Everything specific
/// to a provider (its OpenAPI-generated client, its key, its query language, its answer's shape) stays behind this
/// protocol. A provider returns `ProviderRecord`s, evidence the router scores and merges; it never ranks or decides.
/// Ids a provider returns carry its prefix (`musicbrainz:`, `igdb:`, …), so `work(id:)` can find the provider that
/// owns a work.
protocol DataProvider: Sendable {
  /// The `name` in `Candidate.sources`, and the prefix of its ids, lower-cased.
  var name: String { get }
  var typeID: String { get }
  /// The ids this source owns start with this, e.g. `musicbrainz:`.
  var idPrefix: String { get }
  /// Barcode lookups are only asked of sources with a barcode index.
  var answersBarcodes: Bool { get }
  /// When it's asked: with the type's other primary providers, or only when they found nothing (D-26).
  var tier: ProviderTier { get }
  /// How much the router trusts its matches (D-27).
  var weights: ProviderWeights { get }

  /// Exact barcode matches only: the router scores every record it returns as one.
  func barcode(_ query: BarcodeQuery) async throws(ProviderFailure) -> [ProviderRecord]
  /// What the source finds for the words, unranked: the router compares the words itself.
  func search(_ query: SearchQuery) async throws(ProviderFailure) -> [ProviderRecord]
  func work(id: String) async throws(ProviderFailure) -> Components.Schemas.Work?
}

extension DataProvider {
  var tier: ProviderTier { .primary }
  var weights: ProviderWeights { ProviderWeights() }
}

/// The order a type's providers are asked in (D-26). Every provider of one tier is asked at once; the next tier only
/// when the one before found nothing, whether its providers answered "no match" or failed. A source that knows a type
/// well is primary; a general one (Wikidata) is a fallback, so its looser matches never crowd out a precise one.
enum ProviderTier: Int, Comparable, CaseIterable, Sendable {
  case primary
  case fallback

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A words query, from `identifyObject`'s hints or one import row.
struct SearchQuery: Sendable, Hashable {
  var title: String
  var subtitle: String?
  var catalogueNumber: String?
  var year: Int?
  var subtype: String?
  var region: String?
  var limit: Int
  /// Why a candidate came back, for its `reasons`: `title`, or `ocr` when the words came from a photo.
  var reason: Components.Schemas.Reason.KindPayload

  /// The cache key: everything that changes the answer, normalised, encoded as a JSON array so no value can run
  /// into the next one.
  var cacheKey: String {
    let parts: [String?] = [
      TextMatch.normalise(title), subtitle.map(TextMatch.normalise), catalogueNumber, year.map(String.init), subtype,
      region, String(limit), reason.rawValue,
    ]
    return cacheKeyString(parts)
  }
}

/// An unambiguous cache key from optional parts.
func cacheKeyString(_ parts: [String?]) -> String {
  let data = (try? JSONEncoder().encode(parts)) ?? Data()
  return String(decoding: data, as: UTF8.self)
}

/// The providers the configuration turned on, grouped by type (D-22), asked tier by tier (D-26), their records scored
/// and merged here (D-27). Every provider of a tier is asked at once. Each one's records are scored the same way
/// (`Ranking`), cut to its best 10 and cached; failures never are. The tier's records then become candidates
/// (`RecordMerge`): a release two providers both found is one candidate. When some fail and others find something,
/// that is enough. When a tier finds nothing (its providers failed, or found no match), the next tier is asked. When
/// no tier finds anything and any provider failed, the lookup is `SourceUnavailable` (503) with the shortest
/// `Retry-After` among the failures, and the app retries: a failure never reads as "no match".
package struct LookupRouter: LookupService {
  package typealias Candidate = Components.Schemas.Candidate

  /// Each type's providers, in the configured order, which is also their rank when records merge.
  let sources: [String: [any DataProvider]]
  let cache: AnswerCache<[ProviderRecord]>
  let works: AnswerCache<Components.Schemas.Work>
  let lifetimes: Lifetimes

  struct Lifetimes: Sendable {
    var answer: Duration = .seconds(24 * 3600)
    var empty: Duration = .seconds(3600)
  }

  /// What one tier found, and the `Retry-After` of each provider that failed.
  struct TierAnswer: Sendable {
    var found: [ScoredRecord] = []
    var failures: [Int] = []
  }

  init(sources: [any DataProvider], cacheCapacity: Int = 10_000, lifetimes: Lifetimes = Lifetimes()) {
    self.sources = Dictionary(grouping: sources, by: \.typeID)
    self.cache = AnswerCache(capacity: cacheCapacity)
    self.works = AnswerCache(capacity: max(1, cacheCapacity / 10))
    self.lifetimes = lifetimes
  }

  package var supportedTypes: [String] { sources.keys.sorted() }

  package func barcode(_ query: BarcodeQuery) async throws -> [Candidate] {
    try await tiered(query.typeID) { tier in await askBarcode(tier, query) }
  }

  /// The words go to every provider of the tier, a barcode to those with a barcode index, both at once. A release
  /// both find is one candidate, with the higher confidence and both reasons. One half failing doesn't hide what the
  /// other found; when neither finds anything, the next tier is asked (D-24, D-26).
  package func identify(typeID: String, _ hints: Components.Schemas.IdentifyHints) async throws -> [Candidate] {
    let words = TextMatch.queryTitle(title: hints.title, text: hints.text)
    let query: SearchQuery? =
      words == nil && hints.catalogueNumber == nil
      ? nil
      : SearchQuery(
        title: words ?? "",
        subtitle: hints.subtitle,
        catalogueNumber: hints.catalogueNumber,
        year: hints.year,
        subtype: hints.subtype,
        region: hints.region,
        limit: hints.limit ?? 5,
        reason: hints.title == nil && hints.text != nil ? .ocr : .title
      )
    let barcode = hints.barcode.map { hint in
      BarcodeQuery(
        typeID: typeID,
        code: hint.code,
        symbology: hint.symbology,
        subtype: hints.subtype,
        region: hints.region
      )
    }
    return try await tiered(typeID) { tier in
      func words() async -> TierAnswer {
        guard let query else { return TierAnswer() }
        return await askWords(tier, query)
      }
      func code() async -> TierAnswer {
        guard let barcode else { return TierAnswer() }
        return await askBarcode(tier, barcode)
      }
      async let byWords = words()
      async let byBarcode = code()
      let (codes, text) = await (byBarcode, byWords)
      // Barcode records first, so a release found both ways lists `barcode` before the words' reason.
      return TierAnswer(found: codes.found + text.found, failures: codes.failures + text.failures)
    }
  }

  package func match(typeID: String, _ item: Components.Schemas.MatchItem) async throws -> [Candidate] {
    let query = SearchQuery(
      title: item.title,
      subtitle: item.subtitle,
      // The contract gives an import row's year no range: one outside the years a ranking compares (a blank CSV
      // year read as 0, say) is dropped, not refused, and never computed with (tasks/M3-review.md).
      year: item.year.flatMap { TextMatch.years.contains($0) ? $0 : nil },
      subtype: item.subtype,
      region: item.region,
      limit: 5,
      reason: .title
    )
    return try await tiered(typeID) { tier in await askWords(tier, query) }
  }

  package func work(id: String) async throws -> Components.Schemas.Work? {
    guard let source = sources.values.joined().first(where: { id.hasPrefix($0.idPrefix) }) else { return nil }
    if let cached = await works.value(id) { return cached }
    do throws(ProviderFailure) {
      guard let work = try await source.work(id: id) else { return nil }
      await works.store(work, for: id, lifetime: lifetimes.answer)
      return work
    } catch {
      throw SourceUnavailable(retryAfter: error.retryAfter)
    }
  }

  // MARK: - tiers

  /// Asks the type's tiers in order and returns the first one's candidates, if it found any. With none, any failure
  /// on the way is `SourceUnavailable`: a fallback's "no match" can't stand for a primary that couldn't answer.
  private func tiered(_ typeID: String, _ body: ([any DataProvider]) async -> TierAnswer) async throws -> [Candidate] {
    let all = sources[typeID] ?? []
    var failures: [Int] = []
    for tier in ProviderTier.allCases {
      let asked = all.filter { $0.tier == tier }
      guard !asked.isEmpty else { continue }
      let answer = await body(asked)
      if !answer.found.isEmpty { return RecordMerge.candidates(answer.found, order: all.map(\.name)) }
      failures += answer.failures
    }
    if let soonest = failures.min() { throw SourceUnavailable(retryAfter: soonest) }
    return []
  }

  private func askWords(_ tier: [any DataProvider], _ query: SearchQuery) async -> TierAnswer {
    await ask(tier, operation: "search", key: query.cacheKey) { source throws(ProviderFailure) in
      try await source.search(query)
    } score: { record, source in
      Ranking.words(record, query: query, weights: source.weights)
    }
  }

  private func askBarcode(_ tier: [any DataProvider], _ query: BarcodeQuery) async -> TierAnswer {
    let key = cacheKeyString([query.code, query.symbology?.rawValue, query.subtype, query.region])
    return await ask(tier.filter(\.answersBarcodes), operation: "barcode", key: key) {
      source throws(ProviderFailure) in
      try await source.barcode(query)
    } score: { record, source in
      Ranking.barcode(record, weights: source.weights)
    }
  }

  /// Asks every provider in parallel, each through the cache, and scores what comes back. Each provider's records
  /// are cut to its best 10 before they're cached: what the contract can return, and a bound on what the cache holds.
  private func ask(
    _ asked: [any DataProvider],
    operation: String,
    key: String,
    _ body: @escaping @Sendable (any DataProvider) async throws(ProviderFailure) -> [ProviderRecord],
    score: @escaping @Sendable (ProviderRecord, any DataProvider) -> ScoredRecord
  ) async -> TierAnswer {
    guard !asked.isEmpty else { return TierAnswer() }
    let cache = self.cache
    let lifetimes = self.lifetimes
    let outcomes = await withTaskGroup(of: (Int, Result<[ScoredRecord], ProviderFailure>).self) { group in
      for (index, source) in asked.enumerated() {
        group.addTask {
          let cacheKey = "\(source.name)|\(source.typeID)|\(operation)|\(key)"
          if let cached = await cache.value(cacheKey) { return (index, .success(cached.map { score($0, source) })) }
          do throws(ProviderFailure) {
            let scored = try await body(source)
              .filter { $0.provider == source.name && $0.typeID == source.typeID }
              .map { score($0, source) }
              .sorted { $0.confidence > $1.confidence }
              .prefix(10)
            let records = scored.map(\.record)
            await cache.store(records, for: cacheKey, lifetime: records.isEmpty ? lifetimes.empty : lifetimes.answer)
            return (index, .success(Array(scored)))
          } catch {
            return (index, .failure(error))
          }
        }
      }
      var outcomes: [(Int, Result<[ScoredRecord], ProviderFailure>)] = []
      for await outcome in group { outcomes.append(outcome) }
      // In the configured order, whoever answered first, so a merge is the same every time.
      return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var answer = TierAnswer()
    for outcome in outcomes {
      switch outcome {
      case .success(let found): answer.found += found
      case .failure(let failure): answer.failures.append(failure.retryAfter)
      }
    }
    return answer
  }
}

extension Components.Schemas.Source {
  static func named(_ name: String, url: String? = nil, attribution: String? = nil) -> Self {
    .init(name: name, url: url, attribution: attribution)
  }
}

extension Components.Schemas.Reason {
  static func of(_ kind: KindPayload) -> Self { .init(kind: kind) }
}
