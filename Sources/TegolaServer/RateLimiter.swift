public import Foundation
import NIOCore

/// Token buckets keyed by client (see `RateLimitKey`) or App Attest key id. In memory, per process (DECISIONS D-9).
///
/// The table is bounded. Past `maximumKeys`, full (idle) buckets are dropped first; if that isn't enough, the tenth
/// least recently used are evicted (D-19). Refusing every new client instead would let a spray of addresses lock
/// everyone out; evicting only hands the oldest entries a fresh bucket.
public actor RateLimiter {
  private struct Bucket {
    var tokens: Double
    var updated: Date
  }

  private var buckets: [String: Bucket] = [:]
  private let limit: RateLimit
  private let maximumKeys: Int
  private let now: @Sendable () -> Date

  public init(limit: RateLimit, maximumKeys: Int = 200_000, now: @escaping @Sendable () -> Date = { Date() }) {
    self.limit = limit
    self.maximumKeys = maximumKeys
    self.now = now
  }

  public enum Decision: Equatable, Sendable {
    case allowed
    /// Seconds until enough tokens are back, at least 1.
    case limited(retryAfter: Int)
  }

  /// Takes `cost` tokens (a batch of 50 match rows costs 50), or none and says how long to wait.
  public func take(_ key: String, cost: Double = 1) -> Decision {
    let current = now()
    var bucket = buckets[key] ?? Bucket(tokens: limit.capacity, updated: current)
    let elapsed = max(0, current.timeIntervalSince(bucket.updated))
    bucket.tokens = min(limit.capacity, bucket.tokens + elapsed * limit.refillPerSecond)
    bucket.updated = current
    // A cost above the capacity could never be paid: it waits for a full bucket and takes all of it.
    let price = min(cost, limit.capacity)
    guard bucket.tokens >= price else {
      buckets[key] = bucket
      let wait = (price - bucket.tokens) / limit.refillPerSecond
      return .limited(retryAfter: max(1, Int(wait.rounded(.up))))
    }
    bucket.tokens -= price
    if buckets[key] == nil, buckets.count >= maximumKeys { makeRoom(at: current) }
    buckets[key] = bucket
    return .allowed
  }

  var count: Int { buckets.count }

  private func makeRoom(at current: Date) {
    buckets = buckets.filter { _, bucket in
      bucket.tokens + current.timeIntervalSince(bucket.updated) * limit.refillPerSecond < limit.capacity
    }
    guard buckets.count >= maximumKeys else { return }
    let evict = max(1, maximumKeys / 10)
    for key in buckets.sorted(by: { $0.value.updated < $1.value.updated }).prefix(evict).map(\.key) {
      buckets.removeValue(forKey: key)
    }
  }
}

/// The key a client's requests are counted under (D-19): its IPv4 address, or the /64 of its IPv6 address. One IPv6
/// subscriber usually holds a whole /64 (18 billion billion addresses), so counting per address would give each of
/// them unlimited buckets. An IPv4-mapped IPv6 address counts as its IPv4 address.
enum RateLimitKey {
  static func client(_ address: String) -> String {
    guard address.contains(":"), let socket = try? SocketAddress(ipAddress: address, port: 0) else { return address }
    guard case .v6(let v6) = socket else { return socket.ipAddress ?? address }
    let bytes = withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
      return bytes[12..<16].map(String.init).joined(separator: ".")
    }
    return bytes[0..<8].map { String(format: "%02x", $0) }.joined() + "::/64"
  }
}
