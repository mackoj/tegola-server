import Logging

/// The sources the settings turn on, each with its own connection: pace, breaker, timeout (D-22).
func makeLookupService(
  _ settings: SourceSettings,
  transport: any HTTPTransport,
  logger: Logger
) -> SourcesLookupService {
  var sourceLogger = logger
  sourceLogger[metadataKey: "component"] = "source"
  var sources: [any CatalogueSource] = []
  if let contact = settings.musicBrainzContact {
    sources.append(
      MusicBrainzSource(
        connection: SourceConnection(
          name: "musicbrainz",
          transport: transport,
          interval: .milliseconds(1100),
          logger: sourceLogger
        ),
        userAgent: "tegola-server/1.0 ( \(contact) )"
      )
    )
  }
  if let igdb = settings.igdb {
    sources.append(
      IGDBSource(
        connection: SourceConnection(
          name: "igdb",
          transport: transport,
          interval: .milliseconds(260),
          logger: sourceLogger
        ),
        tokens: TwitchTokens(
          clientID: igdb.id,
          clientSecret: igdb.secret,
          connection: SourceConnection(
            name: "twitch",
            transport: transport,
            interval: .milliseconds(500),
            logger: sourceLogger
          )
        )
      )
    )
  }
  if let screenScraper = settings.screenScraper {
    sources.append(
      ScreenScraperSource(
        connection: SourceConnection(
          name: "screenscraper",
          transport: transport,
          interval: .milliseconds(1200),
          logger: sourceLogger
        ),
        credentials: ScreenScraperCredentials(
          developerID: screenScraper.developerID,
          developerPassword: screenScraper.developerPassword,
          user: screenScraper.user,
          password: screenScraper.password
        )
      )
    )
  }
  if let token = settings.boardGameGeekToken {
    sources.append(
      BoardGameGeekSource(
        connection: SourceConnection(
          name: "boardgamegeek",
          transport: transport,
          interval: .seconds(2),
          maximumWait: .seconds(12),
          logger: sourceLogger
        ),
        token: token
      )
    )
  }
  return SourcesLookupService(sources: sources)
}
