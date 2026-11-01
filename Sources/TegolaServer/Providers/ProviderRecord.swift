import Foundation

// What a provider hands the router, and what the router makes of it (D-27). A provider wraps one source's generated
// client and turns its answers into `ProviderRecord`s: evidence, not answers. It never ranks, merges or decides. The
// router scores every record the same way (`Ranking`), merges the records of several providers that name the same
// release (`RecordMerge`), and builds the contract's candidates. Nothing past this file knows a source's name.

/// One release as one provider knows it, in the contract's vocabulary: the type file's field keys, the spine's roles.
struct ProviderRecord: Sendable, Hashable {
  typealias Kind = Components.Schemas.Reason.KindPayload

  /// The provider's `name` (`musicbrainz`).
  var provider: String
  /// The release's id in this provider, with its prefix (`musicbrainz:release:<mbid>`).
  var releaseID: String
  var workID: String?
  var typeID: String
  var subtype: String?
  var title: String
  var subtitle: String?
  /// Names a query's subtitle may also match, besides `subtitle` (a board game's other publishers).
  var otherSubtitles: [String] = []
  var year: Int?
  var region: String?
  var fields: [String: Components.Schemas.FieldValue] = [:]
  /// List and log fields (a tracklist), by the type file's key; each entry by the field's entry shape.
  var entries: [String: [[String: String?]]] = [:]
  var images: [Components.Schemas.Image] = []
  /// Ids in other databases, the provider's own included, by namespace (`musicbrainz`, `igdb`, `wikidata`). Two
  /// records that disagree on one are never the same release.
  var externalIDs: [String: String] = [:]
  /// The namespaces of `externalIDs` that name this very release, not its game or work (MusicBrainz's release mbid,
  /// not its release group; never IGDB's game id, which every platform's release shares). Two records that share an
  /// id in a namespace both call identifying are the same release.
  var identifying: Set<String> = []
  /// What the source matched exactly, beyond the words the router compares itself: a `catalogueNumber`, a `subtype`.
  /// A record from a barcode lookup is an exact barcode match by definition (the provider drops the others).
  var matched: Set<Kind> = []
  /// The source's own relevance, 0…1, used only when the query has no words to compare (a catalogue number alone).
  var relevance: Double?
  var source: Components.Schemas.Source
}

/// How much the router trusts a provider's matches for its type (D-27). Until the manifests, each provider says it.
struct ProviderWeights: Sendable, Hashable {
  /// The confidence of an exact barcode match.
  var barcode: Double = 0.95
  /// A factor on a words match: a general source's looser matches rank below a specialist's.
  var words: Double = 1
}

/// A record with the router's verdict on it.
struct ScoredRecord: Sendable, Hashable {
  var record: ProviderRecord
  var confidence: Double
  var reasons: [ProviderRecord.Kind]
}

/// Scores records against what was asked, the same way for every provider (D-22's ranking, now in one place).
enum Ranking {
  /// The order reasons are listed in after the one that found the record.
  static let extraReasons: [ProviderRecord.Kind] = [.catalogueNumber, .subtype]

  /// A record a barcode lookup found: the provider's barcode weight.
  static func barcode(_ record: ProviderRecord, weights: ProviderWeights) -> ScoredRecord {
    ScoredRecord(record: record, confidence: clamp(weights.barcode), reasons: reasons(.barcode, record))
  }

  /// A record a words search found. Title 70 %, subtitle 20 %, year 10 %, each counted when the query gives it
  /// (`TextMatch.confidence`), times the provider's words weight. With no words to compare (a catalogue number
  /// alone), the source's own relevance, at most 0.9. A catalogue number the source matched exactly lifts it to 0.9.
  static func words(_ record: ProviderRecord, query: SearchQuery, weights: ProviderWeights) -> ScoredRecord {
    var confidence: Double
    if query.title.isEmpty {
      confidence = clamp(record.relevance ?? 0) * 0.9
    } else {
      confidence = TextMatch.confidence(
        title: query.title,
        candidateTitle: record.title,
        subtitle: query.subtitle,
        candidateSubtitle: subtitle(record, closestTo: query.subtitle),
        year: query.year,
        candidateYear: record.year
      )
    }
    if record.matched.contains(.catalogueNumber) { confidence = max(confidence, 0.9) }
    return ScoredRecord(
      record: record,
      confidence: clamp(confidence * weights.words),
      reasons: reasons(query.reason, record)
    )
  }

  /// The record's subtitle, or the one of its other names closest to what was asked.
  static func subtitle(_ record: ProviderRecord, closestTo asked: String?) -> String? {
    guard let asked, !asked.isEmpty, !record.otherSubtitles.isEmpty else { return record.subtitle }
    let names = (record.subtitle.map { [$0] } ?? []) + record.otherSubtitles
    return names.max { TextMatch.similarity(asked, $0) < TextMatch.similarity(asked, $1) }
  }

  static func reasons(_ first: ProviderRecord.Kind, _ record: ProviderRecord) -> [ProviderRecord.Kind] {
    [first] + extraReasons.filter { $0 != first && record.matched.contains($0) }
  }

  static func clamp(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0
  }
}

/// Turns one tier's scored records into candidates (D-27). Records from different providers become one candidate
/// only when they certainly name the same release: they share a release-level external id (`identifying`), or they
/// agree exactly on the type, the title, the subtype, the region and the year. A similar title is never enough, so two
/// pressings' fields can't mix. A link must also be one to one: a record that could be either of two records of
/// another provider (a reissue) stays on its own. A candidate never holds two records of one provider, nor two that
/// disagree on an id, however they're linked.
enum RecordMerge {
  typealias Candidate = Components.Schemas.Candidate

  /// `order` ranks the providers (the type's configured order): the first one's record leads a merged candidate, so
  /// its ids, title and fields win, and the candidate's ids don't change with whoever answered first.
  static func candidates(_ scored: [ScoredRecord], order: [String]) -> [Candidate] {
    let records = sameRecords(scored)
    let rank: (ScoredRecord) -> Int = { order.firstIndex(of: $0.record.provider) ?? order.count }
    var groups = UnionFind(records.map(\.record))
    for (a, b) in links(records) { groups.union(a, b) }
    return groups.groups()
      .map { members in candidate(members.map { records[$0] }.sorted { rank($0) < rank($1) }) }
      .sorted { ($0.confidence, $1.releaseID) > ($1.confidence, $0.releaseID) }
  }

  /// One provider's same release, found twice (by barcode and by words), is one record with the higher confidence
  /// and both reasons, in the order found.
  static func sameRecords(_ scored: [ScoredRecord]) -> [ScoredRecord] {
    var merged: [ScoredRecord] = []
    var index: [String: Int] = [:]
    for item in scored {
      let key = item.record.provider + "\u{0}" + item.record.releaseID
      guard let at = index[key] else {
        index[key] = merged.count
        merged.append(item)
        continue
      }
      merged[at].confidence = max(merged[at].confidence, item.confidence)
      for reason in item.reasons where !merged[at].reasons.contains(reason) { merged[at].reasons.append(reason) }
    }
    return merged
  }

  /// The pairs of records (by index) that are the same release, best first, one to one between two providers.
  static func links(_ records: [ScoredRecord]) -> [(Int, Int)] {
    var candidates: [(Int, Int)] = []
    for a in records.indices {
      for b in records.indices where b > a && same(records[a].record, records[b].record) {
        candidates.append((a, b))
      }
    }
    // How many records of each other provider a record links to: only a single one counts.
    var counts: [Int: [String: Int]] = [:]
    for (a, b) in candidates {
      counts[a, default: [:]][records[b].record.provider, default: 0] += 1
      counts[b, default: [:]][records[a].record.provider, default: 0] += 1
    }
    return
      candidates
      .filter { a, b in
        counts[a]?[records[b].record.provider] == 1 && counts[b]?[records[a].record.provider] == 1
      }
      .sorted { lhs, rhs in
        let left = max(records[lhs.0].confidence, records[lhs.1].confidence)
        let right = max(records[rhs.0].confidence, records[rhs.1].confidence)
        return left != right ? left > right : (lhs.0, lhs.1) < (rhs.0, rhs.1)
      }
  }

  /// Whether two records of different providers certainly name the same release.
  static func same(_ a: ProviderRecord, _ b: ProviderRecord) -> Bool {
    guard a.provider != b.provider, a.typeID == b.typeID, !conflict(a.externalIDs, b.externalIDs) else { return false }
    let shared = a.identifying.intersection(b.identifying).contains { namespace in
      a.externalIDs[namespace].map { $0 == b.externalIDs[namespace] } ?? false
    }
    if shared { return true }
    guard let key = editionKey(a), key == editionKey(b) else { return false }
    return true
  }

  /// Type, title (folded, without a leading article), subtype, region and year, when the record has all five.
  static func editionKey(_ record: ProviderRecord) -> [String]? {
    let title = TextMatch.stripArticle(TextMatch.normalise(record.title))
    guard !title.isEmpty, let subtype = record.subtype, let region = record.region, let year = record.year else {
      return nil
    }
    return [record.typeID, title, subtype, region, String(year)]
  }

  /// One candidate from records of different providers, the leading one first: its values win, the others fill
  /// what it lacks. Confidence is the highest; reasons, sources and ids are all of theirs.
  static func candidate(_ members: [ScoredRecord]) -> Candidate {
    let lead = members[0].record
    var reasons: [ProviderRecord.Kind] = []
    var sources: [Components.Schemas.Source] = []
    var fields: [String: Components.Schemas.FieldValue] = [:]
    var images: [Components.Schemas.Image] = []
    var externalIDs: [String: String] = [:]
    for member in members {
      for reason in member.reasons where !reasons.contains(reason) { reasons.append(reason) }
      let record = member.record
      if !sources.contains(where: { $0.name == record.source.name }) { sources.append(record.source) }
      fields.merge(record.fields) { kept, _ in kept }
      for image in record.images where !images.contains(where: { $0.role == image.role }) { images.append(image) }
      externalIDs.merge(record.externalIDs) { kept, _ in kept }
    }
    func first<T>(_ value: (ProviderRecord) -> T?) -> T? {
      for member in members { if let found = value(member.record) { return found } }
      return nil
    }
    // A list comes whole from one record, the first that has it: two sources' tracklists don't interleave.
    var entries: [String: [[String: String?]]] = [:]
    for member in members { entries.merge(member.record.entries) { kept, _ in kept } }
    return Candidate(
      releaseID: lead.releaseID,
      workID: first(\.workID),
      typeID: lead.typeID,
      subtype: first(\.subtype),
      title: lead.title,
      subtitle: first(\.subtitle),
      year: first(\.year),
      region: first(\.region),
      fields: fields.isEmpty ? nil : .init(additionalProperties: fields),
      entries: entries.isEmpty
        ? nil : .init(additionalProperties: entries.mapValues { $0.map { .init(additionalProperties: $0) } }),
      images: images.isEmpty ? nil : images,
      confidence: members.map(\.confidence).max() ?? 0,
      reasons: reasons.map { .init(kind: $0) },
      sources: sources,
      externalIDs: externalIDs.isEmpty ? nil : .init(additionalProperties: externalIDs)
    )
  }

  /// Whether two sets of ids disagree on a namespace they both have.
  static func conflict(_ a: [String: String], _ b: [String: String]) -> Bool {
    a.contains { namespace, value in b[namespace].map { $0 != value } ?? false }
  }

  /// Groups of record indices. A union that would put two records of one provider together, or two records that
  /// disagree on an id, is refused: links are checked pairwise, so a chain could otherwise join them.
  struct UnionFind {
    private var parent: [Int]
    private var providers: [Set<String>]
    private var ids: [[String: String]]

    init(_ records: [ProviderRecord]) {
      parent = Array(records.indices)
      providers = records.map { [$0.provider] }
      ids = records.map(\.externalIDs)
    }

    mutating func root(_ index: Int) -> Int {
      var index = index
      while parent[index] != index {
        parent[index] = parent[parent[index]]
        index = parent[index]
      }
      return index
    }

    mutating func union(_ a: Int, _ b: Int) {
      let (x, y) = (root(a), root(b))
      guard x != y, providers[x].isDisjoint(with: providers[y]), !RecordMerge.conflict(ids[x], ids[y]) else { return }
      let (keep, drop) = x < y ? (x, y) : (y, x)
      parent[drop] = keep
      providers[keep].formUnion(providers[drop])
      ids[keep].merge(ids[drop]) { kept, _ in kept }
    }

    mutating func groups() -> [[Int]] {
      var groups: [Int: [Int]] = [:]
      for index in parent.indices { groups[root(index), default: []].append(index) }
      return groups.keys.sorted().map { groups[$0]! }
    }
  }
}
