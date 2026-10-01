import Foundation

class CopyProjectToTempDirectory: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        do {
            notificationCenter.post(
                name: .projectCopyStarted,
                object: nil
            )

            // The project is live while it is copied: build tools create and
            // delete lock and temporary files under `.build` at any moment, and
            // one vanishing mid-copy used to abort the whole run. The shared
            // file manager's delegate is restored afterwards.
            var manager = fileManager
            let previousDelegate = manager.delegate
            let tolerance = VanishedFileTolerance()
            manager.delegate = tolerance
            defer { manager.delegate = previousDelegate }

            try manager.copyItem(
                atPath: state.projectDirectoryURL.path,
                toPath: state.mutatedProjectDirectoryURL.path
            )

            removeCopiedModuleCaches(
                inProjectAt: state.mutatedProjectDirectoryURL.path,
                using: manager
            )

            notificationCenter.post(
                name: .projectCopyFinished,
                object: state.mutatedProjectDirectoryURL.path
            )

            return []
        } catch {
            throw MuterError.projectCopyFailed(
                reason: error.localizedDescription
            )
        }
    }
}

/// Deletes SwiftPM's Clang module caches (`.build/<triple>/<configuration>/ModuleCache`)
/// from a copied project.
///
/// A precompiled module records the absolute module-cache path it was built
/// under, so the copy's cache is rejected ("was compiled with module cache path
/// …") and the baseline build fails before any mutant runs. The compiler
/// rebuilds the cache, so removal is best-effort: anything left behind surfaces
/// as that same build error.
func removeCopiedModuleCaches(
    inProjectAt projectDirectory: String,
    using fileManager: FileSystemManager
) {
    let build = (projectDirectory as NSString).appendingPathComponent(".build")

    for triple in (try? fileManager.contentsOfDirectory(atPath: build)) ?? [] {
        let tripleDirectory = (build as NSString).appendingPathComponent(triple)

        for configuration in (try? fileManager.contentsOfDirectory(atPath: tripleDirectory)) ?? [] {
            let cache = ((tripleDirectory as NSString)
                .appendingPathComponent(configuration) as NSString)
                .appendingPathComponent("ModuleCache")

            if fileManager.fileExists(atPath: cache) {
                try? fileManager.removeItem(atPath: cache)
            }
        }
    }
}

/// Lets a recursive copy continue past files that disappear after the copy has
/// enumerated them. Every other error, a permission failure included, still
/// stops the copy.
final class VanishedFileTolerance: NSObject, FileManagerDelegate {
    private(set) var skippedPaths: [String] = []

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAtPath srcPath: String,
        toPath dstPath: String
    ) -> Bool {
        guard Self.isNoSuchFile(error) else {
            return false
        }

        skippedPaths.append(srcPath)
        return true
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return isNoSuchFile(underlying)
            }
            return false
        }
    }
}
