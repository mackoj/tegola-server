public import AppAttest
public import Foundation

/// Registered App Attest keys. The in-memory store is v1's (DECISIONS D-8): a restart loses every key, and each app
/// re-registers on the `401 …/problems/unknown-key` the contract defines. A persistent store implements the same
/// protocol; `advanceCounter` must stay atomic there too (a conditional `UPDATE … WHERE counter < $new`).
public protocol AttestKeyStore: Sendable {
  /// Stores a newly attested key. A key id that is already registered keeps its stored counter, so re-registering
  /// can't wind the counter back and reopen old assertions.
  func register(_ key: AttestedKey) async
  func key(id: Data) async -> AttestKeyRecord?
  /// Sets the counter to `counter` only if it is greater than the stored one, atomically. `false` is a replay.
  func advanceCounter(id: Data, to counter: UInt32) async -> Bool
  func revoke(id: Data) async
}

public struct AttestKeyRecord: Sendable, Equatable {
  public var key: AttestedKey
  public var revoked: Bool
}

public actor InMemoryAttestKeyStore: AttestKeyStore {
  private var records: [Data: AttestKeyRecord] = [:]

  public init() {}

  public func register(_ key: AttestedKey) {
    if var existing = records[key.keyID] {
      existing.key.counter = max(existing.key.counter, key.counter)
      records[key.keyID] = existing
    } else {
      records[key.keyID] = AttestKeyRecord(key: key, revoked: false)
    }
  }

  public func key(id: Data) -> AttestKeyRecord? { records[id] }

  public func advanceCounter(id: Data, to counter: UInt32) -> Bool {
    guard var record = records[id], counter > record.key.counter else { return false }
    record.key.counter = counter
    records[id] = record
    return true
  }

  public func revoke(id: Data) {
    records[id]?.revoked = true
  }
}

/// Single-use registration challenges. Each one is 32 random bytes, lives `lifetime` seconds and is gone once
/// consumed, whether the attestation then verifies or not. The store is bounded so a flood can't exhaust memory.
public actor ChallengeStore {
  private var expiries: [String: Date] = [:]
  private let lifetime: TimeInterval
  private let capacity: Int
  private let now: @Sendable () -> Date

  public init(lifetime: TimeInterval, capacity: Int, now: @escaping @Sendable () -> Date = { Date() }) {
    self.lifetime = lifetime
    self.capacity = capacity
    self.now = now
  }

  /// A new challenge, or `nil` when the store is full even after dropping the expired ones.
  public func issue() -> (challenge: String, expiresAt: Date)? {
    let current = now()
    if expiries.count >= capacity { expiries = expiries.filter { $0.value > current } }
    guard expiries.count < capacity else { return nil }
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let challenge = Data(bytes).base64EncodedString()
    let expiresAt = current.addingTimeInterval(lifetime)
    expiries[challenge] = expiresAt
    return (challenge, expiresAt)
  }

  /// Removes the challenge and says whether it was issued here and is still valid.
  public func consume(_ challenge: String) -> Bool {
    guard let expiresAt = expiries.removeValue(forKey: challenge) else { return false }
    return expiresAt > now()
  }
}
