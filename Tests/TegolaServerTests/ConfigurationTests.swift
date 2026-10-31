import AppAttest
import Testing

@testable import TegolaServer

@Suite("Configuration")
struct ConfigurationTests {
  // TEGOLA-TEST-SENTINEL: a fake password in a test URL.
  static let databaseURL = "postgres://tegola:secret@db.internal:5432/tegola"
  static let production = ["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola", "TEGOLA_DATABASE_URL": databaseURL]

  static func with(_ overrides: [String: String], base: [String: String] = production) -> [String: String] {
    base.merging(overrides) { $1 }
  }

  @Test func defaultsToProductionOnLoopback() throws {
    let configuration = try ServerConfiguration.load(from: Self.production)
    #expect(configuration.environment == .production)
    #expect(configuration.host == "127.0.0.1")
    #expect(configuration.trustedProxyHops == 0)
    #expect(configuration.allowedAttestEnvironments == [.production])
    #expect(configuration.database?.host == "db.internal")
  }

  /// Each case is refused for its own reason: the message names the setting.
  @Test(arguments: [
    ([:], "TEGOLA_APP_ID"),
    (with(["TEGOLA_APP_ID": "fr.macko.tegola"]), "TEGOLA_APP_ID"),
    (with(["TEGOLA_ENVIRONMENT": "staging"]), "TEGOLA_ENVIRONMENT"),
    (with(["TEGOLA_PORT": "0"]), "TEGOLA_PORT"),
    (with(["TEGOLA_TRUSTED_PROXY_HOPS": "-1"]), "TEGOLA_TRUSTED_PROXY_HOPS"),
    // A debug token never reaches production, even by mistake.
    (with(["TEGOLA_DEBUG_TOKEN": String(repeating: "x", count: 40)]), "TEGOLA_DEBUG_TOKEN"),
    // Too short to resist guessing.
    (with(["TEGOLA_ENVIRONMENT": "development", "TEGOLA_DEBUG_TOKEN": "short"]), "TEGOLA_DEBUG_TOKEN"),
    // Production without a database would forget every key at each restart (D-17).
    (["TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola"], "TEGOLA_DATABASE_URL"),
    (with(["TEGOLA_DATABASE_URL": "mysql://tegola@db/tegola"]), "TEGOLA_DATABASE_URL"),
    (with(["TEGOLA_DATABASE_URL": "postgres://db.internal/tegola"]), "TEGOLA_DATABASE_URL"),
    (with(["TEGOLA_DATABASE_URL": "postgres://tegola@db.internal/"]), "TEGOLA_DATABASE_URL"),
    (with(["TEGOLA_DATABASE_URL": "postgres://tegola@db.internal/tegola?sslmode=prefer"]), "sslmode"),
    (with(["TEGOLA_DATABASE_URL": "postgres://tegola@db.internal/tegola?options=x"]), "unknown parameter"),
  ])
  func refusesToStart(_ env: [String: String], _ reason: String) {
    #expect {
      try ServerConfiguration.load(from: env)
    } throws: { error in
      (error as? ConfigurationError)?.description.contains(reason) == true
    }
  }

  @Test func developmentWithADebugTokenAndNoDatabase() throws {
    let configuration = try ServerConfiguration.load(from: [
      "TEGOLA_APP_ID": "ABCDE12345.fr.macko.tegola",
      "TEGOLA_ENVIRONMENT": "development",
      "TEGOLA_DEBUG_TOKEN": String(repeating: "x", count: 32),
    ])
    #expect(configuration.allowedAttestEnvironments == [.production, .development])
    #expect(configuration.database == nil)
  }

  @Test func databaseURL() throws {
    let settings = try DatabaseSettings.parse("postgresql://te%40gola:p%3Ass@db.internal:6543/tegola_prod")
    #expect(settings.username == "te@gola")
    #expect(settings.password == "p:ss")
    #expect(settings.port == 6543)
    #expect(settings.database == "tegola_prod")
    // Verified TLS unless the URL says otherwise.
    #expect(settings.tls == .verifyFull)
    #expect(try DatabaseSettings.parse("postgres://u@h/d?sslmode=disable").tls == .disable)
    let withCA = try DatabaseSettings.parse("postgres://u@h/d?sslmode=verify-full&sslrootcert=/etc/ca.pem")
    #expect(withCA.rootCertificatePath == "/etc/ca.pem")
  }

  /// The settings can be logged: the password is never in their description.
  @Test func databaseSettingsNeverPrintThePassword() throws {
    let settings = try DatabaseSettings.parse(Self.databaseURL)
    #expect(!settings.description.contains("secret"))
    #expect(!"\(settings)".contains("secret"))
    #expect(!String(reflecting: settings).contains("secret"))
    var dumped = ""
    dump(settings, to: &dumped)
    #expect(!dumped.contains("secret"))
  }
}
