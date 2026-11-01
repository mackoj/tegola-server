import Foundation

/// The releases and scenarios a development server answers from in mock mode (D-28): `TEGOLA_MOCKS` names the file,
/// `mocks/catalogue.json` is the one in the repo, and `mocks/README.md` describes it. Read once at start-up and
/// checked like any setting: a file that can't be read or breaks a rule stops the server (fail closed).
public struct MockCatalogue: Sendable, Decodable {
  /// How long every mock answer takes, so the app's loading states show. 0–5000 ms.
  var latencyMs: Int
  var releases: [Release]
  var scenarios: [Scenario]

  /// One release, as a source would describe it. `id` and `work` are short slugs; the server prefixes them
  /// (`mock:<type>:<id>`, `mock:<type>:work:<work>`).
  struct Release: Sendable, Decodable {
    var type: String
    var id: String
    var work: String?
    var title: String
    var subtitle: String?
    var year: Int?
    var subtype: String?
    var region: String?
    var barcodes: [String]?
    /// The type file's field keys.
    var fields: [String: Components.Schemas.FieldValue]?
    /// List fields (a tracklist), by key.
    var entries: [String: [[String: String?]]]?
  }

  /// What a barcode or a title (compared folded: case, accents, punctuation) does instead of a lookup, so the app
  /// can test its other paths.
  struct Scenario: Sendable, Decodable {
    enum Outcome: String, Sendable, Decodable {
      /// `503` with `Retry-After`, as a source that's down.
      case unavailable
      /// No candidates: "no match".
      case nothing
      /// The normal answer, after `delayMs`.
      case slow
    }

    var barcode: String?
    var title: String?
    var outcome: Outcome
    var retryAfter: Int?
    var delayMs: Int?
  }

  enum CodingKeys: String, CodingKey {
    case latencyMs, releases, scenarios
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 150
    releases = try container.decode([Release].self, forKey: .releases)
    scenarios = try container.decodeIfPresent([Scenario].self, forKey: .scenarios) ?? []
  }

  init(latencyMs: Int = 0, releases: [Release] = [], scenarios: [Scenario] = []) {
    self.latencyMs = latencyMs
    self.releases = releases
    self.scenarios = scenarios
  }

  /// For the start-up log.
  public var summary: String { "mock (\(releases.count) releases, \(scenarios.count) scenarios)" }

  /// The types the mock providers answer for: tegola's four v1 types (D-22), and any other the file uses.
  var types: [String] {
    var types = ["music", "video-game", "board-games", "thing"]
    for release in releases where !types.contains(release.type) { types.append(release.type) }
    return types
  }

  /// Reads and checks a catalogue file.
  static func load(path: String) throws(ConfigurationError) -> MockCatalogue {
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
      throw .invalid("TEGOLA_MOCKS: \(path) can't be read")
    }
    let catalogue: MockCatalogue
    do { catalogue = try JSONDecoder().decode(MockCatalogue.self, from: data) } catch {
      throw .invalid("TEGOLA_MOCKS: \(path) isn't a mock catalogue (\(Self.describe(error)))")
    }
    if let problem = catalogue.problem() { throw .invalid("TEGOLA_MOCKS: \(path): \(problem)") }
    return catalogue
  }

  /// Where a decoding error is, without the file's content.
  static func describe(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return "not JSON" }
    let path: [any CodingKey]
    switch error {
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
      path = context.codingPath
    case .keyNotFound(let key, let context): path = context.codingPath + [key]
    @unknown default: path = []
    }
    let at = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    return at.isEmpty ? "not JSON" : "at \(at)"
  }

  /// The first rule a catalogue breaks, if any: the contract's limits, so a mock answer is one the app can get from
  /// a real source.
  func problem() -> String? {
    guard (0...5000).contains(latencyMs) else { return "latencyMs must be 0–5000" }
    func slug(_ value: String) -> Bool { value.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,59}/) != nil }
    var seen = Set<String>()
    for (index, release) in releases.enumerated() {
      let at = "releases.\(index)"
      guard release.type.wholeMatch(of: /[a-z][a-z0-9-]{1,40}/) != nil else { return "\(at).type isn't a type id" }
      guard slug(release.id) else { return "\(at).id must be a slug: a-z, 0-9 and -, at most 60" }
      guard seen.insert("\(release.type)/\(release.id)").inserted else { return "\(at).id is used twice" }
      if let work = release.work, !slug(work) { return "\(at).work must be a slug" }
      guard !release.title.allSatisfy(\.isWhitespace), release.title.count <= 300 else {
        return "\(at).title must be 1–300 characters"
      }
      if let subtitle = release.subtitle, subtitle.count > 300 { return "\(at).subtitle is over 300 characters" }
      if let year = release.year, !TextMatch.years.contains(year) { return "\(at).year must be 1800–2100" }
      if let subtype = release.subtype, subtype.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,40}/) == nil {
        return "\(at).subtype isn't a subtype key"
      }
      if let region = release.region, region.count > 16 { return "\(at).region is over 16 characters" }
      for code in release.barcodes ?? [] where code.wholeMatch(of: /[0-9A-Za-z-]{6,32}/) == nil {
        return "\(at).barcodes has a code that isn't 6–32 letters, digits or -"
      }
    }
    for (index, scenario) in scenarios.enumerated() {
      let at = "scenarios.\(index)"
      guard (scenario.barcode == nil) != (scenario.title == nil) else { return "\(at) needs a barcode or a title" }
      if let retryAfter = scenario.retryAfter, !(1...3600).contains(retryAfter) {
        return "\(at).retryAfter must be 1–3600"
      }
      if let delay = scenario.delayMs, !(0...20_000).contains(delay) { return "\(at).delayMs must be 0–20000" }
    }
    return nil
  }

  /// The scenario for a barcode or a title, if there's one.
  func scenario(barcode: String) -> Scenario? {
    scenarios.first { $0.barcode == barcode }
  }

  func scenario(title: String) -> Scenario? {
    let folded = TextMatch.normalise(title)
    guard !folded.isEmpty else { return nil }
    return scenarios.first { $0.title.map(TextMatch.normalise) == folded }
  }
}
