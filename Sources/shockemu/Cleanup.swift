import Foundation

struct Cleaner {
    let paths: ShockEmuPaths
    var requireRemotePlayStopped: () throws -> Void = ensureRemotePlayIsStopped

    func clean(logs: Bool) throws {
        try requireRemotePlayStopped()
        let store = ManifestStore(paths: paths)
        if let manifest = try store.load() {
            let app = try store.resolve(manifest.preparedAppRelativePath)
            let runtime = try store.resolve(manifest.runtimeRelativePath)
            for artifact in [app, runtime] where FileManager.default.fileExists(atPath: artifact.path) {
                try FileManager.default.removeItem(at: artifact)
            }
            let roots = Set([app.deletingLastPathComponent(), runtime.deletingLastPathComponent()])
            for root in roots {
                let owned = try ArtifactSafety.requireDescendant(root, of: paths.supportRoot)
                let contents = try FileManager.default.contentsOfDirectory(atPath: owned.path)
                if contents.isEmpty { try FileManager.default.removeItem(at: owned) }
            }
            try FileManager.default.removeItem(at: paths.manifest)
        }
        if logs, FileManager.default.fileExists(atPath: paths.logs.path) {
            let ownedLogs = try ArtifactSafety.requireDescendant(paths.logs, of: paths.supportRoot)
            try FileManager.default.removeItem(at: ownedLogs)
        }
    }
}

struct ShockEmuLog {
    let paths: ShockEmuPaths
    private let maximumBytes: UInt64 = 1_048_576

    func write(_ message: String) {
        do {
            try System.createDirectory(paths.logs)
            let current = paths.logs.appendingPathComponent("shockemu.log")
            if let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize), size >= maximumBytes {
                try rotate()
            }
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if !FileManager.default.fileExists(atPath: current.path) {
                try Data(line.utf8).write(to: current, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: current)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
        } catch {
            // Logging must never stop controller launch or expose path details.
        }
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = paths.logs.appendingPathComponent("shockemu.log.4")
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        for index in stride(from: 3, through: 1, by: -1) {
            let source = paths.logs.appendingPathComponent("shockemu.log.\(index)")
            let destination = paths.logs.appendingPathComponent("shockemu.log.\(index + 1)")
            if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: destination) }
        }
        let current = paths.logs.appendingPathComponent("shockemu.log")
        if manager.fileExists(atPath: current.path) {
            try manager.moveItem(at: current, to: paths.logs.appendingPathComponent("shockemu.log.1"))
        }
    }
}
