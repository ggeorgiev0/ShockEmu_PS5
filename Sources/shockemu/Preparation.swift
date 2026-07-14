import AppKit
import Foundation

struct PreparedArtifacts {
    let app: URL
    let runtime: URL
    let manifest: PreparedManifest
}

struct Preparer {
    let paths: ShockEmuPaths
    private var store: ManifestStore { ManifestStore(paths: paths) }

    func prepare(force: Bool) throws -> PreparedArtifacts {
        try ensureRemotePlayIsStopped()
        let source = try RemotePlayInspector.inspectSupportedApp(at: paths.sourceApp)
        let runtimeSource = try locateRuntime()
        let runtimeHash = try System.sha256(runtimeSource)
        if !force, let current = try currentArtifacts(sourceHash: source.hash, runtimeHash: runtimeHash) {
            return current
        }

        try System.createDirectory(paths.supportRoot)
        try System.createDirectory(paths.artifacts)
        let destinationRoot = paths.artifactRoot(for: source.hash)
        try removeManifestOwnedDestinationIfPresent(destinationRoot)
        try System.createDirectory(destinationRoot)
        let destinationApp = destinationRoot.appendingPathComponent("RemotePlay.app", isDirectory: true)
        let destinationRuntime = destinationRoot.appendingPathComponent("libShockEmuRuntime.dylib")
        do {
            try FileManager.default.copyItem(at: paths.sourceApp, to: destinationApp)
            try FileManager.default.copyItem(at: runtimeSource, to: destinationRuntime)
            try System.restrictPermissionsRecursively(destinationRoot)
            let runtimeSigning = try System.run("/usr/bin/codesign", [
                "--force", "--sign", "-", "--timestamp=none", destinationRuntime.path,
            ])
            guard runtimeSigning.status == 0 else {
                throw CLIError.failed("Ad-hoc signing the injection runtime failed.")
            }
            try signPreparedCopy(destinationApp)
            try verifyPreparedCopy(destinationApp)
        } catch {
            try? FileManager.default.removeItem(at: destinationRoot)
            throw error
        }
        guard try System.sha256(source.executable) == source.hash else {
            try? FileManager.default.removeItem(at: destinationRoot)
            throw CLIError.failed("The original Remote Play executable changed during preparation.")
        }
        let manifest = try makeManifest(
            sourceHash: source.hash,
            runtimeHash: runtimeHash,
            app: destinationApp,
            runtime: destinationRuntime
        )
        try store.save(manifest)
        ShockEmuLog(paths: paths).write("Prepared a verified Remote Play 9.0.0 copy.")
        return PreparedArtifacts(app: destinationApp, runtime: destinationRuntime, manifest: manifest)
    }

    func currentArtifacts(sourceHash: String, runtimeHash: String) throws -> PreparedArtifacts? {
        guard let manifest = try store.load(),
              manifest.sourceExecutableSHA256 == sourceHash,
              manifest.runtimeSHA256 == runtimeHash else { return nil }
        let app = try store.resolve(manifest.preparedAppRelativePath)
        let runtime = try store.resolve(manifest.runtimeRelativePath)
        guard FileManager.default.fileExists(atPath: app.path),
              FileManager.default.fileExists(atPath: runtime.path),
              try System.sha256(runtime) == runtimeHash else { return nil }
        try verifyPreparedCopy(app)
        return PreparedArtifacts(app: app, runtime: runtime, manifest: manifest)
    }

    private func makeManifest(sourceHash: String, runtimeHash: String, app: URL, runtime: URL) throws -> PreparedManifest {
        PreparedManifest(
            sourceExecutableSHA256: sourceHash,
            runtimeSHA256: runtimeHash,
            preparedAppRelativePath: try paths.relativePath(for: app),
            runtimeRelativePath: try paths.relativePath(for: runtime),
            remotePlayVersion: RemotePlayIdentity.version
        )
    }

    private func locateRuntime() throws -> URL {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let candidates = [
            executableDirectory.appendingPathComponent("libShockEmuRuntime.dylib"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/libShockEmuRuntime.dylib"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/arm64-apple-macosx/release/libShockEmuRuntime.dylib"),
        ]
        guard let result = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CLIError.failed("The release runtime was not found. Run 'swift build -c release' first.")
        }
        return ArtifactSafety.canonical(result)
    }

    private func signPreparedCopy(_ app: URL) throws {
        let entitlements = paths.supportRoot.appendingPathComponent("microphone-entitlements.plist")
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
        """.utf8)
        try data.write(to: entitlements, options: .atomic)
        defer { try? FileManager.default.removeItem(at: entitlements) }
        let result = try System.run("/usr/bin/codesign", [
            "--force", "--deep", "--sign", "-", "--timestamp=none",
            "--entitlements", entitlements.path, app.path,
        ])
        guard result.status == 0 else { throw CLIError.failed("Ad-hoc signing the disposable app copy failed.") }
    }

    private func verifyPreparedCopy(_ app: URL) throws {
        let verify = try System.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw CLIError.failed("The prepared app copy failed signature verification.") }
        let details = try System.run("/usr/bin/codesign", ["-dvv", app.path])
        guard !details.output.contains("runtime") else {
            throw CLIError.failed("The prepared copy still has the hardened-runtime flag.")
        }
        let entitlements = try System.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        guard entitlements.output.contains("com.apple.security.device.audio-input") else {
            throw CLIError.failed("The prepared copy lost its microphone entitlement.")
        }
    }

    private func removeManifestOwnedDestinationIfPresent(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let manifest = try store.load() else {
            throw CLIError.failed("Refusing to replace an artifact directory that is not marked by the ShockEmu manifest.")
        }
        let app = try store.resolve(manifest.preparedAppRelativePath)
        let runtime = try store.resolve(manifest.runtimeRelativePath)
        let ownedRoot = try ArtifactSafety.requireDescendant(root, of: paths.supportRoot)
        guard ArtifactSafety.canonical(app.deletingLastPathComponent()) == ownedRoot,
              ArtifactSafety.canonical(runtime.deletingLastPathComponent()) == ownedRoot else {
            throw CLIError.failed("The manifest does not own the existing artifact directory.")
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path))
        let expected = Set([app.lastPathComponent, runtime.lastPathComponent])
        guard names.isSubset(of: expected) else {
            throw CLIError.failed("The artifact directory contains files not marked by the ShockEmu manifest.")
        }
        for artifact in [app, runtime] where FileManager.default.fileExists(atPath: artifact.path) {
            try FileManager.default.removeItem(at: artifact)
        }
        try FileManager.default.removeItem(at: ownedRoot)
    }
}

func ensureRemotePlayIsStopped() throws {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: RemotePlayIdentity.bundleID).isEmpty else {
        throw CLIError.failed("Quit every Remote Play instance before preparing, running, or cleaning ShockEmu.")
    }
}
