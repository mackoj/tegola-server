/// The video-game type's subtypes (tegola's `video-game.yml`), with the names IGDB and ScreenScraper give their
/// platforms, so a subtype filters a search and a platform sets a candidate's subtype (D-22).
enum VideoGamePlatforms {
  struct Platform {
    var subtype: String
    /// The `platform` field's value, as the type file presets it.
    var name: String
    var igdbNames: Set<String>
    var screenScraperSystem: Int
  }

  static let all: [Platform] = [
    .init(subtype: "saturn", name: "Sega Saturn", igdbNames: ["sega saturn"], screenScraperSystem: 22),
    .init(subtype: "n64", name: "Nintendo 64", igdbNames: ["nintendo 64"], screenScraperSystem: 14),
    .init(
      subtype: "neo-geo",
      name: "Neo Geo",
      igdbNames: ["neo geo aes", "neo geo mvs", "neo geo"],
      screenScraperSystem: 142
    ),
    .init(subtype: "game-boy", name: "Game Boy", igdbNames: ["game boy"], screenScraperSystem: 9),
    .init(subtype: "ps1", name: "PlayStation", igdbNames: ["playstation"], screenScraperSystem: 57),
  ]

  static func platform(subtype: String?) -> Platform? {
    guard let subtype else { return nil }
    return all.first { $0.subtype == subtype }
  }

  static func subtype(igdbName: String?) -> String? {
    guard let igdbName else { return nil }
    let name = TextMatch.normalise(igdbName)
    return all.first { $0.igdbNames.contains(name) }?.subtype
  }

  static func subtype(screenScraperSystem: Int?) -> String? {
    guard let screenScraperSystem else { return nil }
    return all.first { $0.screenScraperSystem == screenScraperSystem }?.subtype
  }

  /// The type file's `region` choice from a source's region: NTSC-U, NTSC-J or PAL. A worldwide release says
  /// nothing about the copy's region, so it maps to nothing.
  static func region(_ raw: String?) -> String? {
    switch raw?.lowercased() {
    case "north_america", "us", "usa", "ca", "2": "NTSC-U"
    case "japan", "jp", "5": "NTSC-J"
    case "europe", "australia", "new_zealand", "eu", "fr", "de", "uk", "sp", "it", "nl", "au", "se", "pt", "1", "3",
      "4":
      "PAL"
    default: nil
    }
  }

  /// Whether a candidate's region fits the one asked for. A region the app wrote differently (an ISO country) is
  /// not used to filter: it's only a hint.
  static func fits(region candidate: String?, asked: String?) -> Bool {
    guard let asked, ["NTSC-U", "NTSC-J", "PAL"].contains(asked) else { return true }
    guard let candidate else { return true }
    return candidate == asked
  }
}
