import Foundation

enum ManifestError: Error {
    case unsupportedSchema
    case invalidHash
    case unsafePath
}

struct PreparedManifest: Codable {
    var schemaVersion = 1
    var sourceExecutableSHA256: String
    var runtimeSHA256: String
    var preparedAppRelativePath: String
    var runtimeRelativePath: String
    var remotePlayVersion: String
    var createdAt = Date()

    func validate() throws {
        guard schemaVersion == 1 else { throw ManifestError.unsupportedSchema }
        let hashes = [sourceExecutableSHA256, runtimeSHA256]
        guard hashes.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw ManifestError.invalidHash
        }
        guard Self.safeRelative(preparedAppRelativePath), Self.safeRelative(runtimeRelativePath) else {
            throw ManifestError.unsafePath
        }
        let artifactPrefix = "artifacts/\(sourceExecutableSHA256)/"
        guard preparedAppRelativePath == artifactPrefix + "RemotePlay.app",
              runtimeRelativePath == artifactPrefix + "libShockEmuRuntime.dylib" else {
            throw ManifestError.unsafePath
        }
    }

    private static func safeRelative(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.isEmpty else { return false }
        let components = NSString(string: path).pathComponents
        return !components.contains("..") && !components.contains(".")
    }
}

enum ArtifactSafety {
    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let canonicalRoot = canonical(root).path
        let canonicalCandidate = canonical(candidate).path
        return canonicalCandidate.hasPrefix(canonicalRoot + "/")
    }

    static func requireDescendant(_ candidate: URL, of root: URL) throws -> URL {
        guard isDescendant(candidate, of: root) else {
            throw CLIError.failed("Refusing an artifact path outside the ShockEmu support directory.")
        }
        return canonical(candidate)
    }
}

struct ShockEmuPaths {
    let supportRoot: URL
    let sourceApp: URL

    static var live: ShockEmuPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ShockEmuPaths(
            supportRoot: home.appendingPathComponent("Library/Application Support/ShockEmu", isDirectory: true),
            sourceApp: URL(fileURLWithPath: "/Applications/RemotePlay.app", isDirectory: true)
        )
    }

    var manifest: URL { supportRoot.appendingPathComponent("manifest.json") }
    var logs: URL { supportRoot.appendingPathComponent("logs", isDirectory: true) }
    var artifacts: URL { supportRoot.appendingPathComponent("artifacts", isDirectory: true) }

    func artifactRoot(for sourceHash: String) -> URL {
        artifacts.appendingPathComponent(sourceHash, isDirectory: true)
    }

    func relativePath(for url: URL) throws -> String {
        let owned = try ArtifactSafety.requireDescendant(url, of: supportRoot)
        return String(owned.path.dropFirst(ArtifactSafety.canonical(supportRoot).path.count + 1))
    }
}

struct ManifestStore {
    let paths: ShockEmuPaths

    func load() throws -> PreparedManifest? {
        guard FileManager.default.fileExists(atPath: paths.manifest.path) else { return nil }
        let manifest = try JSONDecoder().decode(PreparedManifest.self, from: Data(contentsOf: paths.manifest))
        try manifest.validate()
        return manifest
    }

    func resolve(_ relativePath: String) throws -> URL {
        try ArtifactSafety.requireDescendant(
            paths.supportRoot.appendingPathComponent(relativePath),
            of: paths.supportRoot
        )
    }

    func save(_ manifest: PreparedManifest) throws {
        try manifest.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: paths.manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.manifest.path)
    }
}
