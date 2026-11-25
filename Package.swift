// swift-tools-version:5.9
import PackageDescription

// The GitHub organization of the suite's repositories: the one name to change should it be renamed (the
// suite repository's scripts/rename-organization.sh does it in every repository).
let organization = "love-suite"

// Bar: the suite's Dock in place of the system one, as an app of its own. Its model stays UI-free and
// tested in BarCore; its settings are a library of their own, which Suite Settings reads for its Bar
// tab. The system Dock it hides is put back by Suite Guard should it vanish.
let suiteCore = Target.Dependency.product(name: "SuiteCore", package: "suite-core")
let dockGuard = Target.Dependency.product(name: "DockGuard", package: "suite-guard")
let filesCore = Target.Dependency.product(name: "SuiteFilesCore", package: "suite-files")
let filesUI = Target.Dependency.product(name: "SuiteFilesUI", package: "suite-files")

let package = Package(
    name: "Bar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BarSettings", targets: ["BarSettings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/\(organization)/suite-core", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-guard", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-files", .upToNextMinor(from: "27.1.0-dev.1")),
    ],
    targets: [
        // Bar's settings and the messages between Bar.app and Suite Settings. No UI.
        .target(name: "BarSettings"),
        // Pinned apps (first read from the system Dock), layout, geometry, minimized windows, stacks.
        .target(name: "BarCore", dependencies: ["BarSettings", suiteCore, dockGuard]),
        .testTarget(name: "BarCoreTests", dependencies: ["BarCore", "BarSettings", dockGuard]),
        // The app: the panel, its icons, the Downloads stack, minimized windows, fitting windows above it.
        // Never "Dock": `killall Dock` restarts the system Dock, whose process is "Dock".
        .executableTarget(
            name: "Bar",
            dependencies: ["BarCore", "BarSettings", suiteCore, filesCore, filesUI, dockGuard],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("QuickLookThumbnailing")]
        ),
    ]
)
