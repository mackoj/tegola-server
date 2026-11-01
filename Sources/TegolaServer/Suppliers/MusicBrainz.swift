import Foundation
import MusicBrainzAPI
import OpenAPIRuntime

/// Music from MusicBrainz (D-22), through the client generated from `api/sources/musicbrainz.openapi.yaml` (D-23):
/// barcode and words, no key. MusicBrainz asks for a User-Agent naming the application and a contact, and at most
/// one request a second; the connection's pacer keeps to it. Its data is CC0.
/// Releases are `musicbrainz:release:<mbid>`, works are `musicbrainz:release-group:<mbid>`.
struct MusicBrainzSupplier: DataSupplier {
  typealias Release = MusicBrainzAPI.Components.Schemas.Release

  let connection: SupplierConnection
  let client: MusicBrainzAPI.Client

  let name = "musicbrainz"
  let typeID = "music"
  let idPrefix = "musicbrainz:"
  let answersBarcodes = true

  /// The Cover Art Archive serves the release's front image at a stable URL; the app follows its redirect to the
  /// Internet Archive. Images are listed only when the release says it has a front, so no URL is a known 404.
  static let imageHosts: Set<String> = ["coverartarchive.org"]

  static let source = Components.Schemas.Source.named(
    "MusicBrainz",
    url: "https://musicbrainz.org",
    attribution: "Data from MusicBrainz (CC0)"
  )

  init(connection: SupplierConnection, userAgent: String) {
    self.connection = connection
    self.client = MusicBrainzAPI.Client(
      serverURL: try! MusicBrainzAPI.Servers.Server1.url(),
      transport: SupplierTransport(connection: connection),
      middlewares: [HeadersMiddleware { ["User-Agent": userAgent] }]
    )
  }

  func barcode(_ query: BarcodeQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    let code = query.code.filter(\.isNumber)
    guard !code.isEmpty else { return [] }
    let releases = try await releases(.init(query: "barcode:\(code)", fmt: .json, limit: 10))
    return releases.compactMap { release in
      // The index matches loosely; only an exact barcode counts as a barcode match.
      guard release.barcode?.filter(\.isNumber) == code else { return nil }
      if let subtype = query.subtype, Self.subtype(release) != subtype { return nil }
      return candidate(release, confidence: 0.95, reasons: [.init(kind: .barcode)])
    }
  }

  func search(_ query: SupplierQuery) async throws(SupplierFailure) -> [Components.Schemas.Candidate] {
    var clauses: [String] = []
    if !query.title.isEmpty { clauses.append("release:(\(Self.escape(query.title)))") }
    if let artist = query.subtitle, !artist.isEmpty { clauses.append("artist:(\(Self.escape(artist)))") }
    if let catalogueNumber = query.catalogueNumber, !catalogueNumber.isEmpty {
      clauses.append("catno:\"\(Self.escape(catalogueNumber))\"")
    }
    // The year ranks and the subtype filters here, not in the index: MusicBrainz's `date` and `format` fields don't
    // match a bare year or medium reliably, and a filter that misses reads as "no match".
    guard !clauses.isEmpty else { return [] }
    let releases = try await releases(
      .init(
        query: clauses.joined(separator: " AND "),
        fmt: .json,
        limit: min(25, query.limit * (query.subtype == nil ? 3 : 5))
      )
    )
    return releases.compactMap { release in
      if let subtype = query.subtype, Self.subtype(release) != subtype { return nil }
      let year = TextMatch.year(release.date)
      var reasons: [Components.Schemas.Reason] = [.init(kind: query.reason)]
      var confidence: Double
      if query.title.isEmpty {
        // A catalogue number alone: MusicBrainz's own score is all we have.
        confidence = Double(min(max(release.score ?? 0, 0), 100)) / 100 * 0.9
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

  func work(id: String) async throws(SupplierFailure) -> Components.Schemas.Work? {
    let prefix = "musicbrainz:release-group:"
    guard id.hasPrefix(prefix), let mbid = Self.mbid(String(id.dropFirst(prefix.count))) else { return nil }
    let releases = try await releases(
      .init(releaseGroup: mbid, inc: "release-groups media artist-credits", fmt: .json, limit: 100)
    )
    guard let first = releases.first else { return nil }
    let title = TextMatch.clean(first.releaseGroup?.title ?? first.title) ?? first.title
    return .init(
      workID: id,
      title: title,
      releases: releases.compactMap { release in
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

  private func releases(_ query: MusicBrainzAPI.Operations.Releases.Input.Query) async throws(SupplierFailure)
    -> [Release]
  {
    let output = try await connection.call { try await client.releases(query: query) }
    switch output {
    case .ok(let ok): return try await connection.decoded { try ok.body.json.releases }
    case .notFound: return []
    case .undocumented(let status, _): throw .failed("http-\(status / 100)xx")
    }
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
      images: Self.images(release, mbid: mbid),
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

  /// The front cover, from the Cover Art Archive, when the release has one: 500 px and a 250 px thumbnail.
  static func images(_ release: Release, mbid: String) -> [Components.Schemas.Image]? {
    guard release.coverArtArchive?.front == true else { return nil }
    let base = "https://coverartarchive.org/release/\(mbid)/front"
    var images: [Components.Schemas.Image] = []
    if let url = allowedImageURL("\(base)-500", hosts: imageHosts) { images.append(.init(role: .front, url: url)) }
    if let url = allowedImageURL("\(base)-250", hosts: imageHosts) { images.append(.init(role: .thumbnail, url: url)) }
    return images.isEmpty ? nil : images
  }

  static func artist(_ release: Release) -> String? {
    guard let credits = release.artistCredit, !credits.isEmpty else { return nil }
    return credits.map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
  }

  /// MusicBrainz's format names per medium (musicbrainz.org/doc/Release/Format); anything else is Other.
  static let vinylFormats: Set<String> = ["Vinyl", "7\" Vinyl", "10\" Vinyl", "12\" Vinyl", "Flexi-disc"]
  static let cdFormats: Set<String> = [
    "CD", "Enhanced CD", "HDCD", "SHM-CD", "Blu-spec CD", "Copy Control CD", "Data CD", "CD-R", "8cm CD", "Hybrid SACD",
    "SACD",
  ]
  static let cassetteFormats: Set<String> = ["Cassette", "Microcassette"]

  /// The type file's `medium` choice: Vinyl, CD, Cassette or Other.
  static func medium(_ release: Release) -> String {
    let formats = (release.media ?? []).compactMap(\.format)
    if formats.isEmpty { return "Other" }
    if formats.allSatisfy(vinylFormats.contains) { return "Vinyl" }
    if formats.allSatisfy(cdFormats.contains) { return "CD" }
    if formats.allSatisfy(cassetteFormats.contains) { return "Cassette" }
    return "Other"
  }

  /// The subtype, when the release lists its media: an unknown medium is no subtype.
  static func subtype(_ release: Release) -> String? {
    guard release.media?.contains(where: { $0.format != nil }) == true else { return nil }
    switch medium(release) {
    case "Vinyl": return "vinyl"
    case "CD": return "cd"
    case "Cassette": return "cassette"
    default: return "other"
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
      // Two 12-inch discs is a double LP; one could be an LP or a 12" single, so it's left to the collector.
      if formats.isSubset(of: ["12\" Vinyl", "Vinyl"]), count == 2 { return "2×LP" }
      return nil
    default: return nil
    }
  }

  /// Lucene's special characters, escaped, so words from the app stay words in MusicBrainz's query (D-22).
  static func escape(_ text: String) -> String {
    let special: Set<Character> = [
      "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]", "^", "\"", "~", "*", "?", ":", "\\", "/",
    ]
    var escaped = ""
    for character in text.prefix(300) {
      // Any whitespace (tabs, ideographic spaces, newlines) becomes a plain space, so the words split below.
      if character.isWhitespace {
        escaped.append(" ")
        continue
      }
      if special.contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    // AND, OR and NOT are operators only in upper case; lower-casing them keeps them words.
    return escaped.split(separator: " ", omittingEmptySubsequences: true)
      .map { ["AND", "OR", "NOT"].contains($0) ? $0.lowercased() : String($0) }
      .joined(separator: " ")
  }
}
