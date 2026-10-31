public import Foundation

/// Token buckets keyed by IP or App Attest key id. In memory, per process (DECISIONS D-9). The table is bounded: past
/// `maximumKeys`, full (idle) buckets are dropped first, and if that isn't enough the request is refused, so a spray
/// of addresses can't grow it without limit.
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
    /// Seconds until a token is back, at least 1.
    case limited(retryAfter: Int)
  }

  public func take(_ key: String) -> Decision {
    let current = now()
    var bucket = buckets[key] ?? Bucket(tokens: limit.capacity, updated: current)
    let elapsed = max(0, current.timeIntervalSince(bucket.updated))
    bucket.tokens = min(limit.capacity, bucket.tokens + elapsed * limit.refillPerSecond)
    bucket.updated = current
    guard bucket.tokens >= 1 else {
      buckets[key] = bucket
      let wait = (1 - bucket.tokens) / limit.refillPerSecond
      return .limited(retryAfter: max(1, Int(wait.rounded(.up))))
    }
    bucket.tokens -= 1
    if buckets[key] == nil, buckets.count >= maximumKeys {
      prune(at: current)
      guard buckets.count < maximumKeys else { return .limited(retryAfter: 60) }
    }
    buckets[key] = bucket
    return .allowed
  }

  private func prune(at current: Date) {
    buckets = buckets.filter { _, bucket in
      bucket.tokens + current.timeIntervalSince(bucket.updated) * limit.refillPerSecond < limit.capacity
    }
  }
}
