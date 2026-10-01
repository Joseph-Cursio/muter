@testable import muterCore
import XCTest

enum TestingError: String, Error {
    case stub
}

final class CopyProjectToTempDirectoryTests: MuterTestCase {
    private let state = MutationTestState()

    private lazy var sut = CopyProjectToTempDirectory()

    func test_whenItsAbleToCopyAProjectIntoATempDirectory() async throws {
        state.projectDirectoryURL = URL(string: "/some/projectName")!
        state.mutatedProjectDirectoryURL = URL(string: "/tmp/projectName")!

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.copyPaths.first?.source, "/some/projectName")
        XCTAssertEqual(fileManager.copyPaths.first?.dest, "/tmp/projectName")
        XCTAssertEqual(fileManager.copyPaths.count, 1)
        XCTAssertEqual(fileManager.methodCalls.first, "copyItem(atPath:toPath:)")
        XCTAssertEqual(fileManager.methodCalls.filter { $0 == "copyItem(atPath:toPath:)" }.count, 1)
    }

    func test_copiesWithVanishedFileToleranceAndRestoresTheDelegate() async throws {
        state.projectDirectoryURL = URL(string: "/some/projectName")!
        state.mutatedProjectDirectoryURL = URL(string: "/tmp/projectName")!

        _ = try await sut.run(with: state)

        XCTAssertTrue(fileManager.delegateDuringCopy is VanishedFileTolerance)
        XCTAssertNil(fileManager.delegate)
    }

    func test_restoresTheDelegateWhenTheCopyFails() async throws {
        fileManager.errorToThrow = TestingError.stub
        state.projectDirectoryURL = URL(string: "/some/projectName")!
        state.mutatedProjectDirectoryURL = URL(string: "/tmp/projectName")!

        _ = try? await sut.run(with: state)

        XCTAssertNil(fileManager.delegate)
    }

    func test_vanishedFileToleranceProceedsOnlyPastMissingFiles() {
        let tolerance = VanishedFileTolerance()
        let missing: [Error] = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]
            ),
        ]
        let fatal: [Error] = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            TestingError.stub,
        ]

        for error in missing {
            XCTAssertTrue(
                tolerance.fileManager(.default, shouldProceedAfterError: error, copyingItemAtPath: "/src/x.lock", toPath: "/dst/x.lock"),
                "should skip \(error)"
            )
        }
        for error in fatal {
            XCTAssertFalse(
                tolerance.fileManager(.default, shouldProceedAfterError: error, copyingItemAtPath: "/src/x", toPath: "/dst/x"),
                "should stop on \(error)"
            )
        }
        XCTAssertEqual(tolerance.skippedPaths.count, missing.count)
    }

    func test_removesTheCopiedModuleCacheFromTheMutatedProjectOnly() async throws {
        state.projectDirectoryURL = URL(fileURLWithPath: "/some/projectName")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/tmp/projectName_mutated")
        fileManager.contentsOfDirectoryToReturn = [
            "/tmp/projectName_mutated/.build": ["arm64-apple-macosx"],
            "/tmp/projectName_mutated/.build/arm64-apple-macosx": ["debug"],
        ]
        fileManager.fileExistsToReturn = [true]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths,
            ["/tmp/projectName_mutated/.build/arm64-apple-macosx/debug/ModuleCache"]
        )
    }

    // Clang's precompiled modules record the absolute module-cache path they
    // were built under, so a copied cache is rejected in `<project>_mutated`
    // ("was compiled with module cache path …") and the baseline build fails.
    // Exercised on a real directory tree because the cleanup walks it.
    func test_removeCopiedModuleCachesDeletesOnlyModuleCaches() throws {
        let manager = FileManager()
        let root = manager.temporaryDirectory
            .appendingPathComponent("muter-module-cache-\(UUID().uuidString)").path
        defer { try? manager.removeItem(atPath: root) }

        let build = "\(root)/.build"
        let debugCache = "\(build)/arm64-apple-macosx/debug/ModuleCache"
        let releaseCache = "\(build)/arm64-apple-macosx/release/ModuleCache"
        let objects = "\(build)/arm64-apple-macosx/debug/App.build"
        for directory in [debugCache, releaseCache, objects] {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try Data("pcm".utf8).write(to: URL(fileURLWithPath: "\(debugCache)/Swift.pcm"))
        try Data("o".utf8).write(to: URL(fileURLWithPath: "\(objects)/main.o"))
        try manager.createSymbolicLink(atPath: "\(build)/debug", withDestinationPath: "arm64-apple-macosx/debug")
        // A `ModuleCache` in the sources is not a build cache and must survive.
        try manager.createDirectory(atPath: "\(root)/Sources/ModuleCache", withIntermediateDirectories: true)

        removeCopiedModuleCaches(inProjectAt: root, using: manager)

        XCTAssertFalse(manager.fileExists(atPath: debugCache))
        XCTAssertFalse(manager.fileExists(atPath: releaseCache))
        XCTAssertTrue(manager.fileExists(atPath: "\(objects)/main.o"))
        XCTAssertTrue(manager.fileExists(atPath: "\(build)/debug"))
        XCTAssertTrue(manager.fileExists(atPath: "\(root)/Sources/ModuleCache"))
    }

    func test_removeCopiedModuleCachesToleratesAProjectWithoutABuildDirectory() throws {
        let manager = FileManager()
        let root = manager.temporaryDirectory
            .appendingPathComponent("muter-no-build-\(UUID().uuidString)").path
        try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: root) }

        removeCopiedModuleCaches(inProjectAt: root, using: manager)

        XCTAssertTrue(manager.fileExists(atPath: root))
    }

    func test_whenItsUnableToCopyAProjectIntoATempDirectory() async throws {
        fileManager.errorToThrow = TestingError.stub
        state.projectDirectoryURL = URL(string: "/some/projectName")!
        state.mutatedProjectDirectoryURL = URL(string: "/tmp/projectName")!

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .projectCopyFailed(reason) = error else {
                XCTFail("Expected projectCopyFailed, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }
    }
}
