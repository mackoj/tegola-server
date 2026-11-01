import Foundation
import Logging

/// Any data supplier, abstractly (D-23): one database that answers for one type (PLAN §4). Everything specific to a
/// supplier (its OpenAPI-generated client, its key, its query language, its answer's shape) stays behind this
/// protocol; the lookup service only sees candidates, works and `SupplierFailure`s. Ids a supplier returns carry
/// its prefix (`musicbrainz:`, `igdb:`, …), so `work(id:)` can find the supplier that owns a work.
protocol DataSupplier: Sendable {
  /// The `name` in `Candidate.sources`, and the prefix of its ids, lower-cased.
  var name: String { get }
  var typeID: String { get }
  /// The ids this source owns start with this, e.g. `musicbrainz:`.
  var idPrefix: String { get }
  /// Barcode lookups are only asked of sources with a barcode index.
  var answersBarcodes: Bool { get }

  func barcode(_ query: BarcodeQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate]
  func search(_ query: SupplierQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate]
  func work(id: String) async throws(SupplierFailure) -> Components.Schemas.Work?
}

/// A words query, from `searchObjects` or one import row.
struct SupplierQuery: Sendable, Hashable {
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

/// The suppliers the configuration turned on, grouped by type (D-22). Every supplier of a type is asked at once; the
/// answers are merged and ranked. When some fail and others answer with candidates, those are enough. When all fail,
/// or the ones that answered found nothing, the lookup is `SourceUnavailable` (503) with the shortest `Retry-After`
/// among the failures, and the app retries: a failure never reads as "no match". Each supplier's answer is cut to
/// its best 10 and cached; failures never are.
package struct SuppliersLookupService: LookupService {
  let sources: [String: [any DataSupplier]]
  let cache: AnswerCache<[Components.Schemas.Candidate]>
  let works: AnswerCache<Components.Schemas.Work>
  let lifetimes: Lifetimes

  struct Lifetimes: Sendable {
    var answer: Duration = .seconds(24 * 3600)
    var empty: Duration = .seconds(3600)
  }

  init(sources: [any DataSupplier], cacheCapacity: Int = 10_000, lifetimes: Lifetimes = Lifetimes()) {
    self.sources = Dictionary(grouping: sources, by: \.typeID)
    self.cache = AnswerCache(capacity: cacheCapacity)
    self.works = AnswerCache(capacity: max(1, cacheCapacity / 10))
    self.lifetimes = lifetimes
  }

  package var supportedTypes: [String] { sources.keys.sorted() }

  package func barcode(_ query: BarcodeQuery) async throws -> [Components.Schemas.Candidate] {
    let asked = (sources[query.typeID] ?? []).filter(\.answersBarcodes)
    let key = cacheKeyString([query.code, query.symbology?.rawValue, query.subtype, query.region])
    return try await ask(asked, operation: "barcode", key: key) { source throws(SupplierFailure) in
      try await source.barcode(query)
    }
  }

  package func search(typeID: String, _ request: Components.Schemas.SearchRequest) async throws
    -> [Components.Schemas.Candidate]
  {
    let words = TextMatch.queryTitle(title: request.title, text: request.text)
    guard words != nil || request.catalogueNumber != nil else { return [] }
    let query = SupplierQuery(
      title: words ?? "",
      subtitle: request.subtitle,
      catalogueNumber: request.catalogueNumber,
      year: request.year,
      subtype: request.subtype,
      region: request.region,
      limit: request.limit ?? 5,
      reason: request.title == nil && request.text != nil ? .ocr : .title
    )
    return try await ask(sources[typeID] ?? [], operation: "search", key: query.cacheKey) {
      source throws(SupplierFailure) in try await source.search(query)
    }
  }

  package func match(typeID: String, _ item: Components.Schemas.MatchItem) async throws
    -> [Components.Schemas.Candidate]
  {
    let query = SupplierQuery(
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
    return try await ask(sources[typeID] ?? [], operation: "search", key: query.cacheKey) {
      source throws(SupplierFailure) in try await source.search(query)
    }
  }

  package func work(id: String) async throws -> Components.Schemas.Work? {
    guard let source = sources.values.joined().first(where: { id.hasPrefix($0.idPrefix) }) else { return nil }
    if let cached = await works.value(id) { return cached }
    do throws(SupplierFailure) {
      guard let work = try await source.work(id: id) else { return nil }
      await works.store(work, for: id, lifetime: lifetimes.answer)
      return work
    } catch {
      throw SourceUnavailable(retryAfter: error.retryAfter)
    }
  }

  /// Asks every source in parallel, each through the cache, and merges what comes back.
  private func ask(
    _ asked: [any DataSupplier],
    operation: String,
    key: String,
    _ body: @escaping @Sendable (any DataSupplier) async throws(SupplierFailure) -> [Components.Schemas.Candidate]
  ) async throws -> [Components.Schemas.Candidate] {
    guard !asked.isEmpty else { return [] }
    let cache = self.cache
    let lifetimes = self.lifetimes
    let outcomes = await withTaskGroup(of: Result<[Components.Schemas.Candidate], SupplierFailure>.self) { group in
      for source in asked {
        group.addTask {
          let cacheKey = "\(source.name)|\(source.typeID)|\(operation)|\(key)"
          if let cached = await cache.value(cacheKey) { return .success(cached) }
          do throws(SupplierFailure) {
            // Best 10 per supplier: what the contract can return, and a bound on what the cache holds.
            let answer = Array(try await body(source).sorted { $0.confidence > $1.confidence }.prefix(10))
            await cache.store(answer, for: cacheKey, lifetime: answer.isEmpty ? lifetimes.empty : lifetimes.answer)
            return .success(answer)
          } catch {
            return .failure(error)
          }
        }
      }
      var outcomes: [Result<[Components.Schemas.Candidate], SupplierFailure>] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }
    var candidates: [Components.Schemas.Candidate] = []
    var failures: [SupplierFailure] = []
    for outcome in outcomes {
      switch outcome {
      case .success(let answer): candidates += answer
      case .failure(let failure): failures.append(failure)
      }
    }
    if candidates.isEmpty, let soonest = failures.map(\.retryAfter).min() {
      throw SourceUnavailable(retryAfter: soonest)
    }
    return candidates
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
