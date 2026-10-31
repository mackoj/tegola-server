public import Hummingbird
public import NIOCore

/// The request context: Hummingbird's core storage plus the peer address, which the edge middleware needs for the
/// per-IP rate limit.
public struct TegolaRequestContext: RequestContext, RemoteAddressRequestContext {
  public var coreContext: CoreRequestContextStorage
  public let remoteAddress: SocketAddress?

  public init(source: ApplicationRequestContextSource) {
    self.coreContext = .init(source: source)
    self.remoteAddress = source.channel.remoteAddress
  }
}
