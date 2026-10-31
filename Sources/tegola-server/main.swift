import Foundation
import Hummingbird
import Logging
import TegolaServer

// Reads TEGOLA_* from the environment (README "Configuration"), refuses to start on an unsafe setting, and serves
// until SIGTERM or SIGINT. TLS is terminated by the reverse proxy in front (DECISIONS D-10).
LoggingSystem.bootstrap { label in
  var handler = StreamLogHandler.standardOutput(label: label)
  handler.logLevel = ProcessInfo.processInfo.environment["LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .info
  return handler
}
var logger = Logger(label: "tegola-server")

let configuration: ServerConfiguration
do {
  configuration = try ServerConfiguration.load()
} catch {
  logger.critical("refusing to start: \(error.description)")
  exit(78)  // EX_CONFIG
}

let app = try buildApplication(configuration: configuration, logger: logger)
logger.info(
  "starting",
  metadata: [
    "environment": "\(configuration.environment.rawValue)",
    "address": "\(configuration.host):\(configuration.port)",
  ]
)
try await app.runService()
