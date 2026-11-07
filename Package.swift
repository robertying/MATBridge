// swift-tools-version:6.0
import PackageDescription

// Apple silicon only. FFmpeg comes from Homebrew (`brew install ffmpeg`); override with FFMPEG_PREFIX if needed.
let ffmpeg = Context.environment["FFMPEG_PREFIX"] ?? "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "MATBridge",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CTrueHD",
            cSettings: [.unsafeFlags(["-I\(ffmpeg)/include", "-O2"])],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpeg)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(ffmpeg)/lib"]),
                .linkedLibrary("avcodec"), .linkedLibrary("avformat"), .linkedLibrary("avutil"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "MATBridge",
            dependencies: ["CTrueHD"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("AppKit")]
        ),
    ]
)
