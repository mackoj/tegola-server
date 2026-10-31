import AppAttest
import Testing

@testable import TegolaServer

@Suite("Configuration")
struct ConfigurationTests {
  @Test func defaultsToProductionOnLoopback() throws {
    let configuration = try ServerConfiguration.load(from: ["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola"])
    #expect(configuration.environment == .production)
    #expect(configuration.host == "127.0.0.1")
    #expect(configuration.trustedProxyHops == 0)
    #expect(configuration.allowedAttestEnvironments == [.production])
  }

  @Test(arguments: [
    [:],
    ["TEGOLA_APP_ID": "fr.macko.tegola"],
    ["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_ENVIRONMENT": "staging"],
    ["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_PORT": "0"],
    ["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_TRUSTED_PROXY_HOPS": "-1"],
    // A debug token never reaches production, even by mistake.
    ["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_DEBUG_TOKEN": String(repeating: "x", count: 40)],
    // Too short to resist guessing.
    [
      "TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_ENVIRONMENT": "development",
      "TEGOLA_DEBUG_TOKEN": "short",
    ],
  ])
  func refusesToStart(_ env: [String: String]) {
    #expect(throws: ConfigurationError.self) { try ServerConfiguration.load(from: env) }
  }

  @Test func developmentWithADebugToken() throws {
    let configuration = try ServerConfiguration.load(from: [
      "TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola",
      "TEGOLA_ENVIRONMENT": "development",
      "TEGOLA_DEBUG_TOKEN": String(repeating: "x", count: 32),
    ])
    #expect(configuration.allowedAttestEnvironments == [.production, .development])
  }
}
