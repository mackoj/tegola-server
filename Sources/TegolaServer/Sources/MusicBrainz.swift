import Foundation

/// Music from MusicBrainz (D-22): barcode and words, no key. MusicBrainz asks for a User-Agent naming the
/// application and a contact, and at most one request a second; the connection's pacer keeps to it.
/// Its data is CC0. Releases are `musicbrainz:release:<mbid>`, works are `musicbrainz:release-group:<mbid>`.
struct MusicBrainzSource: CatalogueSource {
  let connection: SourceConnection
  let userAgent: String
  let base = URL(string: "https://musicbrainz.org/ws/2/")!

  let name = "musicbrainz"
  let typeID = "music"
  let idPrefix = "musicbrainz:"
  let answersBarcodes = true

  static let source = Components.Schemas.Source.named(
    "MusicBrainz",
    url: "https://musicbrainz.org",
    attribution: "Data from MusicBrainz (CC0)"
  )

  func barcode(_ query: BarcodeQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] {
    let code = query.code.filter(\.isNumber)
    guard !code.isEmpty else { return [] }
    let releases = try await releases(lucene: "barcode:\(code)", limit: 10)
    return releases.compactMap { release in
      // The index matches loosely; only an exact barcode counts as a barcode match.
      guard release.barcode?.filter(\.isNumber) == code else { return nil }
      if let subtype = query.subtype, Self.subtype(release) != subtype { return nil }
      return candidate(release, confidence: 0.95, reasons: [.init(kind: .barcode)])
    }
  }

  func search(_ query: SourceQuery) async throws(SourceFailure) -> [Components.Schemas.Candidate] {
    var clauses: [String] = []
    if !query.title.isEmpty { clauses.append("release:(\(Self.escape(query.title)))") }
    if let artist = query.subtitle, !artist.isEmpty { clauses.append("artist:(\(Self.escape(artist)))") }
    if let catalogueNumber = query.catalogueNumber, !catalogueNumber.isEmpty {
      clauses.append("catno:\"\(Self.escape(catalogueNumber))\"")
    }
    if let year = query.year { clauses.append("date:\(year)") }
    if let format = query.subtype.flatMap(Self.format(forSubtype:)) { clauses.append("format:\(format)") }
    guard !clauses.isEmpty else { return [] }
    let releases = try await releases(lucene: clauses.joined(separator: " AND "), limit: min(25, query.limit * 3))
    return releases.compactMap { release in
      let year = TextMatch.year(release.date)
      var reasons: [Components.Schemas.Reason] = [.init(kind: query.reason)]
      var confidence: Double
      if query.title.isEmpty {
        // A catalogue number alone: MusicBrainz's own score is all we have.
        confidence = Double(release.score ?? 0) / 100 * 0.9
      } else {
        confidence = TextMatch.confidence(
          title: query.title,
          candidateTitle: release.title,
          subtitle: query.subtitle,
          candidateSubtitle: Self.artist(release),
          year: query.year,
          candidateYear: year
        )
      }
      if let catalogueNumber = query.catalogueNumber,
        release.labelInfo?.contains(where: {
          $0.catalogNumber.map(TextMatch.normalise) == TextMatch.normalise(catalogueNumber)
        }) == true
      {
        reasons.append(.init(kind: .catalogueNumber))
        confidence = max(confidence, 0.9)
      }
      return candidate(release, confidence: confidence, reasons: reasons)
    }
  }

  func work(id: String) async throws(SourceFailure) -> Components.Schemas.Work? {
    let prefix = "musicbrainz:release-group:"
    guard id.hasPrefix(prefix), let mbid = Self.mbid(String(id.dropFirst(prefix.count))) else { return nil }
    var components = URLComponents(url: base.appendingPathComponent("release"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      .init(name: "release-group", value: mbid), .init(name: "inc", value: "release-groups media artist-credits"),
      .init(name: "fmt", value: "json"), .init(name: "limit", value: "100"),
    ]
    guard let data = try await connection.send(request(components.url!)) else { return nil }
    let page = try connection.decode(ReleaseList.self, from: data)
    guard let first = page.releases.first else { return nil }
    let title = TextMatch.clean(first.releaseGroup?.title ?? first.title) ?? first.title
    return .init(
      workID: id,
      title: title,
      releases: page.releases.compactMap { release in
        guard let releaseID = Self.mbid(release.id) else { return nil }
        return .init(
          releaseID: "musicbrainz:release:\(releaseID)",
          typeID: typeID,
          subtype: Self.subtype(release),
          title: TextMatch.clean(release.title) ?? title,
          year: TextMatch.year(release.date)
        )
      }
    )
  }

  // MARK: - requests

  private func releases(lucene: String, limit: Int) async throws(SourceFailure) -> [Release] {
    var components = URLComponents(url: base.appendingPathComponent("release"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      .init(name: "query", value: lucene), .init(name: "fmt", value: "json"),
      .init(name: "limit", value: String(max(1, min(limit, 25)))),
    ]
    guard let data = try await connection.send(request(components.url!)) else { return [] }
    return try connection.decode(ReleaseList.self, from: data).releases
  }

  private func request(_ url: URL) -> OutboundRequest {
    OutboundRequest(url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"])
  }

  private func candidate(
    _ release: Release,
    confidence: Double,
    reasons: [Components.Schemas.Reason]
  ) -> Components.Schemas.Candidate? {
    guard let mbid = Self.mbid(release.id), let title = TextMatch.clean(release.title) else { return nil }
    var fields: [String: Components.Schemas.FieldValue] = [:]
    let medium = Self.medium(release)
    fields["medium"] = .case1(medium)
    if let format = Self.formatChoice(release, medium: medium) { fields["format"] = .case1(format) }
    if let label = TextMatch.clean(release.labelInfo?.first?.label?.name) { fields["label"] = .case1(label) }
    if let number = TextMatch.clean(release.labelInfo?.first?.catalogNumber, max: 64) {
      fields["catalogNumber"] = .case1(number)
    }
    if let country = TextMatch.clean(release.country, max: 16) { fields["country"] = .case1(country) }
    var externalIDs = ["musicbrainz": mbid]
    if let group = release.releaseGroup?.id.flatMap(Self.mbid) { externalIDs["musicbrainz-release-group"] = group }
    return .init(
      releaseID: "musicbrainz:release:\(mbid)",
      workID: release.releaseGroup?.id.flatMap(Self.mbid).map { "musicbrainz:release-group:\($0)" },
      typeID: typeID,
      subtype: Self.subtype(release),
      title: title,
      subtitle: TextMatch.clean(Self.artist(release)),
      year: TextMatch.year(release.date),
      fields: .init(additionalProperties: fields),
      confidence: confidence,
      reasons: reasons,
      sources: [Self.source],
      externalIDs: .init(additionalProperties: externalIDs)
    )
  }

  // MARK: - mapping

  /// MusicBrainz ids are UUIDs; anything else is refused, so an id never smuggles a path or query into a URL.
  static func mbid(_ raw: String?) -> String? {
    guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
    return uuid.uuidString.lowercased()
  }

  static func artist(_ release: Release) -> String? {
    guard let credits = release.artistCredit, !credits.isEmpty else { return nil }
    return credits.map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
  }

  /// The type file's `medium` choice: Vinyl, CD, Cassette or Other.
  static func medium(_ release: Release) -> String {
    let formats = (release.media ?? []).compactMap(\.format)
    if formats.isEmpty { return "Other" }
    if formats.allSatisfy({ $0.contains("Vinyl") }) { return "Vinyl" }
    if formats.allSatisfy({ $0.contains("CD") }) { return "CD" }
    if formats.allSatisfy({ $0.contains("Cassette") }) { return "Cassette" }
    return "Other"
  }

  static func subtype(_ release: Release) -> String? {
    switch medium(release) {
    case "Vinyl": "vinyl"
    case "CD": "cd"
    case "Cassette": "cassette"
    default: release.media?.isEmpty == false ? "other" : nil
    }
  }

  /// The type file's `format` choice, only when it's unambiguous.
  static func formatChoice(_ release: Release, medium: String) -> String? {
    let media = release.media ?? []
    let count = media.count
    switch medium {
    case "CD": return count == 1 ? "CD" : count == 2 ? "2×CD" : count == 3 ? "3×CD" : "Box set"
    case "Cassette": return count == 1 ? "Cassette" : count == 2 ? "2×Cassette" : nil
    case "Vinyl":
      let formats = Set(media.compactMap(\.format))
      if formats == ["7\" Vinyl"] { return count == 1 ? "7\"" : nil }
      if formats == ["10\" Vinyl"] { return count == 1 ? "10\"" : nil }
      if formats.isSubset(of: ["12\" Vinyl", "Vinyl"]) { return count == 1 ? "LP" : count == 2 ? "2×LP" : nil }
      return nil
    default: return nil
    }
  }

  static func format(forSubtype subtype: String) -> String? {
    switch subtype {
    case "vinyl": "Vinyl"
    case "cd": "CD"
    case "cassette": "Cassette"
    default: nil
    }
  }

  /// Lucene's special characters, escaped, so words from the app stay words in MusicBrainz's query (D-22).
  static func escape(_ text: String) -> String {
    let special: Set<Character> = [
      "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]", "^", "\"", "~", "*", "?", ":", "\\", "/",
    ]
    var escaped = ""
    for character in text.prefix(300) {
      if character.isNewline { escaped.append(" "); continue }
      if special.contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    // AND, OR and NOT are operators only in upper case; lower-casing them keeps them words.
    return escaped.split(separator: " ", omittingEmptySubsequences: true)
      .map { ["AND", "OR", "NOT"].contains($0) ? $0.lowercased() : String($0) }
      .joined(separator: " ")
  }

  // MARK: - wire

  struct ReleaseList: Decodable {
    var releases: [Release]
  }

  struct Release: Decodable {
    var id: String
    var score: Int?
    var title: String
    var date: String?
    var country: String?
    var barcode: String?
    var artistCredit: [ArtistCredit]?
    var releaseGroup: ReleaseGroup?
    var labelInfo: [LabelInfo]?
    var media: [Medium]?

    enum CodingKeys: String, CodingKey {
      case id, score, title, date, country, barcode, media
      case artistCredit = "artist-credit"
      case releaseGroup = "release-group"
      case labelInfo = "label-info"
    }
  }

  struct ArtistCredit: Decodable {
    var name: String?
    var joinphrase: String?
    var artist: Artist?
  }

  struct Artist: Decodable {
    var name: String?
  }

  struct ReleaseGroup: Decodable {
    var id: String?
    var title: String?
  }

  struct LabelInfo: Decodable {
    var catalogNumber: String?
    var label: Label?

    enum CodingKeys: String, CodingKey {
      case label
      case catalogNumber = "catalog-number"
    }
  }

  struct Label: Decodable {
    var name: String?
  }

  struct Medium: Decodable {
    var format: String?
  }
}
