import AsyncHTTPClient
package import Foundation
import Logging
import NIOCore
import NIOHTTP1

// What every lookup source shares (PLAN §4, DECISIONS D-22): a transport tests can replace, an outbound pace within
// the provider's terms, a circuit breaker, timeouts, a bounded answer cache, and the text matching that turns a
// provider's answers into ranked candidates.

// MARK: - transport

/// One outbound HTTP request. Sources build these; the transport sends them.
package struct OutboundRequest: Sendable, Equatable {
  package enum Method: String, Sendable { case get = "GET", post = "POST" }

  package var method: Method
  package var url: URL
  package var headers: [String: String]
  package var body: Data?

  package init(method: Method = .get, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

package struct OutboundResponse: Sendable {
  package var status: Int
  package var headers: [String: String]
  package var body: Data

  package init(status: Int, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

/// Sends a request and reads at most `maximumBytes` of the answer. Tests replay recorded answers instead.
package protocol HTTPTransport: Sendable {
  func send(_ request: OutboundRequest, timeout: Duration, maximumBytes: Int) async throws -> OutboundResponse
}

/// The production transport: AsyncHTTPClient on the shared event loop group, HTTPS only.
struct AsyncHTTPTransport: HTTPTransport {
  let client: HTTPClient

  init(client: HTTPClient = .shared) {
    self.client = client
  }

  func send(_ request: OutboundRequest, timeout: Duration, maximumBytes: Int) async throws
    -> OutboundResponse
  {
    guard request.url.scheme == "https" else { throw SourceFailure.refusedURL }
    var outbound = HTTPClientRequest(url: request.url.absoluteString)
    outbound.method = request.method == .get ? .GET : .POST
    for (name, value) in request.headers { outbound.headers.add(name: name, value: value) }
    if let body = request.body { outbound.body = .bytes(ByteBuffer(bytes: body)) }
    let seconds = Int64(timeout.components.seconds)
    let response = try await client.execute(outbound, timeout: .seconds(max(1, seconds)))
    let buffer = try await response.body.collect(upTo: maximumBytes)
    var headers: [String: String] = [:]
    for header in response.headers { headers[header.name.lowercased()] = header.value }
    return OutboundResponse(status: Int(response.status.code), headers: headers, body: Data(buffer.readableBytesView))
  }
}

// MARK: - failures

/// Why a source didn't answer. Logged by case, never with the query; mapped to `SourceUnavailable` (503).
package enum SourceFailure: Error, Equatable {
  /// The provider said 429 or 503, or our own pace would wait too long.
  case busy(retryAfter: Int)
  /// The breaker is open after repeated failures.
  case circuitOpen(retryAfter: Int)
  /// Network error, timeout, a 5xx, or an answer we couldn't read.
  case failed(String)
  /// The credentials were refused (401/403): an operator problem, not the user's.
  case unauthorized
  /// A URL that isn't HTTPS.
  case refusedURL

  var retryAfter: Int {
    switch self {
    case .busy(let seconds), .circuitOpen(let seconds): max(1, seconds)
    case .failed, .refusedURL: 30
    case .unauthorized: 300
    }
  }

  var reason: String {
    switch self {
    case .busy: "busy"
    case .circuitOpen: "circuit-open"
    case .failed(let reason): reason
    case .unauthorized: "unauthorized"
    case .refusedURL: "refused-url"
    }
  }
}

// MARK: - pace

/// Spaces a source's requests at least `interval` apart, across every request the server makes to it. A caller
/// that would wait longer than `maximumWait` is refused with `busy` instead, so a request never hangs on a queue.
actor Pacer {
  let interval: Duration
  let maximumWait: Duration
  private var nextSlot: ContinuousClock.Instant

  init(interval: Duration, maximumWait: Duration) {
    self.interval = interval
    self.maximumWait = maximumWait
    self.nextSlot = .now
  }

  func acquire() async throws {
    let now = ContinuousClock.now
    let slot = max(now, nextSlot)
    let wait = slot - now
    guard wait <= maximumWait else {
      throw SourceFailure.busy(retryAfter: Int(wait.components.seconds) + 1)
    }
    nextSlot = slot + interval
    if wait > .zero { try await Task.sleep(for: wait) }
  }
}

// MARK: - circuit breaker

/// After `threshold` failures in a row, a source is skipped for `coolDown`; one success closes it again.
actor CircuitBreaker {
  let threshold: Int
  let coolDown: Duration
  private var failures = 0
  private var openUntil: ContinuousClock.Instant?

  init(threshold: Int = 5, coolDown: Duration = .seconds(30)) {
    self.threshold = threshold
    self.coolDown = coolDown
  }

  func check() throws {
    guard let openUntil else { return }
    let now = ContinuousClock.now
    if now < openUntil {
      throw SourceFailure.circuitOpen(retryAfter: Int((openUntil - now).components.seconds) + 1)
    }
    self.openUntil = nil  // half-open: the next call decides
  }

  func success() {
    failures = 0
    openUntil = nil
  }

  func failure() {
    failures += 1
    if failures >= threshold { openUntil = .now + coolDown }
  }
}

// MARK: - cache

/// Answers kept in memory, keyed by source, operation and normalised query: a barcode's answer is the same for
/// everyone (PLAN §4). Bounded; the oldest entries go first. Errors are never cached.
actor AnswerCache<Value: Sendable> {
  private struct Entry {
    var value: Value
    var expires: ContinuousClock.Instant
  }

  let capacity: Int
  private var entries: [String: Entry] = [:]
  private var order: [String] = []

  init(capacity: Int = 10_000) {
    self.capacity = max(1, capacity)
  }

  func value(_ key: String) -> Value? {
    guard let entry = entries[key] else { return nil }
    guard entry.expires > .now else {
      entries[key] = nil
      return nil
    }
    return entry.value
  }

  func store(_ value: Value, for key: String, lifetime: Duration) {
    if entries[key] == nil { order.append(key) }
    entries[key] = Entry(value: value, expires: .now + lifetime)
    if entries.count > capacity {
      // Drop the oldest tenth in one go, so eviction stays cheap.
      let drop = max(1, capacity / 10)
      for key in order.prefix(drop) { entries[key] = nil }
      order.removeFirst(min(drop, order.count))
    }
    if order.count > capacity * 2 { order = order.filter { entries[$0] != nil } }
  }

  var count: Int { entries.count }
}

// MARK: - one source's connection

/// A source's way out: its pace, its breaker, its timeout, its size cap, and its logger. Every request goes through
/// `send`, which turns every failure into a `SourceFailure` and counts it.
struct SourceConnection: Sendable {
  let name: String
  let transport: any HTTPTransport
  let pacer: Pacer
  let breaker: CircuitBreaker
  let timeout: Duration
  let maximumBytes: Int
  let logger: Logger

  init(
    name: String,
    transport: any HTTPTransport,
    interval: Duration,
    maximumWait: Duration = .seconds(10),
    timeout: Duration = .seconds(8),
    maximumBytes: Int = 2 * 1024 * 1024,
    logger: Logger
  ) {
    self.name = name
    self.transport = transport
    self.pacer = Pacer(interval: interval, maximumWait: maximumWait)
    self.breaker = CircuitBreaker()
    self.timeout = timeout
    self.maximumBytes = maximumBytes
    self.logger = logger
  }

  /// The body of a 2xx answer, or nil for a 404. Anything else throws a `SourceFailure`.
  func send(_ request: OutboundRequest) async throws(SourceFailure) -> Data? {
    do {
      try await breaker.check()
      try await pacer.acquire()
    } catch let failure as SourceFailure {
      throw failure
    } catch {
      throw .failed("cancelled")
    }
    let response: OutboundResponse
    do {
      response = try await transport.send(request, timeout: timeout, maximumBytes: maximumBytes)
    } catch let failure as SourceFailure {
      await record(failure)
      throw failure
    } catch {
      let failure = SourceFailure.failed("network")
      await record(failure)
      throw failure
    }
    switch response.status {
    case 200..<300:
      await breaker.success()
      return response.body
    case 404:
      await breaker.success()
      return nil
    case 401, 403:
      await record(.unauthorized)
      throw .unauthorized
    // 423, 430 and 431 are ScreenScraper's "closed", "daily quota" and "too many unknown requests".
    case 429, 503, 423, 430, 431:
      let retryAfter =
        response.headers["retry-after"].flatMap { Int($0) } ?? (response.status == 430 ? 3600 : 30)
      let failure = SourceFailure.busy(retryAfter: min(max(retryAfter, 1), 3600))
      await record(failure)
      throw failure
    default:
      let failure = SourceFailure.failed("http-\(response.status / 100)xx")
      await record(failure)
      throw failure
    }
  }

  /// Logs the source and the reason, never the query or the answer.
  func record(_ failure: SourceFailure) async {
    if case .busy = failure {} else { await breaker.failure() }
    logger.warning("source failed", metadata: ["source": "\(name)", "reason": "\(failure.reason)"])
  }

  func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(SourceFailure) -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      logger.warning("source failed", metadata: ["source": "\(name)", "reason": "undecodable"])
      throw .failed("undecodable")
    }
  }
}

// MARK: - text

/// Normalising and comparing titles, so every source ranks its answers the same way (D-22).
enum TextMatch {
  /// Lower case, no diacritics, punctuation as spaces, "&" as "and", collapsed whitespace.
  static func normalise(_ text: String) -> String {
    let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
      .replacingOccurrences(of: "&", with: " and ")
    var result = ""
    var lastWasSpace = true
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        result.unicodeScalars.append(scalar)
        lastWasSpace = false
      } else if !lastWasSpace {
        result.append(" ")
        lastWasSpace = true
      }
    }
    if result.hasSuffix(" ") { result.removeLast() }
    return result
  }

  /// 0…1: how alike two titles are. Exact after normalising is 1; otherwise the Dice coefficient of character
  /// bigrams, so word order and small typos cost little, and a leading article doesn't matter.
  static func similarity(_ lhs: String, _ rhs: String) -> Double {
    let a = stripArticle(normalise(lhs))
    let b = stripArticle(normalise(rhs))
    if a.isEmpty || b.isEmpty { return 0 }
    if a == b { return 1 }
    let x = bigrams(a)
    let y = bigrams(b)
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    var counts: [String: Int] = [:]
    for gram in x { counts[gram, default: 0] += 1 }
    var shared = 0
    for gram in y where (counts[gram] ?? 0) > 0 {
      shared += 1
      counts[gram]! -= 1
    }
    return 2 * Double(shared) / Double(x.count + y.count)
  }

  static func stripArticle(_ text: String) -> String {
    for article in ["the ", "a ", "an ", "le ", "la ", "les ", "l ", "der ", "die ", "das "]
    where text.hasPrefix(article) {
      return String(text.dropFirst(article.count))
    }
    return text
  }

  static func bigrams(_ text: String) -> [String] {
    let characters = Array(text.replacingOccurrences(of: " ", with: ""))
    guard characters.count > 1 else { return characters.map(String.init) }
    return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
  }

  /// The query's confidence for a candidate (D-22): title 70 %, subtitle 20 %, year 10 %, each counted only when
  /// the query gives it, so a title-only query can still reach 1.
  static func confidence(
    title: String,
    candidateTitle: String,
    subtitle: String?,
    candidateSubtitle: String?,
    year: Int?,
    candidateYear: Int?
  ) -> Double {
    var score = 0.7 * similarity(title, candidateTitle)
    var weight = 0.7
    if let subtitle, !subtitle.isEmpty {
      weight += 0.2
      score += 0.2 * (candidateSubtitle.map { similarity(subtitle, $0) } ?? 0)
    }
    if let year {
      weight += 0.1
      if let candidateYear { score += 0.1 * (candidateYear == year ? 1 : abs(candidateYear - year) == 1 ? 0.5 : 0) }
    }
    return min(1, max(0, score / weight))
  }

  /// What to search for: the title, else the first lines of OCR text, else nothing.
  static func queryTitle(title: String?, text: String?) -> String? {
    if let title, !title.allSatisfy(\.isWhitespace) { return title.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let text else { return nil }
    let lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let joined = lines.prefix(3).joined(separator: " ")
    return joined.isEmpty ? nil : String(joined.prefix(200))
  }

  /// Keeps a provider's string within the contract's sizes and free of control characters.
  static func clean(_ text: String?, max: Int = 300) -> String? {
    guard let text else { return nil }
    let cleaned = String(
      String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.unicodeScalars.prefix(max).map(Character.init))
  }

  /// The year of an ISO date ("1997-05-21", "1997"), if it has one.
  static func year(_ date: String?) -> Int? {
    guard let date, date.count >= 4, let year = Int(date.prefix(4)), (1800...2100).contains(year) else { return nil }
    return year
  }
}

/// An image URL a source gave us, kept only when it's HTTPS on one of the hosts we expect (D-22).
func allowedImageURL(_ raw: String?, hosts: Set<String>) -> String? {
  guard var raw, !raw.isEmpty else { return nil }
  if raw.hasPrefix("//") { raw = "https:" + raw }
  guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
    hosts.contains(host), url.user == nil, url.password == nil, url.query == nil
  else { return nil }
  return url.absoluteString
}
