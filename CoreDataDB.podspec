Pod::Spec.new do |spec|

  # ――― Metadata ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  spec.name         = "CoreDataDB"
  spec.module_name  = "CoreDataDB"
  spec.version      = "1.1.0"
  spec.summary      = "A Sendable, async/await Core Data layer that trades in value types instead of managed objects."

  spec.description  = <<-DESC
    CoreDataDB wraps Core Data behind a small Sendable facade. Every operation is
    async/await and exchanges value-type DTOs rather than managed objects, so
    nothing thread-confined escapes the context it was fetched on, and a client
    can be built from any isolation domain.

    The framework ships no managed object model of its own — the host application
    supplies one, and any models registered against it are checked when the store
    opens, turning a missing entity or an absent uniqueness constraint into a
    named error instead of a crash or a silent duplicate row.

    What it provides:

      * Object-graph CRUD that honours delete rules, validation and save hooks.
      * A separate, clearly-labelled batch tier issuing NSBatch* requests straight
        to the store, merging the resulting object IDs back into the live contexts.
      * A two-part migration layer: staged schema plans that run inside the store
        load, and per-model data migrations run afterwards against the migrated
        store, each recorded in a ledger kept in the store's own metadata so the
        record survives a backup and restore.
      * A per-call choice of context — the main queue, a shared background queue,
        or a detached context for long imports.

    The optional CoreDataDB/Combine subspec republishes that CRUD tier as Combine
    publishers, and adds the one thing the async tier has no equivalent for: live
    observation. An observe publisher emits a snapshot on subscribe and a fresh one
    whenever the rows it covers move — from any context, or from the batch tier,
    which writes past the contexts entirely.
  DESC

  spec.homepage          = "https://github.com/ilyaSoftDev/CoreDataDB"
  spec.documentation_url = "https://ilyaSoftDev.github.io/CoreDataDB"
  spec.license           = { :type => "Proprietary", :file => "LICENSE" }
  spec.author            = { "Ilya Slipak" => "ilyaslipak@gmail.com" }


  # ――― Platforms ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
  #
  # Mirrors the Xcode target. SUPPORTED_PLATFORMS is "iphoneos iphonesimulator
  # macosx xros xrsimulator" — there is deliberately no tvOS or watchOS slice.
  #
  # Linting visionOS requires the runtime locally:
  #   xcodebuild -downloadPlatform visionOS
  #
  # NOTE: 26.5 is the Xcode target's floor, not a verified API floor. See the
  # note below the spec — lower these if a 17.0/14.0/1.0 build compiles clean.

  spec.ios.deployment_target      = "26.5"
  spec.osx.deployment_target      = "26.5"
  spec.visionos.deployment_target = "26.5"

  # SWIFT_VERSION in the Xcode target is 5.0. The source uses Swift 6 spellings
  # such as `sending`, which the current compiler accepts in the 5 language mode;
  # it is not built with strict concurrency checking.
  spec.swift_versions = ["5.0"]


  # ――― Source ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  spec.source       = {
    :git => "https://github.com/ilyaSoftDev/CoreDataDB.git",
    :tag => "#{spec.version}"
  }

  # ――― Subspecs ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
  #
  # `source_files` and `frameworks` live on the subspecs, not on the root, because
  # root attributes are *inherited* by every subspec: a root-level
  # "CoreDataDB/**/*.swift" would pull the Combine sources into Core and defeat the
  # split. `pod_target_xcconfig` below is the deliberate exception — both subspecs
  # have to be built the same way.
  #
  # `os` (for Logger) is part of the platform and needs no explicit entry.
  # Foundation is linked implicitly and is omitted. The DocC catalog under
  # CoreDataDB/ holds only .md and is matched by neither glob; CoreDataDBTests/ is
  # a sibling of both.
  #
  # NOTE: within CocoaPods the subspecs are a packaging boundary only — both are
  # compiled into one module named CoreDataDB, so a consumer of both writes a
  # single `import CoreDataDB`. The Xcode framework target — whose synchronized
  # group is rooted at CoreDataDB/ — always compiles both folders and has no
  # opt-out at all.
  #
  # Package.swift draws the same line as two targets, which under SPM are two
  # modules; the folders here are its `path:` roots, so the two declarations of
  # the split stay in step. That is also why every file in CoreDataDB/Combine/
  # guards its `import CoreDataDB` with `#if COREDATADB_MODULAR` — the flag is
  # defined by the package alone, and this build must not take the import.

  spec.default_subspecs = "Core"

  spec.subspec "Core" do |core|
    core.source_files = "CoreDataDB/Core/**/*.swift"
    core.frameworks   = "CoreData"
  end

  # The async CRUD tier as Combine publishers, plus live `observe` publishers.
  spec.subspec "Combine" do |combine|
    combine.dependency   "CoreDataDB/Core"
    combine.source_files = "CoreDataDB/Combine/**/*.swift"
    combine.frameworks   = "Combine"
  end


  # ――― Build settings ―――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
  #
  # Carried over from the Xcode target. The source compiles without these — it
  # was verified — but approachable concurrency implies NonisolatedNonsendingByDefault,
  # which changes where a nonisolated async function actually runs. Omitting them
  # would be a semantic difference, not a no-op, so the pod is built the same way
  # the framework is.

  spec.pod_target_xcconfig = {
    "SWIFT_APPROACHABLE_CONCURRENCY" => "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY" => "YES"
  }

end
