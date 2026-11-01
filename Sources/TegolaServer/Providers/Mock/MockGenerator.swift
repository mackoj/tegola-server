import Foundation

/// Made-up releases for words and codes the mock catalogue doesn't have (D-28). The same input always makes the same
/// release, on every run and machine, filled with the type file's field keys, so the app can fill a form from it.
/// The names are invented; the source says "Mock".
struct MockGenerator {
  let typeID: String
  let idPrefix: String
  let source: Components.Schemas.Source

  /// What the query asked for, which a made-up release honours.
  struct Asked {
    var title: String?
    var subtitle: String?
    var year: Int?
    var subtype: String?
    var region: String?
  }

  /// A made-up release: edition 0 is the main one; edition 1 is the same title in another subtype, region or year.
  func release(slug: String, edition: Int, asked: Asked) -> ProviderRecord {
    var random = SplitMix(seed: Self.hash(typeID + "/" + slug))
    let words = Self.words(typeID)
    let title = TextMatch.clean(asked.title) ?? random.title(words)
    let subtypes = asked.subtype.map { [$0] } ?? words.subtypes
    let subtype = subtypes.isEmpty ? nil : subtypes[(random.next(subtypes.count) + edition) % subtypes.count]
    let regions = asked.region.map { [$0] } ?? words.regions
    let region = regions.isEmpty ? nil : regions[(random.next(regions.count) + edition) % regions.count]
    let baseYear = asked.year ?? (words.firstYear + random.next(30))
    // A second edition with nothing else to tell it apart comes out a few years later.
    let apart = subtypes.count > 1 || regions.count > 1 || asked.year != nil
    let year = baseYear + (apart ? 0 : edition * 3)
    let maker = random.pick(words.makers)
    var fields: [String: Components.Schemas.FieldValue] = [:]
    var entries: [String: [[String: String?]]] = [:]
    var subtitle = asked.subtitle.flatMap { TextMatch.clean($0) }
    switch typeID {
    case "music":
      subtitle = subtitle ?? maker
      let medium = ["vinyl": "Vinyl", "cd": "CD", "cassette": "Cassette"][subtype ?? ""] ?? "Other"
      fields["medium"] = .case1(medium)
      if let format = ["Vinyl": "LP", "CD": "CD", "Cassette": "Cassette"][medium] { fields["format"] = .case1(format) }
      fields["label"] = .case1(random.pick(["Lantern Records", "Northwind", "Copperline Music", "Moth & Field"]))
      fields["catalogNumber"] = .case1("MOCK-\(1000 + random.next(9000))")
      if let region { fields["country"] = .case1(region) }
      entries["tracklist"] = (1...(6 + random.next(5))).map { position in
        [
          "position": "\(position)", "title": random.title(words),
          "duration": "\(2 + random.next(5)):\(String(format: "%02d", random.next(60)))",
        ]
      }
    case "video-game":
      let platform = VideoGamePlatforms.platform(subtype: subtype)?.name
      subtitle = subtitle ?? platform
      if let platform { fields["platform"] = .case1(platform) }
      fields["publisher"] = .case1(maker)
      if let region { fields["region"] = .case1(region) }
      fields["media"] = .case1(["ps1", "saturn"].contains(subtype ?? "") ? "Optical disc" : "Cartridge")
    case "board-games":
      subtitle = subtitle ?? maker
      fields["designer"] = .case1(random.pick(["A. Moreau", "K. Lindqvist", "R. Okafor", "M. Tanaka", "S. Ferreira"]))
      fields["players"] = .case1(random.pick(["2–4", "1–5", "2–6", "3–5", "2"]))
      fields["playTime"] = .case2(Double(30 + 15 * random.next(10)))
      fields["minAge"] = .case2(Double(random.pick([8, 10, 12, 14])))
      fields["weight"] = .case2(Double(15 + random.next(26)) / 10)
    default:
      subtitle = subtitle ?? maker
      fields["material"] = .case1(random.pick(["Enamel", "Tin", "Ceramic", "Wood", "Glass"]))
    }
    return ProviderRecord(
      provider: "mock",
      releaseID: "\(idPrefix)gen:\(slug):\(edition)",
      workID: "\(idPrefix)gen:\(slug)",
      typeID: typeID,
      subtype: subtype,
      title: title,
      subtitle: subtitle,
      year: TextMatch.years.contains(year) ? year : nil,
      region: region,
      fields: fields,
      entries: entries,
      externalIDs: ["mock": "\(typeID):gen:\(slug):\(edition)"],
      identifying: ["mock"],
      source: source
    )
  }

  /// A made-up work: its two editions, titled from its slug (words) or made up again (a code).
  func work(slug: String) -> Components.Schemas.Work {
    let title =
      slug.hasPrefix("code-")
      ? nil : slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    let editions = (0..<2).map { release(slug: slug, edition: $0, asked: .init(title: title)) }
    return .init(
      workID: "\(idPrefix)gen:\(slug)",
      title: editions[0].title,
      releases: editions.map {
        .init(
          releaseID: $0.releaseID,
          typeID: typeID,
          subtype: $0.subtype,
          title: $0.title,
          year: $0.year,
          region: $0.region
        )
      }
    )
  }

  // MARK: - words

  struct Words {
    var first: [String]
    var second: [String]
    var makers: [String]
    var subtypes: [String]
    var regions: [String]
    var firstYear: Int
  }

  static func words(_ typeID: String) -> Words {
    switch typeID {
    case "music":
      Words(
        first: ["Velvet", "Electric", "Silent", "Golden", "Paper", "Neon", "Hollow", "Crimson", "Distant", "Midnight"],
        second: ["Horizons", "Gardens", "Machines", "Rivers", "Signals", "Lanterns", "Echoes", "Harbours", "Mirrors"],
        makers: ["The Paper Lanterns", "Marlowe Vane", "Quiet Harbour", "Juniper Static", "Ada Kestrel"],
        subtypes: ["cd", "vinyl", "cassette"],
        regions: ["GB", "US", "FR", "DE", "JP"],
        firstYear: 1965
      )
    case "video-game":
      Words(
        first: ["Star", "Dungeon", "Turbo", "Pixel", "Shadow", "Crystal", "Rocket", "Lantern"],
        second: ["Quest", "Racer", "Legends", "Odyssey", "Tactics", "Rally", "Saga", "Arena"],
        makers: ["Kestrel Works", "Bluefin Games", "Ironleaf", "Copperline Interactive", "Moonlit Arcade"],
        subtypes: VideoGamePlatforms.all.map(\.subtype),
        regions: ["PAL", "NTSC-U", "NTSC-J"],
        firstYear: 1989
      )
    case "board-games":
      Words(
        first: ["Harbor", "Orchard", "Caravan", "Lantern", "Meadow", "Glacier"],
        second: ["Traders", "Builders", "Kingdoms", "Expedition", "Guilds", "Harvest"],
        makers: ["Lantern Table", "Meadow Games", "Orchard Press", "Fennel & Co"],
        subtypes: [],
        regions: [],
        firstYear: 1995
      )
    default:
      Words(
        first: ["Ceramic", "Enamel", "Tin", "Wooden", "Glass", "Paper"],
        second: ["Fox", "Lighthouse", "Robot", "Teapot", "Badge", "Whale"],
        makers: ["Studio Fennel", "Atelier Brume", "Hollow Oak", "Tinker & Finch"],
        subtypes: [],
        regions: [],
        firstYear: 1970
      )
    }
  }

  /// FNV-1a, 64 bits: the same on every run and machine, unlike `Hasher`.
  static func hash(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }

  /// A small seeded generator (SplitMix64), so a made-up release is the same every time.
  struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
      state &+= 0x9e37_79b9_7f4a_7c15
      var z = state
      z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
      z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
      return z ^ (z >> 31)
    }

    /// 0..<bound.
    mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

    mutating func pick<T>(_ values: [T]) -> T { values[next(values.count)] }

    mutating func title(_ words: Words) -> String { pick(words.first) + " " + pick(words.second) }
  }
}
