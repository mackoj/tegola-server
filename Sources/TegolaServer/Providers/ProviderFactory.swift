import Logging

/// The sources the settings turn on, each with its own connection: pace, breaker, timeout (D-22); Wikidata's
/// profiles share one (D-26).
func makeLookupService(
  _ settings: SourceSettings,
  transport: any HTTPTransport,
  logger: Logger
) -> LookupRouter {
  var sourceLogger = logger
  sourceLogger[metadataKey: "component"] = "source"
  var sources: [any DataProvider] = []
  if let contact = settings.musicBrainzContact {
    sources.append(
      MusicBrainzProvider(
        connection: ProviderConnection(
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
      IGDBProvider(
        connection: ProviderConnection(
          name: "igdb",
          transport: transport,
          interval: .milliseconds(260),
          logger: sourceLogger
        ),
        tokens: TwitchTokens(
          clientID: igdb.id,
          clientSecret: igdb.secret,
          connection: ProviderConnection(
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
      ScreenScraperProvider(
        connection: ProviderConnection(
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
      BoardGameGeekProvider(
        connection: ProviderConnection(
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
  if let contact = settings.wikidataContact {
    // One connection for every type's profile: Wikidata sees one client, one request at a time (D-26). Items with
    // their statements are large, hence the bigger cap.
    let connection = ProviderConnection(
      name: "wikidata",
      transport: transport,
      interval: .milliseconds(500),
      maximumBytes: 8 * 1024 * 1024,
      logger: sourceLogger
    )
    for profile in WikidataProfile.all {
      sources.append(
        WikidataProvider(profile: profile, connection: connection, userAgent: "tegola-server/1.0 ( \(contact) )")
      )
    }
  }
  return LookupRouter(sources: sources, logger: sourceLogger)
}

/// Mock mode (D-28): one mock provider per type, behind the same router as the real sources, so ranking, merging,
/// caching and failures behave as they will in production.
func makeMockLookupService(_ catalogue: MockCatalogue, logger: Logger) -> LookupRouter {
  var sourceLogger = logger
  sourceLogger[metadataKey: "component"] = "source"
  return LookupRouter(
    sources: catalogue.types.map { MockProvider(typeID: $0, catalogue: catalogue) },
    logger: sourceLogger
  )
}
