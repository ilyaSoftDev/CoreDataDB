// swift-tools-version: 6.0
//
//  Package.swift
//  CoreDataDB
//
//  Swift Package Manager distribution.
//
//  This manifest describes the same sources the Xcode framework target and the
//  podspec build — it does not restructure them. It does reproduce the podspec's
//  Core/Combine split, as two targets rather than two subspecs; see the note
//  above `targets`, which is where the consequences are. SPM's convention is
//  Sources/<Target>/, but the Xcode target uses a file-system-synchronized
//  group rooted at CoreDataDB/, so moving the tree to satisfy SPM would mean
//  editing project.pbxproj and would break the podspec's globs at the same
//  time. `path:` points SPM at the existing layout instead, and all three
//  distribution channels stay in sync by construction.

import PackageDescription

// ―― Build settings ――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
//
// The Xcode target sets SWIFT_VERSION = 5.0 with SWIFT_APPROACHABLE_CONCURRENCY
// and SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY, and the podspec carries
// the same two through pod_target_xcconfig. This reproduces them for SPM.
//
// Both halves are load-bearing:
//
//   * .swiftLanguageMode(.v5) — a tools-6.0 manifest defaults to the Swift 6
//     language mode, which the Xcode target does NOT use. Omitting this would
//     compile the package under stricter rules than the framework is built
//     with, and the Sendable conformances here have not been audited for it.
//
//   * The upcoming features — SWIFT_APPROACHABLE_CONCURRENCY is an umbrella
//     that turns these on individually. NonisolatedNonsendingByDefault changes
//     where a nonisolated async function actually runs, so leaving it out is a
//     semantic difference rather than a missing optimisation.
//
// Deliberately no .unsafeFlags: a package using them cannot be consumed as a
// dependency by any other package, which would defeat the point of this file.
//
// Keep this declared ABOVE `let package`. A manifest still compiles with the
// order reversed, but the settings silently resolve to empty: the package then
// builds in the Swift 6 language mode with none of the features below, and
// nothing warns. Verify with:
//
//   swift build -v 2>&1 | grep -oE '\-swift-version [0-9]+|\-enable-upcoming-feature [A-Za-z]+' | sort -u
//
// which must list -swift-version 5 and all four features.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "CoreDataDB",

    // Mirrors the Xcode target's IPHONEOS/MACOSX/XROS_DEPLOYMENT_TARGET and the
    // podspec's deployment_target entries, to the minor version. There is
    // deliberately no tvOS or watchOS platform, matching SUPPORTED_PLATFORMS.
    //
    // NOTE: 26.5 is the Xcode target's floor, not a verified API floor — the
    // doc comments throughout the sources still claim iOS 18 / macOS 15. Lower
    // these in step with the Xcode target and the podspec if that is ever
    // established; they are three copies of one number.
    platforms: [
        .iOS("26.5"),
        .macOS("26.5"),
        .visionOS("26.5")
    ],

    // One product per tier, mirroring `spec.default_subspecs = "Core"`: a
    // consumer depending on "CoreDataDB" gets the async tier alone, and reaches
    // the publishers by adding "CoreDataDBCombine" — the same opt-in a Podfile
    // makes with `pod 'CoreDataDB/Combine'`.
    //
    // No explicit `type:` — an automatic library lets the consumer's build
    // decide static or dynamic, which is what a source distribution should do.
    // BUILD_LIBRARY_FOR_DISTRIBUTION in the Xcode target matters for shipping a
    // binary .framework and has no bearing here.
    products: [
        .library(
            name: "CoreDataDB",
            targets: ["CoreDataDB"]
        ),
        .library(
            name: "CoreDataDBCombine",
            targets: ["CoreDataDBCombine"]
        )
    ],

    // ―― Two targets, one per tier ――――――――――――――――――――――――――――――――――――――――― #
    //
    // The podspec splits these sources into a default `Core` subspec and an
    // opt-in `Combine` one. SPM has no subspec, so the same boundary is drawn
    // with two targets — and a target is a *module*, which the subspecs are not:
    // CocoaPods and the Xcode framework compile both folders into one module
    // named CoreDataDB.
    //
    // Two consequences follow, and both are handled in the sources rather than
    // being left for a consumer to discover:
    //
    //   * The Combine tier has to import the async tier here and must not
    //     import it there, where it would be importing the module being
    //     compiled. Every file in CoreDataDB/Combine/ therefore guards its
    //     `import CoreDataDB` with `#if COREDATADB_MODULAR`, defined below and
    //     nowhere else. DatabaseCombineProxy.swift spells it `@_exported` so
    //     that one `import CoreDataDBCombine` still reaches DatabaseClient, as
    //     it does for a pod consumer.
    //   * Internal access across the boundary stops compiling. There is exactly
    //     one such reach — the store identity the notification filter matches
    //     on — and Core exposes it as `@_spi(CoreDataDBTiers)` rather than as
    //     public API, so the split costs no public ABI. See
    //     CoreDataDB/Core/DatabaseClient+StoreIdentity.swift.
    //
    // The paths are the subspec globs' roots, so the two declarations of the
    // split cannot drift far. .github/scripts/check-source-layout.sh fails the
    // build if a Swift file lands outside both folders, where the Xcode target
    // would still compile it while neither this manifest nor the podspec ships
    // it.
    targets: [
        .target(
            name: "CoreDataDB",
            path: "CoreDataDB/Core",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CoreDataDBCombine",
            dependencies: ["CoreDataDB"],
            path: "CoreDataDB/Combine",
            swiftSettings: swiftSettings + [.define("COREDATADB_MODULAR")]
        ),
        .testTarget(
            name: "CoreDataDBTests",
            dependencies: ["CoreDataDB", "CoreDataDBCombine"],
            path: "CoreDataDBTests",
            swiftSettings: swiftSettings
        )
    ]
)
