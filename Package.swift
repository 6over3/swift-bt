// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "swift-bt",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2),
  ],
  products: [
    .library(name: "BehaviorTree", targets: ["BehaviorTree"]),
    .library(name: "BehaviorTreeUI", targets: ["BehaviorTreeUI"]),
    .library(name: "BehaviorTreeLogging", targets: ["BehaviorTreeLogging"]),
    .library(name: "BehaviorTreeMetrics", targets: ["BehaviorTreeMetrics"]),
    .library(name: "BehaviorTreeTracing", targets: ["BehaviorTreeTracing"]),
    .executable(name: "BehaviorTreeSample", targets: ["BehaviorTreeSample"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/lukilabs/elk-swift.git",
      exact: "1.0.2"
    ),
    .package(
      url: "https://github.com/apple/swift-log.git",
      from: "1.15.0"
    ),
    .package(
      url: "https://github.com/apple/swift-metrics.git",
      from: "2.11.0"
    ),
    .package(
      url: "https://github.com/apple/swift-distributed-tracing.git",
      from: "1.4.1"
    ),
  ],
  targets: [
    .target(name: "BehaviorTree"),
    .target(
      name: "BehaviorTreeUI",
      dependencies: [
        "BehaviorTree",
        .product(name: "ElkSwift", package: "elk-swift"),
      ]
    ),
    .target(
      name: "BehaviorTreeLogging",
      dependencies: [
        "BehaviorTree",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(
      name: "BehaviorTreeMetrics",
      dependencies: [
        "BehaviorTree",
        .product(name: "Metrics", package: "swift-metrics"),
      ]
    ),
    .target(
      name: "BehaviorTreeTracing",
      dependencies: [
        "BehaviorTree",
        .product(name: "Tracing", package: "swift-distributed-tracing"),
      ]
    ),
    .executableTarget(
      name: "BehaviorTreeSample",
      dependencies: ["BehaviorTree", "BehaviorTreeUI"],
      path: "Examples/BehaviorTreeSample"
    ),
    .testTarget(
      name: "BehaviorTreeTests",
      dependencies: ["BehaviorTree"]
    ),
    .testTarget(
      name: "BehaviorTreeUITests",
      dependencies: ["BehaviorTreeUI"]
    ),
    .testTarget(
      name: "BehaviorTreeIntegrationTests",
      dependencies: [
        "BehaviorTreeLogging",
        "BehaviorTreeMetrics",
        "BehaviorTreeTracing",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "MetricsTestKit", package: "swift-metrics"),
        .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
      ]
    ),
  ]
)
