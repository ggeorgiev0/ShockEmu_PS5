import AppKit
import Foundation
import ShockEmuCore

@main
enum ShockEmuCommandLine {
    static func main() {
        do {
            try execute(Command.parse(Array(CommandLine.arguments.dropFirst())))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "ShockEmu failed."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func execute(_ command: Command) throws {
        let paths = ShockEmuPaths.live
        switch command {
        case .doctor:
            try Doctor(paths: paths).run()
        case .validateProfile(let path):
            let result = try loadProfile(path)
            result.profile.warnings.forEach { print("warning: \($0)") }
            print("Profile is valid (\(result.profile.keyBindings.count) keyboard inputs, \(result.profile.mouseBindings.count) mouse inputs).")
        case .prepare(let force):
            _ = try Preparer(paths: paths).prepare(force: force)
            print("Prepared a verified disposable Remote Play copy.")
        case .run(let path, let source, let verbose):
            try run(profilePath: path, inputSource: source, verbose: verbose, paths: paths)
        case .clean(let logs):
            try Cleaner(paths: paths).clean(logs: logs)
            print("Removed ShockEmu-owned artifacts.")
        }
    }

    private static func loadProfile(_ path: String) throws -> (profile: SEProfile, url: URL, hash: String) {
        let url = ArtifactSafety.canonical(URL(fileURLWithPath: path))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError.failed("The selected profile is not a readable file.")
        }
        let data = try Data(contentsOf: url)
        let profile = try SEProfile(data: data)
        return (profile, url, System.sha256(data))
    }

    private static func run(profilePath: String, inputSource: InputSource, verbose: Bool, paths: ShockEmuPaths) throws {
        try ensureRemotePlayIsStopped()
        let selected = try loadProfile(profilePath)
        selected.profile.warnings.forEach { print("warning: \($0)") }
        let prepared = try Preparer(paths: paths).prepare(force: false)
        guard let executable = Bundle(url: prepared.app)?.executableURL else {
            throw CLIError.failed("The prepared Remote Play executable is missing.")
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.environment = LaunchEnvironment.make(
            base: ProcessInfo.processInfo.environment,
            runtime: prepared.runtime.path,
            profile: selected.url.path,
            profileHash: selected.hash,
            inputSource: inputSource,
            verbose: verbose
        )
        ShockEmuLog(paths: paths).write("Launching the prepared Remote Play copy.")
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CLIError.failed("The prepared Remote Play process exited abnormally (status \(process.terminationStatus)).")
        }
    }
}

struct Doctor {
    let paths: ShockEmuPaths

    func run() throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard os.majorVersion == 26, os.minorVersion == 5 else {
            throw CLIError.failed("This build is verified only on macOS 26.5.")
        }
        let processor = try System.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        guard processor.status == 0, processor.output.contains("Apple M3 Pro") else {
            throw CLIError.failed("This build is verified only on Apple M3 Pro.")
        }
        let xcode = try System.run("/usr/bin/xcodebuild", ["-version"])
        guard xcode.status == 0, xcode.output.contains("Xcode 26.6") else {
            throw CLIError.failed("Xcode 26.6 is required for the verified release build.")
        }
        let identity = try RemotePlayInspector.inspectSupportedApp(at: paths.sourceApp)
        guard try RemotePlayInspector.hasRequiredIOKitImports(identity.executable) else {
            throw CLIError.failed("Remote Play no longer imports the required IOKit functions.")
        }
        let sip = try System.run("/usr/bin/csrutil", ["status"])
        guard sip.status == 0, sip.output.localizedCaseInsensitiveContains("enabled") else {
            throw CLIError.failed("System Integrity Protection must remain enabled.")
        }
        print("Remote Play: 9.0.0, Sony signature valid, supported hash")
        print("Host: Apple M3 Pro, macOS 26.5, Xcode 26.6")
        print("IOKit: required imports present")
        print("SIP: enabled")
        if let manifest = try ManifestStore(paths: paths).load() {
            print("Prepared cache: schema \(manifest.schemaVersion), source hash matches: \(manifest.sourceExecutableSHA256 == identity.hash)")
        } else {
            print("Prepared cache: not created")
        }
    }
}
