// swift-tools-version: 6.0
import Foundation
import PackageDescription

// sherpa-onnx prebuilt dylibs are fetched into vendor/ by scripts/fetch-deps.sh
let vendorLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("vendor/sherpa-onnx/lib").path

let sherpaLinkerFlags: [LinkerSetting] = [
  .unsafeFlags([
    "-L", vendorLib,
    // inside JustSpeak.app the dylibs live in Contents/Frameworks; for `swift run` use vendor/
    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    "-Xlinker", "-rpath", "-Xlinker", vendorLib,
  ])
]

let package = Package(
  name: "just-speak",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "just-speak", targets: ["JustSpeak"])
  ],
  targets: [
    .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
    .target(
      name: "JustSpeakCore",
      dependencies: ["CSherpaOnnx"],
      linkerSettings: sherpaLinkerFlags
    ),
    // linker settings propagate from JustSpeakCore to everything that links it
    .executableTarget(name: "JustSpeak", dependencies: ["JustSpeakCore"]),
    .testTarget(name: "JustSpeakCoreTests", dependencies: ["JustSpeakCore"]),
  ]
)
