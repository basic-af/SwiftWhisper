// swift-tools-version:5.5
import PackageDescription

var exclude: [String] = []
let platforms: [SupportedPlatform]? = [
    .macOS(.v12),
    .iOS(.v14),
    .watchOS(.v4),
    .tvOS(.v14)
]

let resources: [Resource] = [
    .process("ggml-metal.metal")
]

#if os(Linux)
// Linux doesn't support CoreML, and will attempt to import the coreml source directory
exclude.append("coreml")
#endif

let package = Package(
    name: "SwiftWhisper",
    platforms: platforms,
    products: [
        .library(name: "SwiftWhisper", targets: ["SwiftWhisper"])
    ],
    targets: [
        .target(
            name: "SwiftWhisper",
            dependencies: ["whisper_cpp", "whisper_cpp_metal"]
        ),
        .target(
            name: "whisper_cpp_metal",
            path: "Sources/whisper_cpp_metal",
            sources: ["ggml-metal.m"],
            resources: resources,
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fno-objc-arc"])
            ]
        ),
        .target(
            name: "whisper_cpp",
            dependencies: [.target(name: "whisper_cpp_metal")],
            path: "Sources/whisper_cpp",
            sources: [
                "ggml.c",
                "ggml-alloc.c",
                "coreml/whisper-encoder-impl.m",
                "coreml/whisper-encoder.mm",
                "whisper.cpp",
            ],
            resources: resources,
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
                .define("GGML_USE_ACCELERATE"),
                .define("WHISPER_USE_COREML"),
                .define("WHISPER_COREML_ALLOW_FALLBACK"),
                .define("GGML_USE_METAL")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "WhisperTests",
            dependencies: ["SwiftWhisper"],
            resources: [.copy("TestResources/")]
        )
    ],
    cxxLanguageStandard: CXXLanguageStandard.cxx11
)
