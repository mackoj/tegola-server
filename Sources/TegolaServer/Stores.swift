public import AppAttest
public import Foundation

/// Registered App Attest keys. Production keeps them in Postgres (`PostgresStore`, D-17); tests and development
/// servers without `TEGOLA_DATABASE_URL` keep them in memory (`InMemoryAttestKeyStore`), where a restart loses every
/// key and each install re-registers through the contract's `unknown-key` path (D-8).
///
/// A store that can't answer throws; the caller answers 503 and never treats the failure as "no key" or "replay".
public protocol AttestKeyStore: Sendable {
  /// Stores a newly attested key. A key id that is already registered keeps its stored counter and revocation, so
  /// re-registering can't wind the counter back and reopen old assertions, nor bring a revoked key back.
  func register(_ key: AttestedKey) async throws
  func key(id: Data) async throws -> AttestKeyRecord?
  /// Sets the counter to `counter` only if it is greater than the stored one, atomically. `false` is a replay.
  func advanceCounter(id: Data, to counter: UInt32) async throws -> Bool
  func revoke(id: Data) async throws
}

public struct AttestKeyRecord: Sendable, Equatable {
  public var key: AttestedKey
  public var revoked: Bool

  public init(key: AttestedKey, revoked: Bool) {
    self.key = key
    self.revoked = revoked
  }
}

/// Single-use registration challenges: 32 random bytes, base64, valid `lifetime` seconds, gone once consumed whether
/// the attestation then verifies or not. Stores are bounded so a flood can't exhaust memory or disk.
public protocol ChallengeStore: Sendable {
  /// A new challenge, or `nil` when the store is full even after dropping the expired ones.
  func issue() async throws -> (challenge: String, expiresAt: Date)?
  /// Removes the challenge and says whether it was issued here and is still valid.
  func consume(_ challenge: String) async throws -> Bool
}

enum ChallengeGenerator {
  static func make() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64EncodedString()
  }
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

public actor InMemoryChallengeStore: ChallengeStore {
  private var expiries: [String: Date] = [:]
  private let lifetime: TimeInterval
  private let capacity: Int
  private let now: @Sendable () -> Date

  public init(lifetime: TimeInterval, capacity: Int, now: @escaping @Sendable () -> Date = { Date() }) {
    self.lifetime = lifetime
    self.capacity = capacity
    self.now = now
  }

  public func issue() -> (challenge: String, expiresAt: Date)? {
    let current = now()
    if expiries.count >= capacity { expiries = expiries.filter { $0.value > current } }
    guard expiries.count < capacity else { return nil }
    let challenge = ChallengeGenerator.make()
    let expiresAt = current.addingTimeInterval(lifetime)
    expiries[challenge] = expiresAt
    return (challenge, expiresAt)
  }

  public func consume(_ challenge: String) -> Bool {
    guard let expiresAt = expiries.removeValue(forKey: challenge) else { return false }
    return expiresAt > now()
  }
}
