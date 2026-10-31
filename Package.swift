// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "tegola-server",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "tegola-server", targets: ["tegola-server"]),
    .library(name: "TegolaServer", targets: ["TegolaServer"]),
    .library(name: "AppAttest", targets: ["AppAttest"]),
  ],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", "2.5.0"..<"3.0.0"),
    .package(url: "https://github.com/swift-server/swift-openapi-hummingbird.git", "2.0.1"..<"3.0.0"),
    .package(url: "https://github.com/apple/swift-openapi-generator", "1.10.0"..<"2.0.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", "1.8.0"..<"2.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"5.0.0"),
    .package(url: "https://github.com/apple/swift-certificates.git", "1.6.0"..<"2.0.0"),
    .package(url: "https://github.com/apple/swift-asn1.git", "1.3.0"..<"2.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", "1.6.0"..<"2.0.0"),
    .package(url: "https://github.com/apple/swift-nio.git", "2.80.0"..<"3.0.0"),
    .package(url: "https://github.com/apple/swift-http-types.git", "1.3.0"..<"2.0.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", "1.25.0"..<"2.0.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", "2.27.0"..<"3.0.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", "2.6.0"..<"3.0.0"),
  ],
  targets: [
    // App Attest verification: a strict CBOR reader, attestation (certificate chain to Apple's root, nonce, app id,
    // environment, key id) and assertion (signature, counter, app id) checks. No Hummingbird, no I/O: pure and
    // testable with a fake CA (DECISIONS D-4, D-5).
    .target(
      name: "AppAttest",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "SwiftASN1", package: "swift-asn1"),
      ],
      swiftSettings: swiftSettings
    ),
    // The server: types and server stubs generated from api/tegola-lookup.openapi.yaml (a symlink here, so the
    // contract has one home in this repo; tegola's copy is the source, scripts/sync-contract.sh copies it), the
    // handlers, the security middlewares, configuration and the in-memory stores.
    .target(
      name: "TegolaServer",
      dependencies: [
        "AppAttest",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ],
      swiftSettings: swiftSettings,
      plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
    ),
    .executableTarget(
      name: "tegola-server",
      dependencies: [
        "TegolaServer",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: swiftSettings
    ),
    // A fake App Attest CA and device for both test targets.
    .target(
      name: "AppAttestTestSupport",
      dependencies: [
        "AppAttest",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "SwiftASN1", package: "swift-asn1"),
      ],
      path: "Tests/AppAttestTestSupport",
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AppAttestTests",
      dependencies: [
        "AppAttest",
        "AppAttestTestSupport",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "SwiftASN1", package: "swift-asn1"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "TegolaServerTests",
      dependencies: [
        "TegolaServer",
        "AppAttest",
        "AppAttestTestSupport",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "SwiftASN1", package: "swift-asn1"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: swiftSettings
    ),
  ]
)
