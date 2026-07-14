import Foundation
import Testing
@testable import shockemu

@Test func ownedPathsRejectSiblingAndSymlinkEscapes() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = temporary.appendingPathComponent("support", isDirectory: true)
    let outside = temporary.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    #expect(ArtifactSafety.isDescendant(root.appendingPathComponent("apps/a"), of: root))
    #expect(!ArtifactSafety.isDescendant(temporary.appendingPathComponent("support-old/a"), of: root))

    let link = root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(!ArtifactSafety.isDescendant(link.appendingPathComponent("app"), of: root))
}

@Test func manifestRejectsUnknownSchemaAndTraversal() throws {
    let valid = PreparedManifest(
        sourceExecutableSHA256: String(repeating: "a", count: 64),
        runtimeSHA256: String(repeating: "b", count: 64),
        preparedAppRelativePath: "artifacts/\(String(repeating: "a", count: 64))/RemotePlay.app",
        runtimeRelativePath: "artifacts/\(String(repeating: "a", count: 64))/libShockEmuRuntime.dylib",
        remotePlayVersion: "9.0.0"
    )
    #expect(throws: Never.self) { try valid.validate() }

    var traversal = valid
    traversal.preparedAppRelativePath = "../RemotePlay.app"
    #expect(throws: ManifestError.self) { try traversal.validate() }

    var future = valid
    future.schemaVersion = 2
    #expect(throws: ManifestError.self) { try future.validate() }

    var arbitrary = valid
    arbitrary.preparedAppRelativePath = "keep.txt"
    #expect(throws: ManifestError.self) { try arbitrary.validate() }
}

@Test func commandParserRequiresProfilesAndRejectsUnknownInputSources() throws {
    #expect(try Command.parse(["doctor"]) == .doctor)
    #expect(try Command.parse(["prepare", "--force"]) == .prepare(force: true))
    #expect(throws: CLIError.self) { try Command.parse(["run"]) }
    #expect(throws: CLIError.self) {
        try Command.parse(["run", "--profile", "example.se", "--input-source", "global"])
    }
}

@Test func cleanupRemovesOnlyManifestOwnedArtifacts() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = ShockEmuPaths(
        supportRoot: temporary.appendingPathComponent("support", isDirectory: true),
        sourceApp: temporary.appendingPathComponent("source.app", isDirectory: true)
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    let artifactRoot = paths.artifactRoot(for: String(repeating: "a", count: 64))
    let app = artifactRoot.appendingPathComponent("RemotePlay.app", isDirectory: true)
    let runtime = artifactRoot.appendingPathComponent("libShockEmuRuntime.dylib")
    let unrelated = paths.supportRoot.appendingPathComponent("keep.txt")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Data("runtime".utf8).write(to: runtime)
    try Data("owned by user".utf8).write(to: unrelated)
    let manifest = PreparedManifest(
        sourceExecutableSHA256: String(repeating: "a", count: 64),
        runtimeSHA256: String(repeating: "b", count: 64),
        preparedAppRelativePath: try paths.relativePath(for: app),
        runtimeRelativePath: try paths.relativePath(for: runtime),
        remotePlayVersion: "9.0.0"
    )
    try ManifestStore(paths: paths).save(manifest)

    try Cleaner(paths: paths, requireRemotePlayStopped: {}).clean(logs: false)

    #expect(!FileManager.default.fileExists(atPath: app.path))
    #expect(!FileManager.default.fileExists(atPath: runtime.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func launchEnvironmentDropsInheritedInjectionAndStaleProfileValues() {
    let environment = LaunchEnvironment.make(
        base: [
            "HOME": "/safe/home",
            "DYLD_FORCE_FLAT_NAMESPACE": "1",
            "DYLD_LIBRARY_PATH": "/unexpected",
            "SHOCKEMU_PROFILE_PATH": "/stale",
        ],
        runtime: "/owned/runtime",
        profile: "/selected/profile",
        profileHash: String(repeating: "a", count: 64),
        inputSource: .local,
        verbose: true
    )
    #expect(environment["HOME"] == "/safe/home")
    #expect(environment["DYLD_FORCE_FLAT_NAMESPACE"] == nil)
    #expect(environment["DYLD_LIBRARY_PATH"] == nil)
    #expect(environment["DYLD_INSERT_LIBRARIES"] == "/owned/runtime")
    #expect(environment["SHOCKEMU_PROFILE_PATH"] == "/selected/profile")
    #expect(environment["SHOCKEMU_VERBOSE"] == "1")
}
