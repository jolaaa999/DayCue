// swift-tools-version:5.9
import PackageDescription

// DayCueCore 只依赖 Foundation / CryptoKit / SQLite3，因此在 macOS 上也能 swift test。
// iOS 专有框架（UIKit/SwiftUI/EventKit/AVFoundation/Vision/Speech）一律不进这个 target，
// 否则 macOS 上根本无法编译测试。
let package = Package(
    name: "DayCue",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DayCueCore", targets: ["DayCueCore"])
    ],
    targets: [
        .target(
            name: "DayCueCore",
            path: "Sources/DayCueCore"
        ),
        .testTarget(
            name: "DayCueCoreTests",
            dependencies: ["DayCueCore"],
            path: "Tests/DayCueCoreTests"
        )
    ]
)
