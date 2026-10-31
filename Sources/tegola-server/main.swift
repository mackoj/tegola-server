import Foundation
import Hummingbird
import Logging
import PostgresNIO
import TegolaServer

// Reads TEGOLA_* from the environment (README "Configuration"), refuses to start on an unsafe setting, and serves
// until SIGTERM or SIGINT. TLS is terminated by the reverse proxy in front (DECISIONS D-10).
//
// Exit codes: 78 (EX_CONFIG) for a setting that's missing or unsafe; 1 for anything that stops the server after the
// settings were accepted (a database that can't be reached or migrated, a CA file that can't be read). Either way
// the reason is logged first, without secrets (D-19).
LoggingSystem.bootstrap { label in
  var handler = StreamLogHandler.standardOutput(label: label)
  handler.logLevel = ProcessInfo.processInfo.environment["LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .info
  return handler
}
let logger = Logger(label: "tegola-server")

let configuration: ServerConfiguration
do {
  configuration = try ServerConfiguration.load()
} catch {
  logger.critical("refusing to start: \(error.description)")
  exit(78)  // EX_CONFIG
}

/// What an operator needs, and nothing that could hold a secret: a PSQLError's code and the server's own message and
/// SQLSTATE (never the query's bound values or the connection's password); other errors by type and description.
func reason(_ error: any Error) -> String {
  if let error = error as? PSQLError {
    let message = error.serverInfo?[.message] ?? "no server message"
    let state = error.serverInfo?[.sqlState] ?? "-"
    return "database: \(error.code) (SQLSTATE \(state)): \(message)"
  }
  return "\(String(reflecting: type(of: error))): \(error)"
}

do {
  let app = try buildApplication(configuration: configuration, logger: logger)
  logger.info(
    "starting",
    metadata: [
      "environment": "\(configuration.environment.rawValue)",
      "address": "\(configuration.host):\(configuration.port)",
      "database": "\(configuration.database.map(\.description) ?? "in memory")",
    ]
  )
  try await app.runService()
} catch {
  logger.critical("stopped: \(reason(error))")
  exit(1)
}
