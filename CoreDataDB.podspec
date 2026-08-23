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

  # Every source file lives under CoreDataDB/. The DocC catalog nested in there
  # holds only .md and is not matched, and CoreDataDBTests/ is a sibling.
  spec.source_files = "CoreDataDB/**/*.swift"


  # ――― Linking ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
  #
  # `os` (for Logger) is part of the platform and needs no explicit entry.
  # Foundation is linked implicitly and is omitted.

  spec.frameworks   = "CoreData"


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
