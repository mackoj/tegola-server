import Foundation
import Logging

@testable import TegolaServer

// Supplier answers for the tests (D-22, D-23). Written by hand from each provider's documented response format, because
// this sandbox can't reach the providers; trimmed to the fields the sources read, plus a few they must ignore.
// Re-record them from the live APIs when a key is at hand (docs/milestones/M3.md).

/// A transport that answers from fixtures and remembers what it was asked. The first route whose `match` the
/// request's URL contains answers; routes can answer differently on later calls.
final class ReplayTransport: HTTPTransport, @unchecked Sendable {
  struct Route {
    var match: String
    var answers: [OutboundResponse]
    var delay: Duration = .zero
  }

  private let lock = NSLock()
  private var routes: [Route]
  private var calls: [String: Int] = [:]
  private(set) var requests: [OutboundRequest] = []

  init(_ routes: [(String, [OutboundResponse])], delays: [String: Duration] = [:]) {
    self.routes = routes.map { Route(match: $0.0, answers: $0.1, delay: delays[$0.0] ?? .zero) }
  }

  convenience init(_ routes: [(String, OutboundResponse)]) {
    self.init(routes.map { ($0.0, [$0.1]) }, delays: [:])
  }

  var sent: [OutboundRequest] { lock.withLock { requests } }

  func send(_ request: OutboundRequest, timeout: Duration, maximumBytes: Int) async throws -> OutboundResponse {
    let (answer, delay) = try lock.withLock {
      requests.append(request)
      guard let route = routes.first(where: { request.url.absoluteString.contains($0.match) }) else {
        throw URLError(.cannotFindHost)
      }
      let index = calls[route.match, default: 0]
      calls[route.match] = index + 1
      return (route.answers[min(index, route.answers.count - 1)], route.delay)
    }
    if delay > .zero { try await Task.sleep(for: delay) }
    return answer
  }
}

/// A 200, labelled as the providers label theirs: JSON with a charset by default, `xml` for BoardGameGeek's
/// `text/xml` (the generated clients refuse a content type their description doesn't declare).
func ok(_ body: String, contentType: String = "application/json; charset=utf-8", headers: [String: String] = [:])
  -> OutboundResponse
{
  OutboundResponse(status: 200, headers: headers.merging(["content-type": contentType]) { $1 }, body: Data(body.utf8))
}

func xml(_ body: String) -> OutboundResponse {
  ok(body, contentType: "text/xml; charset=utf-8")
}

func status(_ code: Int, headers: [String: String] = [:]) -> OutboundResponse {
  OutboundResponse(status: code, headers: headers, body: Data())
}

/// A connection with no pause between requests, for tests.
func testConnection(_ name: String, _ transport: any HTTPTransport, logger: Logger = quietLogger) -> SupplierConnection
{
  SupplierConnection(name: name, transport: transport, interval: .zero, logger: logger)
}

let quietLogger: Logger = {
  var logger = Logger(label: "test")
  logger.logLevel = .critical
  return logger
}()

/// Collects log lines, to check what a source writes.
final class LogCapture: LogHandler, @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .trace

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    let all = metadata.merging(event.metadata ?? [:]) { $1 }
    lock.withLock { lines.append("\(event.message) \(all)") }
  }

  var text: String { lock.withLock { lines.joined(separator: "\n") } }

  var logger: Logger { Logger(label: "capture") { _ in self } }
}

enum Fixture {
  // MARK: MusicBrainz

  static let mbRelease = "8a3a6a2a-1c2b-4c8e-9f5e-0a1b2c3d4e5f"
  static let mbGroup = "1d2e3f40-5a6b-4c7d-8e9f-a0b1c2d3e4f5"

  /// `GET /ws/2/release/?query=barcode:…`: one exact barcode hit, and one near miss the index also returned.
  static let musicBrainzBarcode = """
    {"created":"2026-11-01T00:00:00.000Z","count":2,"offset":0,"releases":[
      {"id":"\(mbRelease)","score":100,"status":"Official","title":"OK Computer","date":"1997-05-21","country":"GB",
       "barcode":"724385522925","track-count":12,
       "artist-credit":[{"name":"Radiohead","artist":{"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":"Radiohead"}}],
       "release-group":{"id":"\(mbGroup)","primary-type":"Album","title":"OK Computer"},
       "label-info":[{"catalog-number":"NODATA 02","label":{"id":"x","name":"Parlophone"}}],
       "media":[{"format":"12\\" Vinyl","disc-count":1,"track-count":6},{"format":"12\\" Vinyl","disc-count":1,"track-count":6}],
       "cover-art-archive":{"artwork":true,"count":3,"front":true,"back":true,"darkened":false}},
      {"id":"00000000-1111-4222-8333-444444444444","score":61,"title":"OK Computer OKNOTOK","date":"2017-06-23",
       "barcode":"634904086528","media":[{"format":"CD"}]}
    ]}
    """

  /// `GET /ws/2/release/?query=release:(…)`: two editions of one album.
  static let musicBrainzSearch = """
    {"count":2,"offset":0,"releases":[
      {"id":"\(mbRelease)","score":100,"title":"OK Computer","date":"1997-05-21","country":"GB",
       "artist-credit":[{"name":"Radiohead"}],"release-group":{"id":"\(mbGroup)","title":"OK Computer"},
       "media":[{"format":"CD"}],"cover-art-archive":{"artwork":true,"count":1,"front":false,"back":true}},
      {"id":"99999999-8888-4777-8666-555555555555","score":90,"title":"OK Computer","date":"2009-03-24",
       "country":"US","artist-credit":[{"name":"Radiohead"}],"release-group":{"id":"\(mbGroup)"},
       "media":[{"format":"CD"},{"format":"CD"}]}
    ]}
    """

  /// `GET /ws/2/release?release-group=…`: the browse a work is built from.
  static let musicBrainzWork = """
    {"release-count":2,"release-offset":0,"releases":[
      {"id":"\(mbRelease)","title":"OK Computer","date":"1997-05-21","country":"GB",
       "release-group":{"id":"\(mbGroup)","title":"OK Computer"},"media":[{"format":"12\\" Vinyl"}]},
      {"id":"99999999-8888-4777-8666-555555555555","title":"OK Computer","date":"2009",
       "release-group":{"id":"\(mbGroup)","title":"OK Computer"},"media":[{"format":"CD"}]}
    ]}
    """

  // MARK: IGDB

  static let twitchToken = #"{"access_token":"TEGOLA-TEST-SENTINEL-token","expires_in":5000000,"token_type":"bearer"}"#

  /// `POST /v4/games` with `search`: one game, released on N64 in two regions, plus a release on a platform the
  /// type has no subtype for.
  static let igdbGames = """
    [{"id":1026,"name":"The Legend of Zelda: Ocarina of Time","first_release_date":911606400,
      "cover":{"id":1,"image_id":"co3nnx"},
      "franchises":[{"id":596,"name":"The Legend of Zelda"}],
      "involved_companies":[{"id":1,"company":{"id":70,"name":"Nintendo"},"publisher":true},
                            {"id":2,"company":{"id":71,"name":"Nintendo EAD"},"publisher":false}],
      "release_dates":[
        {"id":1,"y":1998,"region":5,"platform":{"id":4,"name":"Nintendo 64"}},
        {"id":2,"y":1998,"release_region":{"id":2,"region":"north_america"},"platform":{"id":4,"name":"Nintendo 64"}},
        {"id":3,"y":2011,"release_region":{"id":1,"region":"europe"},"platform":{"id":37,"name":"Nintendo 3DS"}}
      ]}]
    """

  // MARK: ScreenScraper

  /// `GET /api2/jeuRecherche.php`: one game with regional names and dates, and media URLs carrying credentials,
  /// as ScreenScraper's do.
  static let screenScraperSearch = """
    {"header":{"APIversion":"2.0","success":"true"},"response":{"jeux":[
      {"id":"3","noms":[{"region":"ss","text":"Sonic The Hedgehog"},{"region":"jp","text":"Sonic The Hedgehog (JP)"}],
       "systeme":{"id":"1","text":"Megadrive"},"editeur":{"id":"3","text":"SEGA"},
       "dates":[{"region":"us","text":"1991-06-23"},{"region":"jp","text":"1991-07-26"},{"region":"eu","text":"1991"}],
       "medias":[{"type":"box-2D","region":"us","url":"https://neoclone.screenscraper.fr/api2/mediaJeu.php?devid=TEGOLA-TEST-SENTINEL&devpassword=leak&media=box"}]}
    ]}}
    """

  static let screenScraperEmpty = #"{"header":{"success":"true"},"response":{"jeux":[{}]}}"#

  // MARK: BoardGameGeek

  static let bggSearch = """
    <?xml version="1.0" encoding="utf-8"?>
    <items total="3" termsofuse="https://boardgamegeek.com/xmlapi/termsofuse">
      <item type="boardgame" id="31260"><name type="primary" value="Agricola"/><yearpublished value="2007"/></item>
      <item type="boardgame" id="200680"><name type="primary" value="Agricola (Revised Edition)"/><yearpublished value="2016"/></item>
      <item type="boardgame" id="12345"><name type="alternate" value="Agricola: All Creatures Big and Small"/></item>
    </items>
    """

  static let bggThing = """
    <?xml version="1.0" encoding="utf-8"?>
    <items termsofuse="https://boardgamegeek.com/xmlapi/termsofuse">
      <item type="boardgame" id="31260">
        <thumbnail>https://cf.geekdo-images.com/abc__thumb/img/x.jpg</thumbnail>
        <image>https://evil.example.com/tracker.jpg</image>
        <name type="alternate" sortindex="1" value="Agricola: Die Bauern und das liebe Vieh"/>
        <name type="primary" sortindex="1" value="Agricola"/>
        <yearpublished value="2007"/><minplayers value="1"/><maxplayers value="5"/>
        <playingtime value="150"/><minage value="12"/>
        <link type="boardgamedesigner" id="34" value="Uwe Rosenberg"/>
        <link type="boardgamepublisher" id="2" value="Lookout Games"/>
        <link type="boardgamepublisher" id="3" value="Z-Man Games"/>
        <statistics page="1"><ratings><averageweight value="3.6371"/></ratings></statistics>
      </item>
      <item type="boardgameexpansion" id="38733"><name type="primary" value="Agricola: Farmers of the Moor"/></item>
    </items>
    """

}
